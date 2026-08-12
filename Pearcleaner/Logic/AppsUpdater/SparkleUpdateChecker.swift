//
//  SparkleUpdateChecker.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 10/28/25.
//
//  Simplified Sparkle update checker using SPUUpdater directly
//

import Foundation
import Sparkle

/// Result of Sparkle update check - makes Sparkle's decision explicit
private enum SparkleUpdateResult {
    /// Sparkle found a valid update (always trust this)
    case updateFound(
        appcastItem: SUAppcastItem,
        state: SPUUserUpdateState
    )

    /// Sparkle says no update needed
    case noUpdate(
        reason: SPUNoUpdateFoundReason,
        latestItem: SUAppcastItem?  // May be nil if feed is empty
    )

    /// Sparkle encountered an error
    case error(Error)
}

private enum SparkleSingleAppCheckResult: @unchecked Sendable {
    case update(UpdateableApp)
    case current(URL)
    case failed(UpdateCheckFailure)
}

class SparkleUpdateChecker {
    fileprivate static let logger = UpdaterDebugLogger.shared
    static let invalidSigningConfigurationMessage = "This app's Sparkle signing configuration does not support external update checks"
    static let invalidFeedConfigurationMessage = "This app does not expose a usable Sparkle feed"

    /// Check for Sparkle updates using SPUUpdater directly
    /// Only checks apps with SUFeedURL in Info.plist (no binary scanning)
    static func checkForUpdates(apps: [AppInfo], includePreReleases: Bool) async -> UpdateCheckResults {
        logger.log(.sparkle, "Starting Sparkle update check for \(apps.count) apps (includePreReleases: \(includePreReleases))")
        await GlobalConsoleManager.shared.appendOutput("Checking for Sparkle updates (\(apps.count) apps)...\n", source: CurrentPage.updater.title)

        // Filter apps that have Sparkle feed URLs
        var sparkleApps: [(appInfo: AppInfo, bundle: Bundle, feedURL: URL)] = []
        var results = UpdateCheckResults()

        for appInfo in apps {
            // App Store receipts are authoritative. Some MAS builds retain
            // stale Sparkle keys that are not an alternative update channel.
            guard !appInfo.isAppStore else {
                logger.log(.sparkle, "Skipping App Store app: \(appInfo.appName)")
                continue
            }

            guard let bundle = Bundle(url: appInfo.path) else {
                results.failures.append(UpdateCheckFailure(
                    appPath: appInfo.path,
                    appName: appInfo.appName,
                    message: "The application bundle could not be opened"
                ))
                continue
            }

            if hasInvalidEdDSAPublicKey(in: bundle) {
                logger.log(.sparkle, "Skipping invalid EdDSA key: \(appInfo.appName)")
                results.failures.append(UpdateCheckFailure(
                    appPath: appInfo.path,
                    appName: appInfo.appName,
                    message: invalidSigningConfigurationMessage
                ))
                continue
            }

            guard let feedURL = Self.feedURL(from: bundle) else {
                results.failures.append(UpdateCheckFailure(
                    appPath: appInfo.path,
                    appName: appInfo.appName,
                    message: invalidFeedConfigurationMessage
                ))
                continue
            }

            logger.log(.sparkle, "Checking: \(appInfo.appName) - \(feedURL.absoluteString)")
            sparkleApps.append((appInfo, bundle, feedURL))
        }

        guard !sparkleApps.isEmpty else {
            logger.log(.sparkle, "No Sparkle apps with valid feed URLs found")
            return results
        }

        // Check apps in batches to prevent system resource exhaustion
        // Batch size adapts to CPU core count (min: 5, max: 50)
        // Lower minimum helps Intel Macs complete scans faster while still being safe
        let batches = createOptimalChunks(from: sparkleApps, minChunkSize: 5, maxChunkSize: 50)

        // Process each batch concurrently
        for batch in batches {
            // Check for cancellation between batches
            if Task.isCancelled {
                break
            }

            let batchResults = await withTaskGroup(of: SparkleSingleAppCheckResult.self) { group in
                for (appInfo, bundle, feedURL) in batch {
                    group.addTask {
                        await Self.checkSingleApp(appInfo: appInfo, bundle: bundle, feedURL: feedURL, includePreReleases: includePreReleases)
                    }
                }

                var batchResults = UpdateCheckResults()
                for await result in group {
                    switch result {
                    case .update(let update):
                        batchResults.updates.append(update)
                    case .current(let path):
                        batchResults.currentAppPaths.insert(path)
                    case .failed(let failure):
                        batchResults.failures.append(failure)
                    }
                }
                return batchResults
            }

            results.merge(batchResults)
        }

        logger.log(.sparkle, "Found \(results.updates.count) Sparkle updates available")
        await GlobalConsoleManager.shared.appendOutput("Found \(results.updates.count) Sparkle update(s)\n", source: CurrentPage.updater.title)
        return results
    }

    /// Check a single app for updates using SPUUpdater
    private static func checkSingleApp(appInfo: AppInfo, bundle: Bundle, feedURL: URL, includePreReleases: Bool) async -> SparkleSingleAppCheckResult {
        // Directly proceed with Sparkle check (no pre-flight URL check)
        // Users can hide slow/problematic apps using the eye button to prevent future checks
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let operation = SparkleCheckerOperation(
                    appInfo: appInfo,
                    bundle: bundle,
                    feedURL: feedURL,
                    includePreReleases: includePreReleases
                ) { result in
                    continuation.resume(returning: result)
                }
                operation.start()
            }
        }

        return result
    }

    /// Get Sparkle feed URL from app bundle
    /// Checks SUFeedURL in Info.plist, falls back to DevMate if framework is present
    static func feedURL(from bundle: Bundle) -> URL? {
        guard let information = bundle.infoDictionary else { return nil }

        // 1. Check SUFeedURL in Info.plist (standard Sparkle configuration)
        if let urlString = information["SUFeedURL"] as? String,
           let feedURL = validatedFeedURL(from: urlString) {
            return feedURL
        }

        // 2. DevMate framework fallback (older apps)
        guard let bundleIdentifier = bundle.bundleIdentifier else { return nil }

        let frameworksURL = bundle.bundleURL.appendingPathComponent("Contents/Frameworks")
        let frameworks = try? FileManager.default.contentsOfDirectory(atPath: frameworksURL.path)

        if frameworks?.contains(where: { $0.contains("DevMateKit") }) ?? false {
            // DevMate apps use https://updates.devmate.com/{bundleIdentifier}.xml
            return URL(string: "https://updates.devmate.com")?
                .appendingPathComponent(bundleIdentifier)
                .appendingPathExtension("xml")
        }

        return nil
    }

    /// Only absolute HTTP(S) feeds can be checked outside of the host app.
    /// Some apps use placeholders such as `NULL` and replace them dynamically
    /// at runtime; Foundation otherwise accepts these as relative URLs.
    static func validatedFeedURL(from rawValue: String) -> URL? {
        let value = rawValue
            .unquoted
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty,
              !["null", "(null)", "nil"].contains(value.lowercased()),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }

        return url
    }

    /// Sparkle 2 expects SUPublicEDKey to contain a raw 32-byte Ed25519 public
    /// key encoded as one Base64 string. A PEM/DSA key in this field causes
    /// SPUUpdater.start() to fail with a low-level cryptographic error.
    static func hasInvalidEdDSAPublicKey(in bundle: Bundle) -> Bool {
        guard let information = bundle.infoDictionary,
              information.keys.contains("SUPublicEDKey") else {
            return false
        }

        guard let rawKey = information["SUPublicEDKey"] as? String else {
            return true
        }

        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains("-----BEGIN"),
              let decodedKey = Data(base64Encoded: key) else {
            return true
        }

        return decodedKey.count != 32
    }

    /// Sparkle reports signing setup problems through one error code, including
    /// missing, malformed, or legacy-only public keys. Keep the detailed error
    /// in diagnostics while presenting it as an unsupported third-party setup.
    fileprivate static func userFacingFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              nsError.code == SUError.noPublicDSAFoundError.rawValue else {
            return error.localizedDescription
        }

        return invalidSigningConfigurationMessage
    }

}

// MARK: - SPUUpdater Operation

/// Manages a single SPUUpdater instance to check for updates
private class SparkleCheckerOperation: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private let appInfo: AppInfo
    private let bundle: Bundle
    private let feedURL: URL
    private let includePreReleases: Bool
    private let completion: (SparkleSingleAppCheckResult) -> Void
    private var updater: SPUUpdater?
    private var hasFinished = false

    init(appInfo: AppInfo, bundle: Bundle, feedURL: URL, includePreReleases: Bool, completion: @escaping (SparkleSingleAppCheckResult) -> Void) {
        self.appInfo = appInfo
        self.bundle = bundle
        self.feedURL = feedURL
        self.includePreReleases = includePreReleases
        self.completion = completion
        super.init()
    }

    func start() {
        // Log what we're passing to Sparkle for diagnostics
        SparkleUpdateChecker.logger.log(.sparkle, "  🔍 Creating SPUUpdater:")
        SparkleUpdateChecker.logger.log(.sparkle, "     Bundle path: \(bundle.bundlePath)")
        SparkleUpdateChecker.logger.log(.sparkle, "     CFBundleVersion: \(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "nil")")
        SparkleUpdateChecker.logger.log(.sparkle, "     CFBundleShortVersionString: \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "nil")")
        SparkleUpdateChecker.logger.log(.sparkle, "     Feed URL: \(feedURL.absoluteString)")
        SparkleUpdateChecker.logger.log(.sparkle, "     Include pre-releases: \(includePreReleases)")

        // Create SPUUpdater with this operation as both user driver and delegate
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater

        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            SparkleUpdateChecker.logger.log(.sparkle, "  ❌ Failed to start updater: \(error.localizedDescription)")
            finish(with: .failed(failure(SparkleUpdateChecker.userFacingFailureMessage(for: error))))
        }
    }

    private func finish(with result: SparkleSingleAppCheckResult) {
        guard !hasFinished else { return }
        hasFinished = true
        completion(result)
        updater = nil
    }

    private func failure(_ message: String) -> UpdateCheckFailure {
        UpdateCheckFailure(appPath: appInfo.path, appName: appInfo.appName, message: message)
    }

    private func createUpdate(from appcastItem: SUAppcastItem, includePreReleases: Bool) -> UpdateableApp? {
        // Get versions from appcast item for display
        let availableVersionString = appcastItem.displayVersionString
        let buildVersionString = appcastItem.versionString

        // Sparkle already selected a compatible item. Only apply the user's
        // pre-release preference and extract metadata here.
        SparkleUpdateChecker.logger.log(.sparkle, "     Processing validated update: \(availableVersionString) (build: \(buildVersionString))")

        // Check if this is a pre-release
        var isPreRelease = false

        // Method 1: Sparkle 2.0+ channels (modern apps)
        if let channel = appcastItem.channel, channel.lowercased() != "release" {
            if !includePreReleases {
                SparkleUpdateChecker.logger.log(.sparkle, "     Filtering: Pre-release channel '\(channel)' (toggle off)")
                return nil
            }
            isPreRelease = true
            SparkleUpdateChecker.logger.log(.sparkle, "     Detected pre-release channel: \(channel)")
        }

        // Method 2: Version string analysis (legacy apps like Transmission)
        if isPreReleaseVersion(availableVersionString) {
            if !includePreReleases {
                SparkleUpdateChecker.logger.log(.sparkle, "     Filtering: Pre-release version name '\(availableVersionString)' (toggle off)")
                return nil
            }
            isPreRelease = true
            SparkleUpdateChecker.logger.log(.sparkle, "     Detected pre-release version name: \(availableVersionString)")
        }

        // Extract release notes
        var releaseTitle: String?
        var releaseDescription: String?
        var releaseNotesLink: String?
        var fetchedReleaseNotes: String?

        if let title = appcastItem.title {
            releaseTitle = title
        }
        if let description = appcastItem.itemDescription {
            releaseDescription = ReleaseNotesProcessor.normalize(
                description,
                installedVersion: appInfo.appVersion,
                availableVersion: availableVersionString
            )
        }
        if let notesURL = appcastItem.releaseNotesURL ?? appcastItem.fullReleaseNotesURL {
            releaseNotesLink = notesURL.absoluteString
            // Note: Cannot fetch here synchronously - will be fetched on-demand when sidebar row appears
            fetchedReleaseNotes = nil
        }

        return UpdateableApp(
            appInfo: appInfo,
            availableVersion: availableVersionString,
            availableBuildNumber: buildVersionString,
            source: .sparkle,
            adamID: nil,
            appStoreURL: nil,
            status: .idle,
            progress: 0.0,
            isSelectedForUpdate: true,
            releaseTitle: releaseTitle,
            releaseDescription: releaseDescription,
            releaseNotesLink: releaseNotesLink,
            releaseDate: appcastItem.dateString,
            isPreRelease: isPreRelease,
            isIOSApp: false,
            foundInRegion: nil,
            fetchedReleaseNotes: fetchedReleaseNotes,
            appcastItem: appcastItem  // Cache the validated appcast item
        )
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Disable automatic update checks and system profiling
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let result = SparkleUpdateResult.updateFound(appcastItem: appcastItem, state: state)
        processResult(result, reply: reply, acknowledgement: nil)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let result = extractResultFromNoUpdateError(error)
        processResult(result, reply: nil, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let result = SparkleUpdateResult.error(error)
        processResult(result, reply: nil, acknowledgement: acknowledgement)
    }

    // MARK: - Helper Methods

    /// Extract structured result from Sparkle's "no update" error
    private func extractResultFromNoUpdateError(_ error: Error) -> SparkleUpdateResult {
        let nsError = error as NSError

        // Verify this is actually a "no update" error from Sparkle
        guard nsError.domain == SUSparkleErrorDomain,
              nsError.code == SUError.noUpdateError.rawValue else {
            // Some other error - treat as genuine error
            return .error(error)
        }

        // Extract latest appcast item (may be nil if feed is empty)
        let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem

        // Extract Sparkle's reason for no update
        let reasonRawValue = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value ?? 0
        let sparkleReason = SPUNoUpdateFoundReason(rawValue: reasonRawValue) ?? .unknown

        return .noUpdate(reason: sparkleReason, latestItem: latestItem)
    }

    /// Format SPUNoUpdateFoundReason as human-readable string
    private func formatNoUpdateReason(_ reason: SPUNoUpdateFoundReason) -> String {
        switch reason {
        case .onLatestVersion:
            return "Already on latest version"
        case .onNewerThanLatestVersion:
            return "Newer than latest (ahead of feed)"
        case .systemIsTooOld:
            return "System too old for update"
        case .systemIsTooNew:
            return "System too new for update"
        default:
            return "Unknown reason"
        }
    }

    /// Log comprehensive details about what Sparkle's callback told us
    private func logSparkleCallback(_ result: SparkleUpdateResult) {
        switch result {
        case .updateFound(let appcastItem, let state):
            SparkleUpdateChecker.logger.log(.sparkle, "  📥 CALLBACK: showUpdateFound")
            SparkleUpdateChecker.logger.log(.sparkle, "     App: \(appInfo.appName)")
            SparkleUpdateChecker.logger.log(.sparkle, "     Installed: \(appInfo.appVersion) (build: \(appInfo.appBuildNumber ?? "unknown"))")
            SparkleUpdateChecker.logger.log(.sparkle, "     Available: \(appcastItem.displayVersionString) (build: \(appcastItem.versionString))")

            if let minOS = appcastItem.minimumSystemVersion {
                SparkleUpdateChecker.logger.log(.sparkle, "     Min system version: \(minOS)")
            }

            if let channel = appcastItem.channel {
                SparkleUpdateChecker.logger.log(.sparkle, "     Channel: \(channel)")
            }

            if let date = appcastItem.dateString {
                SparkleUpdateChecker.logger.log(.sparkle, "     Release date: \(date)")
            }

            let stageDesc = state.stage == .notDownloaded ? "not downloaded" :
                           state.stage == .downloaded ? "downloaded" : "installing"
            let initiatedDesc = state.userInitiated ? "user-initiated" : "automatic"
            SparkleUpdateChecker.logger.log(.sparkle, "     State: \(stageDesc), \(initiatedDesc)")

        case .noUpdate(let reason, let latestItem):
            SparkleUpdateChecker.logger.log(.sparkle, "  📥 CALLBACK: showUpdateNotFoundWithError")
            SparkleUpdateChecker.logger.log(.sparkle, "     App: \(appInfo.appName)")
            SparkleUpdateChecker.logger.log(.sparkle, "     Installed: \(appInfo.appVersion)")

            if let item = latestItem {
                SparkleUpdateChecker.logger.log(.sparkle, "     Latest: \(item.displayVersionString) (build: \(item.versionString))")
                if let title = item.title {
                    SparkleUpdateChecker.logger.log(.sparkle, "     Title: \(title)")
                }
            } else {
                SparkleUpdateChecker.logger.log(.sparkle, "     Latest: (none in feed)")
            }

            let reasonDesc = formatNoUpdateReason(reason)
            SparkleUpdateChecker.logger.log(.sparkle, "     Reason: \(reasonDesc)")

        case .error(let error):
            SparkleUpdateChecker.logger.log(.sparkle, "  📥 CALLBACK: showUpdaterError")
            SparkleUpdateChecker.logger.log(.sparkle, "     App: \(appInfo.appName)")
            SparkleUpdateChecker.logger.log(.sparkle, "     Error: \(error.localizedDescription)")

            let nsError = error as NSError
            SparkleUpdateChecker.logger.log(.sparkle, "     Domain: \(nsError.domain), Code: \(nsError.code)")
        }
    }

    /// Process Sparkle's result with comprehensive logging and decision-making
    private func processResult(
        _ result: SparkleUpdateResult,
        reply: ((SPUUserUpdateChoice) -> Void)?,
        acknowledgement: (() -> Void)?
    ) {
        // Log what Sparkle told us (comprehensive callback details)
        logSparkleCallback(result)

        // Process based on result type
        switch result {
        case .updateFound(let appcastItem, _):
            // Trust Sparkle - it says update is available
            SparkleUpdateChecker.logger.log(.sparkle, "  → Processing update found callback")

            // Apply our pre-release filtering if toggle is OFF
            let update = createUpdate(from: appcastItem, includePreReleases: includePreReleases)

            if let update = update {
                SparkleUpdateChecker.logger.log(.sparkle, "  ✅ Showing update: \(update.appInfo.appName) \(appInfo.appVersion) → \(update.availableVersion ?? "unknown")")
                if update.isPreRelease {
                    SparkleUpdateChecker.logger.log(.sparkle, "     🔵 Marked as pre-release")
                }
            } else {
                // Our filtering rejected it (pre-release filtered or version not newer)
                SparkleUpdateChecker.logger.log(.sparkle, "  ⚠️ Update filtered out by Pearcleaner logic")
            }

            // This checker only observes Sparkle's selection. Dismiss the
            // installation prompt without persisting a skipped version.
            reply?(.dismiss)

            if let update {
                finish(with: .update(update))
            } else {
                finish(with: .failed(failure("Sparkle selected an update that was filtered by the current channel settings")))
            }

        case .noUpdate(let reason, let latestItem):
            // Sparkle says no update - trust it completely!
            let reasonDesc = formatNoUpdateReason(reason)
            SparkleUpdateChecker.logger.log(.sparkle, "  → No update needed: \(reasonDesc)")

            if let item = latestItem {
                let latestVersion = item.displayVersionString
                let latestBuild = item.versionString
                SparkleUpdateChecker.logger.log(.sparkle, "     Latest in feed: \(latestVersion) (build: \(latestBuild))")
            } else {
                SparkleUpdateChecker.logger.log(.sparkle, "     Latest in feed: (none)")
            }

            switch reason {
            case .onLatestVersion, .onNewerThanLatestVersion:
                finish(with: .current(appInfo.path))
            case .systemIsTooOld:
                finish(with: .failed(failure("The available Sparkle update requires a newer macOS version")))
            case .systemIsTooNew:
                finish(with: .failed(failure("The available Sparkle update does not support this macOS version")))
            default:
                finish(with: .failed(failure("Sparkle could not determine a compatible update")))
            }
            acknowledgement?()

        case .error(let error):
            SparkleUpdateChecker.logger.log(.sparkle, "  ❌ Sparkle error: \(error.localizedDescription)")
            finish(with: .failed(failure(SparkleUpdateChecker.userFacingFailureMessage(for: error))))
            acknowledgement?()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        finish(with: .current(appInfo.path))
    }

    // MARK: - Ignored SPUUserDriver Methods

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateInFocus() {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showCanCheck(forUpdates canCheckForUpdates: Bool) {}
    func dismissUserInitiatedUpdateCheck() {}
    func showSendingTerminationSignal() {}
    func dismissUpdateInstallation() {}

    // MARK: - SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Provide the feed URL to Sparkle
        return feedURL.absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // If pre-releases are enabled, allow common pre-release channels
        // If disabled, return empty set (only default/stable channel)
        guard includePreReleases else {
            return []
        }

        // Common pre-release channel names used by Sparkle apps
        return ["beta", "alpha", "nightly", "rc", "dev"]
    }

}

// MARK: - String Extension

private extension String {
    /// Removes surrounding quotes and apostrophes from the string
    /// Handles malformed Info.plist entries like: "https://example.com" or 'https://example.com'
    var unquoted: String {
        return trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
}
