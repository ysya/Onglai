//
//  UpdateManager.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 10/13/25.
//

import Foundation
import SwiftUI
import AlinFoundation

@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var updatesBySource: [UpdateSource: [UpdateableApp]] = [:]
    @Published var hiddenUpdates: [UpdateableApp] = []
    @Published var isScanning: Bool = false
    @Published var lastScanDate: Date?
    @Published var scanningSources: Set<UpdateSource> = []
    @Published var currentScanTask: Task<Void, Never>?
    @Published private(set) var scanFailuresBySource: [UpdateSource: [UpdateCheckFailure]] = [:]

    /// Paths that each source explicitly confirmed as current. Absence from an
    /// update list is not enough because it may also mean the check failed.
    private var currentAppPathsBySource: [UpdateSource: Set<URL>] = [:]

    // Batch update tracking
    @Published var isUpdatingAll: Bool = false
    @Published var totalAppsToUpdate: Int = 0
    @Published private(set) var completedAppsInBatch: Int = 0

    // Consolidated settings (2 Data properties total)
    @AppStorage("settings.updater.sources") private var sourcesData: Data = UpdaterSourcesSettings.defaultEncoded()
    @AppStorage("settings.updater.display") private var displayData: Data = UpdaterDisplaySettings.defaultEncoded()

    @AppStorage("settings.updater.debugLogging") private var debugLogging: Bool = false
    @AppStorage("settings.updater.hiddenAppsData") private var hiddenAppsData: Data = Data()
    @AppStorage("settings.updater.ignoredAppsData") private var ignoredAppsData: Data = Data()

    // Computed properties for convenient access to nested structs
    private var sources: UpdaterSourcesSettings {
        get {
            UpdaterSourcesSettings.decode(from: sourcesData)
        }
        set {
            sourcesData = newValue.encode()
        }
    }

    private var display: UpdaterDisplaySettings {
        get {
            UpdaterDisplaySettings.decode(from: displayData)
        }
        set {
            displayData = newValue.encode()
        }
    }

    // Backward-compatible convenience properties
    private var checkAppStore: Bool { sources.appStore.enabled }
    private var checkHomebrew: Bool { sources.homebrew.enabled }
    private var checkSparkle: Bool { sources.sparkle.enabled }
    private var showAutoUpdatesInHomebrew: Bool { sources.homebrew.showAutoUpdates }
    private var includeSparklePreReleases: Bool { sources.sparkle.includePreReleases }
    private var showUnsupported: Bool { display.showUnsupported }
    private var showCurrent: Bool { display.showCurrent }

    private var hasAutoScannedOnce = false

    private init() {
        // Migrate old settings to new consolidated format
        migrateSettingsIfNeeded()

        // Migrate old hiddenApps data to new ignoredApps format on first launch
        migrateHiddenAppsIfNeeded()

        // Subscribe to notification for automatic background scanning
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAllAppsFullyLoaded),
            name: NSNotification.Name("AllAppsFullyLoaded"),
            object: nil
        )
    }

    /// Migrate old individual settings to new consolidated structs (one-time migration)
    private func migrateSettingsIfNeeded() {
        // Check if migration already happened by seeing if new settings exist
        if sourcesData.isEmpty {
            // Read old settings from UserDefaults
            let oldCheckAppStore = UserDefaults.standard.bool(forKey: "settings.updater.checkAppStore")
            let oldCheckHomebrew = UserDefaults.standard.bool(forKey: "settings.updater.checkHomebrew")
            let oldCheckSparkle = UserDefaults.standard.bool(forKey: "settings.updater.checkSparkle")
            let oldShowAutoUpdates = UserDefaults.standard.bool(forKey: "settings.updater.showAutoUpdatesInHomebrew")
            let oldIncludePreReleases = UserDefaults.standard.bool(forKey: "settings.updater.includeSparklePreReleases")

            // Check if any old settings exist (they default to false if never set)
            let hasOldSettings = UserDefaults.standard.object(forKey: "settings.updater.checkAppStore") != nil ||
                                UserDefaults.standard.object(forKey: "settings.updater.checkHomebrew") != nil ||
                                UserDefaults.standard.object(forKey: "settings.updater.checkSparkle") != nil

            if hasOldSettings {
                // Migrate to new format
                var newSources = UpdaterSourcesSettings()
                newSources.appStore.enabled = oldCheckAppStore
                newSources.homebrew.enabled = oldCheckHomebrew
                newSources.homebrew.showAutoUpdates = oldShowAutoUpdates
                newSources.sparkle.enabled = oldCheckSparkle
                newSources.sparkle.includePreReleases = oldIncludePreReleases

                sources = newSources
            }
        }

        if displayData.isEmpty {
            // Read old showUnsupported setting
            let oldShowUnsupported = UserDefaults.standard.bool(forKey: "settings.updater.showUnsupported")

            if UserDefaults.standard.object(forKey: "settings.updater.showUnsupported") != nil {
                var newDisplay = UpdaterDisplaySettings()
                newDisplay.showUnsupported = oldShowUnsupported
                display = newDisplay
            }
        }
    }

    @objc private func handleAllAppsFullyLoaded() {
        // Only run once per app session
        guard !hasAutoScannedOnce else { return }
        hasAutoScannedOnce = true

        currentScanTask = Task { @MainActor in
            await scanIfNeeded()
        }
    }

    /// Public entry point for triggering scans. Prevents duplicate scans through centralized logic.
    /// - Parameters:
    ///   - forceReload: If true, bypasses cache and forces a fresh scan
    ///   - sources: Optional set of specific sources to scan. If nil, scans all enabled sources.
    func scanIfNeeded(forceReload: Bool = false, sources: Set<UpdateSource>? = nil) async {
        // Prevent duplicate scans
        guard !isScanning else { return }

        // Trigger scan if forcing reload OR specific sources requested
        if forceReload || sources != nil {
            await scanForUpdates(forceReload: forceReload, sources: sources)
            return
        }

        // Otherwise, only scan if no data exists yet
        guard lastScanDate == nil else { return }
        await scanForUpdates()
    }

    var hasUpdates: Bool {
        updatesBySource.values.contains { !$0.isEmpty } || !hiddenUpdates.isEmpty
    }

    var totalUpdateCount: Int {
        updatesBySource
            .filter { $0.key != .unsupported && $0.key != .current }
            .values
            .reduce(0) { $0 + $1.count }
    }

    /// Presents one row per installed app instead of one row per update source.
    /// The underlying source results remain intact so existing update and detail
    /// flows can continue to operate on their original records.
    var appCentricItems: [UpdaterListItem] {
        let sourceApps = updatesBySource.values.flatMap { $0 }
        let actionableApps = sourceApps.filter { $0.source != .current && $0.source != .unsupported }
        var items: [UpdaterListItem] = []

        for (_, candidates) in Dictionary(grouping: actionableApps, by: { $0.appInfo.path.standardizedFileURL }) {
            guard let primary = preferredUpdate(from: candidates) else { continue }
            items.append(
                UpdaterListItem(
                    id: "update:\(primary.appInfo.path.standardizedFileURL.path)",
                    section: primary.appInfo.isAppStore || primary.source == .appStore ? .external : .available,
                    appInfo: primary.appInfo,
                    primaryApp: primary,
                    alternateApps: candidates.filter { $0.id != primary.id },
                    issues: []
                )
            )
        }

        let pathsWithUpdates = Set(actionableApps.map { $0.appInfo.path.standardizedFileURL })
        var issuesByPath: [URL: [UpdaterSourceIssue]] = [:]
        for (source, failures) in scanFailuresBySource {
            for failure in failures {
                let path = failure.appPath.standardizedFileURL
                guard !pathsWithUpdates.contains(path) else { continue }
                issuesByPath[path, default: []].append(
                    UpdaterSourceIssue(source: source, message: failure.message)
                )
            }
        }

        for (path, issues) in issuesByPath {
            let appInfo = AppState.shared.sortedApps.first { $0.path.standardizedFileURL == path }
            let isUnsupportedConfiguration = issues.allSatisfy {
                $0.message == SparkleUpdateChecker.invalidFeedConfigurationMessage ||
                $0.message == SparkleUpdateChecker.invalidSigningConfigurationMessage
            }
            items.append(
                UpdaterListItem(
                    id: "issue:\(path.path)",
                    section: isUnsupportedConfiguration ? .unsupported : .attention,
                    appInfo: appInfo,
                    primaryApp: nil,
                    alternateApps: [],
                    issues: issues.sorted { $0.source.rawValue < $1.source.rawValue }
                )
            )
        }

        for source in [UpdateSource.current, .unsupported] {
            let section: UpdaterItemSection = source == .current ? .current : .unsupported
            for app in updatesBySource[source] ?? [] {
                let path = app.appInfo.path.standardizedFileURL
                items.append(
                    UpdaterListItem(
                        id: "\(source.rawValue):\(path.path)",
                        section: section,
                        appInfo: app.appInfo,
                        primaryApp: app,
                        alternateApps: [],
                        issues: []
                    )
                )
            }
        }

        return items.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    private func preferredUpdate(from candidates: [UpdateableApp]) -> UpdateableApp? {
        candidates.min { lhs, rhs in
            updateSourcePriority(for: lhs) < updateSourcePriority(for: rhs)
        }
    }

    private func updateSourcePriority(for app: UpdateableApp) -> Int {
        if app.appInfo.isAppStore, app.source == .appStore { return 0 }
        if app.appInfo.cask != nil, app.source == .homebrew { return 1 }
        if app.source == .sparkle { return 2 }
        if app.source == .homebrew { return 3 }
        if app.source == .appStore { return 4 }
        return 5
    }

    func setSelection(forAppAt path: URL, selected: Bool) {
        for source in [UpdateSource.homebrew, .sparkle] {
            guard var apps = updatesBySource[source] else { continue }
            var changed = false
            for index in apps.indices where apps[index].appInfo.path.standardizedFileURL == path.standardizedFileURL {
                apps[index].isSelectedForUpdate = selected
                changed = true
            }
            if changed {
                updatesBySource[source] = apps
            }
        }
    }

    /// Progress of batch update (0.0 to 1.0)
    var updateAllProgress: Double {
        guard totalAppsToUpdate > 0 else { return 0 }
        return Double(completedAppsInBatch) / Double(totalAppsToUpdate)
    }

    /// Number of completed apps in batch update
    var completedAppsCount: Int {
        completedAppsInBatch
    }

    /// Computed property for easy access to hidden apps mapping (bundleID -> source)
    private var hiddenApps: [String: UpdateSource] {
        get {
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: hiddenAppsData) else {
                return [:]
            }
            // Convert String to UpdateSource
            return decoded.compactMapValues { UpdateSource(rawValue: $0) }
        }
        set {
            // Convert UpdateSource to String for storage
            let stringDict = newValue.mapValues { $0.rawValue }
            hiddenAppsData = (try? JSONEncoder().encode(stringDict)) ?? Data()
        }
    }

    /// Unified ignored apps storage: bundleID -> [source -> version?]
    /// nil version = permanently ignored, string version = skip until newer version
    private var ignoredApps: [String: [String: String?]] {
        get {
            guard let decoded = try? JSONDecoder().decode([String: [String: String?]].self, from: ignoredAppsData) else {
                return [:]
            }
            return decoded
        }
        set {
            ignoredAppsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// Migrate old hiddenApps data to new ignoredApps format (one-time migration)
    private func migrateHiddenAppsIfNeeded() {
        // Only migrate if old data exists and new data is empty
        guard !hiddenAppsData.isEmpty, ignoredAppsData.isEmpty else { return }

        var migrated: [String: [String: String?]] = [:]
        for (bundleID, source) in hiddenApps {
            // Convert to new format with nil version (permanent ignore)
            migrated[bundleID] = [source.rawValue: nil]
        }

        ignoredApps = migrated
        // Keep old data for now in case user downgrades
    }

    /// Get the ignored version for a specific app and source
    /// - Parameter app: The app to check
    /// - Returns: nil if permanently ignored, version string if skipped, or nil if not ignored for this source
    func getIgnoredVersion(for app: UpdateableApp) -> String? {
        return ignoredApps[app.uniqueIdentifier]?[app.source.rawValue] ?? nil
    }

    /// Update the fetched release notes for a specific app
    /// - Parameters:
    ///   - appId: The UUID of the app to update
    ///   - content: The fetched release notes content
    func updateFetchedReleaseNotes(for appId: UUID, content: String) {
        // Find and update the app in updatesBySource
        for (source, apps) in updatesBySource {
            if let index = apps.firstIndex(where: { $0.id == appId }) {
                var updatedApp = apps[index]
                updatedApp.fetchedReleaseNotes = content
                updatesBySource[source]?[index] = updatedApp
                return
            }
        }
    }

    /// Hide an app permanently or skip a specific version
    /// - Parameters:
    ///   - app: The app to ignore
    ///   - skipVersion: Optional version to skip. If nil, app is permanently ignored. If provided, only that version is skipped.
    func hideApp(_ app: UpdateableApp, skipVersion: String? = nil) {
        // Add to new unified ignored apps storage
        var ignored = ignoredApps
        if ignored[app.uniqueIdentifier] == nil {
            ignored[app.uniqueIdentifier] = [:]
        }
        ignored[app.uniqueIdentifier]?[app.source.rawValue] = skipVersion

        ignoredApps = ignored

        // Also update old storage for backward compatibility
        if skipVersion == nil {
            var hidden = hiddenApps
            hidden[app.uniqueIdentifier] = app.source
            hiddenApps = hidden
        }

        // Immediately remove from visible lists for instant UI feedback
        updatesBySource[app.source]?.removeAll { $0.uniqueIdentifier == app.uniqueIdentifier }

        // Add to hidden list for sidebar display
        if !hiddenUpdates.contains(where: { $0.uniqueIdentifier == app.uniqueIdentifier }) {
            hiddenUpdates.append(app)
        }
    }

    /// Rescan a single app to get fresh update data
    func recheckUpdate(for app: UpdateableApp) async -> UpdateableApp? {
        // Get fresh AppInfo from sortedApps (handles case where app was updated externally)
        guard let freshAppInfo = AppState.shared.sortedApps.first(where: {
            $0.bundleIdentifier == app.uniqueIdentifier
        }) else {
            return nil // App no longer exists
        }

        // Call appropriate source-specific checker based on app.source
        switch app.source {
        case .homebrew:
            let results = await HomebrewUpdateChecker.checkForUpdates(
                apps: [freshAppInfo],
                includeFormulae: false,
                showAutoUpdatesInHomebrew: showAutoUpdatesInHomebrew
            )
            return results.updates.first

        case .appStore:
            let results = await AppStoreUpdateChecker.checkForUpdates(apps: [freshAppInfo])
            return results.updates.first

        case .sparkle:
            let results = await SparkleUpdateChecker.checkForUpdates(
                apps: [freshAppInfo],
                includePreReleases: includeSparklePreReleases
            )
            return results.updates.first

        case .unsupported:
            return nil // Can't check unsupported apps

        case .current:
            return nil // Already current, no update available
        }
    }

    /// Unhide an app (remove from hidden filter and restore to visible list if it has an update)
    func unhideApp(_ app: UpdateableApp) async {
        // Remove from new unified ignored apps storage
        var ignored = ignoredApps
        ignored[app.uniqueIdentifier]?.removeValue(forKey: app.source.rawValue)
        if ignored[app.uniqueIdentifier]?.isEmpty == true {
            ignored.removeValue(forKey: app.uniqueIdentifier)
        }
        ignoredApps = ignored

        // Also remove from old storage for backward compatibility
        var hidden = hiddenApps
        hidden.removeValue(forKey: app.uniqueIdentifier)
        hiddenApps = hidden

        // Immediately remove from hidden list for instant UI feedback
        hiddenUpdates.removeAll { $0.uniqueIdentifier == app.uniqueIdentifier }

        // Rescan the app to get fresh update data
        if let refreshedApp = await recheckUpdate(for: app) {
            // Add refreshed app to visible list
            if var apps = updatesBySource[app.source] {
                apps.append(refreshedApp)
                // Sort alphabetically after adding using sortKey extension
                apps.sort { $0.appInfo.appName.sortKey < $1.appInfo.appName.sortKey }
                updatesBySource[app.source] = apps
            } else {
                updatesBySource[app.source] = [refreshedApp]
            }
        }
        // If nil returned, no update available anymore - don't add to visible list
    }

    /// Toggle selection state for an app in the update queue
    func toggleAppSelection(_ app: UpdateableApp) {
        guard var apps = updatesBySource[app.source],
              let index = apps.firstIndex(where: { $0.id == app.id }) else { return }

        apps[index].isSelectedForUpdate.toggle()
        updatesBySource[app.source] = apps
    }

    func scanForUpdates(forceReload: Bool = false, sources: Set<UpdateSource>? = nil) async {
        // Double-check to prevent race condition where multiple scans pass the guard
        guard !isScanning else { return }
        isScanning = true
        defer {
            isScanning = false
            scanningSources.removeAll()  // Always clear scanning state on exit
            currentScanTask = nil
        }

        // Determine which sources to scan
        var sourcesToScan: Set<UpdateSource>
        if let sources = sources {
            // Selective scan - only scan specified sources
            sourcesToScan = sources

            // Only clear specified sources from updatesBySource (preserve others)
            for source in sources {
                updatesBySource[source] = nil
                currentAppPathsBySource[source] = nil
                scanFailuresBySource[source] = nil
            }
            // Don't clear hiddenUpdates - will be rebuilt at end
        } else {
            // Full scan - scan all enabled sources (current behavior)
            sourcesToScan = []
            if checkAppStore { sourcesToScan.insert(.appStore) }
            if checkHomebrew { sourcesToScan.insert(.homebrew) }
            if checkSparkle { sourcesToScan.insert(.sparkle) }

            // Clear all results
            updatesBySource = [:]
            hiddenUpdates = []  // Clear to prevent stale entries (will be rebuilt from persistent storage)
            currentAppPathsBySource = [:]
            scanFailuresBySource = [:]
        }

        scanningSources = sourcesToScan

        // Only flush caches and reload apps if explicitly requested or debug mode enabled
        // This significantly improves performance for regular update checks
        if forceReload || debugLogging || AppState.shared.sortedApps.isEmpty {
            // Flush bundle caches (useful for testing with fake versions in debug mode)
            Pearcleaner.flushBundleCaches(for: AppState.shared.sortedApps)

            // Reload apps from disk to detect newly installed/uninstalled apps
            let folderPaths = await MainActor.run {
                FolderSettingsManager.shared.folderPaths
            }
            await loadAppsAsync(folderPaths: folderPaths, useStreaming: false)
        }

        // Check for cancellation after loading apps
        if Task.isCancelled {
            return
        }

        // Use apps from AppState (either freshly loaded or existing)
        let apps = AppState.shared.sortedApps

        // Launch concurrent scans with progressive updates
        await withTaskGroup(of: (UpdateSource, UpdateCheckResults).self) { group in
            if sourcesToScan.contains(.homebrew) {
                group.addTask {
                    let results = await HomebrewUpdateChecker.checkForUpdates(apps: apps, includeFormulae: false, showAutoUpdatesInHomebrew: self.showAutoUpdatesInHomebrew)
                    return (.homebrew, results)
                }
            }

            if sourcesToScan.contains(.appStore) {
                group.addTask {
                    // Use pre-categorized flag (instant check vs expensive receipt verification)
                    let appStoreApps = apps.filter { $0.isAppStore }
                    let results = await AppStoreUpdateChecker.checkForUpdates(apps: appStoreApps)
                    return (.appStore, results)
                }
            }

            if sourcesToScan.contains(.sparkle) {
                group.addTask {
                    // App Store receipts are authoritative. MAS builds may
                    // contain stale Sparkle metadata that is not usable.
                    let sparkleApps = apps.filter { $0.hasSparkle && !$0.isAppStore }

                    let results = await SparkleUpdateChecker.checkForUpdates(apps: sparkleApps, includePreReleases: self.includeSparklePreReleases)
                    return (.sparkle, results)
                }
            }

            // Process results as they complete
            for await (source, results) in group {
                // Check for cancellation between source results
                if Task.isCancelled {
                    break
                }
                currentAppPathsBySource[source] = results.currentAppPaths
                scanFailuresBySource[source] = results.failures
                await processSourceResults(source: source, apps: results.updates)
            }
        }

        // Check for cancellation before final processing
        if Task.isCancelled {
            return
        }

        // Deduplicate: Remove Homebrew apps that also exist in Sparkle (when auto_updates=true and toggle is ON)
        // Rationale: If an app has both Homebrew cask and Sparkle framework with auto_updates=true,
        // prefer the developer's choice (built-in Sparkle updater) and avoid showing in both categories
        if showAutoUpdatesInHomebrew, let homebrewApps = updatesBySource[.homebrew], let sparkleApps = updatesBySource[.sparkle] {
            // Build set of Sparkle app paths for quick lookup
            let sparkleAppPaths = Set(sparkleApps.map { $0.appInfo.path })

            // Filter out Homebrew apps that have both:
            // 1. auto_updates=true (developer chose built-in updater)
            // 2. Sparkle framework (exists in Sparkle category)
            let deduplicatedHomebrew = homebrewApps.filter { brewApp in
                guard let autoUpdates = brewApp.appInfo.autoUpdates, autoUpdates else {
                    return true  // Keep: no auto_updates flag
                }

                // Exclude if app also exists in Sparkle (prefer Sparkle)
                return !sparkleAppPaths.contains(brewApp.appInfo.path)
            }

            // Update with deduplicated list
            updatesBySource[.homebrew] = deduplicatedHomebrew
        }

        // Calculate unsupported apps (always calculate - it's instant, toggle only controls UI visibility)
        let unsupportedApps = apps.filter { app in
            // Not a web app (web apps update with browser)
            !app.webApp &&
            // Not an App Store app
            !app.isAppStore &&
            // Not a Homebrew cask/formula
            app.cask == nil &&
            // Doesn't have Sparkle
            !app.hasSparkle
        }.map { app in
            // Create UpdateableApp with unsupported source
            UpdateableApp(
                appInfo: app,
                availableVersion: nil,  // Can't check updates
                availableBuildNumber: nil,
                source: .unsupported,
                adamID: nil,
                appStoreURL: nil,
                status: .idle,
                progress: 0.0,
                isSelectedForUpdate: false,  // Can't update unsupported apps
                releaseTitle: nil,
                releaseDescription: nil,
                releaseNotesLink: nil,
                releaseDate: nil,
                isPreRelease: false,
                isIOSApp: false,
                foundInRegion: nil,
                appcastItem: nil
            )
        }

        await processSourceResults(source: .unsupported, apps: unsupportedApps)

        // Calculate current apps (supported but up-to-date - no updates available)
        let currentApps = apps.filter { app in
            // Not a web app
            !app.webApp &&
            // Every enabled source applicable to this app must explicitly
            // confirm it is current. A missing result may represent an error.
            isConfirmedCurrent(app) &&
            // But doesn't have an update available in any of the update sources
            !updatesBySource.values.flatMap { $0 }.contains(where: { $0.appInfo.path == app.path })
        }.map { app in
            // Create UpdateableApp with current source
            UpdateableApp(
                appInfo: app,
                availableVersion: app.appVersion,  // Already up-to-date
                availableBuildNumber: nil,
                source: .current,
                adamID: nil,
                appStoreURL: nil,
                status: .idle,
                progress: 0.0,
                isSelectedForUpdate: false,  // Already current, no update needed
                releaseTitle: nil,
                releaseDescription: nil,
                releaseNotesLink: nil,
                releaseDate: nil,
                isPreRelease: false,
                isIOSApp: false,
                foundInRegion: nil,
                fetchedReleaseNotes: nil,
                appcastItem: nil
            )
        }

        await processSourceResults(source: .current, apps: currentApps)

        // Rebuild hidden apps list for display
        // This ensures ALL hidden apps appear in the sidebar, even those without updates
        await rebuildHiddenAppsList(allApps: apps)

        lastScanDate = Date()

        let failureCount = scanFailuresBySource.values.reduce(0) { $0 + $1.count }
        if failureCount > 0 {
            GlobalConsoleManager.shared.appendOutput(
                "⚠ Could not verify updates for \(failureCount) app(s); they were not marked as current\n",
                source: CurrentPage.updater.title
            )
        }

        // Print formatted debug report to console after scan completes
        if debugLogging {
            printOS("\n" + UpdaterDebugLogger.shared.generateDebugReport())
        }

    }

    private func isConfirmedCurrent(_ app: AppInfo) -> Bool {
        var applicableSources: [UpdateSource] = []

        if checkAppStore, app.isAppStore {
            applicableSources.append(.appStore)
        }
        if checkHomebrew,
           app.cask != nil,
           !(app.autoUpdates == true && !showAutoUpdatesInHomebrew) {
            applicableSources.append(.homebrew)
        }
        if checkSparkle, app.hasSparkle, !app.isAppStore {
            applicableSources.append(.sparkle)
        }

        guard !applicableSources.isEmpty else { return false }
        return applicableSources.allSatisfy {
            currentAppPathsBySource[$0]?.contains(app.path) == true
        }
    }

    /// Rebuild hidden apps list from storage for display in sidebar
    /// This populates hiddenUpdates with ALL hidden apps (even those without updates)
    private func rebuildHiddenAppsList(allApps: [AppInfo]) async {
        let hidden = hiddenApps

        // For each hidden app in storage, create an UpdateableApp for display
        for (bundleID, source) in hidden {
            // Skip if already in hiddenUpdates (was found during update check)
            if hiddenUpdates.contains(where: { $0.uniqueIdentifier == bundleID }) {
                continue
            }

            // Find the app in sortedApps
            guard let appInfo = allApps.first(where: { $0.bundleIdentifier == bundleID }) else {
                // App no longer exists, remove from hidden storage
                var mutableHidden = hidden
                mutableHidden.removeValue(forKey: bundleID)
                hiddenApps = mutableHidden
                continue
            }

            // Create UpdateableApp without update info (just for display)
            let updateableApp = UpdateableApp(
                appInfo: appInfo,
                availableVersion: nil,
                availableBuildNumber: nil,
                source: source,
                adamID: nil,
                appStoreURL: nil,
                status: .idle,
                progress: 0.0,
                isSelectedForUpdate: false,
                releaseTitle: nil,
                releaseDescription: nil,
                releaseNotesLink: nil,
                releaseDate: nil,
                isPreRelease: false,
                isIOSApp: false,
                foundInRegion: nil,
                appcastItem: nil
            )

            hiddenUpdates.append(updateableApp)
        }
    }

    private func processSourceResults(source: UpdateSource, apps: [UpdateableApp]) async {
        // Sort alphabetically
        let sortedApps = apps.sorted { $0.appInfo.appName.sortKey < $1.appInfo.appName.sortKey }

        // Filter ignored and version-skipped apps
        let ignored = ignoredApps
        let visible = sortedApps.filter { app in
            // Check if app is in ignored list
            guard let ignoredVersions = ignored[app.uniqueIdentifier],
                  let ignoredVersion = ignoredVersions[source.rawValue] else {
                return true // Not ignored, show it
            }

            // If ignoredVersion is nil, permanently ignored
            if ignoredVersion == nil {
                return false
            }

            // If ignoredVersion matches availableVersion, skip this version
            if let availableVersion = app.availableVersion,
               availableVersion == ignoredVersion {
                return false
            }

            // Newer version available, show it
            return true
        }
        let hiddenAppsFromSource = sortedApps.filter { app in
            guard let ignoredVersions = ignored[app.uniqueIdentifier],
                  let ignoredVersion = ignoredVersions[source.rawValue] else {
                return false
            }
            return ignoredVersion == nil || app.availableVersion == ignoredVersion
        }

        // Update results (set to empty array even if no visible results to indicate "completed")
        updatesBySource[source] = visible

        // Add hidden apps to hidden list
        for app in hiddenAppsFromSource {
            if !hiddenUpdates.contains(where: { $0.uniqueIdentifier == app.uniqueIdentifier }) {
                hiddenUpdates.append(app)
            }
        }

        // Mark source as no longer scanning
        scanningSources.remove(source)
    }

    /// Cancel the current scan operation
    func cancelScan() {
        currentScanTask?.cancel()
    }

    /// Remove pre-release apps from a specific source without rescanning
    /// This is more efficient than rescanning when toggling off pre-releases
    func removePreReleaseApps(from source: UpdateSource) {
        guard var apps = updatesBySource[source] else { return }

        // Filter out pre-release apps
        apps = apps.filter { !$0.isPreRelease }

        // Update the source with filtered apps
        updatesBySource[source] = apps
    }

    func updateApp(_ app: UpdateableApp) async {
        switch app.source {
        case .homebrew:
            if let cask = app.appInfo.cask {
                GlobalConsoleManager.shared.appendOutput("Starting Homebrew update for \(app.appInfo.appName) (\(cask))...\n", source: CurrentPage.updater.title)

                // Update the app status
                if var apps = updatesBySource[.homebrew],
                   let index = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[index].status = .downloading
                    updatesBySource[.homebrew] = apps
                }

                // Perform upgrade
                do {
                    try await HomebrewController.shared.upgradePackage(name: cask, isCask: true)

                    GlobalConsoleManager.shared.appendOutput("✓ Successfully updated \(app.appInfo.appName) to version \(app.availableVersion ?? "unknown")\n", source: CurrentPage.updater.title)

                    // Only remove from list if upgrade succeeded
                    updatesBySource[.homebrew]?.removeAll { $0.id == app.id }

                    // Refresh apps (only flush updated app's bundle for performance)
                    await refreshApps(updatedApp: app.appInfo)
                } catch {
                    GlobalConsoleManager.shared.appendOutput("✗ Failed to update \(app.appInfo.appName): \(error.localizedDescription)\n", source: CurrentPage.updater.title)

                    // Update status to failed on error
                    if var apps = updatesBySource[.homebrew],
                       let index = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[index].status = .failed(error.localizedDescription)
                        apps[index].progress = 0.0  // Reset progress indicator
                        updatesBySource[.homebrew] = apps
                    }
                    printOS("Error updating Homebrew package \(cask): \(error)")
                }
            }

        case .appStore:
            guard let url = appStoreURL(for: app), NSWorkspace.shared.open(url) else {
                let message = "Could not open this app in the App Store"
                updateStatus(for: app, status: .failed(message), progress: 0)
                GlobalConsoleManager.shared.appendOutput("✗ \(message): \(app.appInfo.appName)\n", source: CurrentPage.updater.title)
                return
            }
            GlobalConsoleManager.shared.appendOutput("Opened \(app.appInfo.appName) in the App Store. Install the update there.\n", source: CurrentPage.updater.title)

        case .sparkle:
            // Use Sparkle's updater via UpdateQueue to prevent concurrent update conflicts
            // SPUUpdater will automatically get feed URL from Info.plist via delegate

            // Check if update already queued/running for this app
            if UpdateQueue.shared.containsOperation(for: app.appInfo.bundleIdentifier) {
                UpdaterDebugLogger.shared.log(.sparkle, "⚠️ Update already queued for \(app.appInfo.appName)")
                printOS("Update already queued for \(app.appInfo.appName)")
                GlobalConsoleManager.shared.appendOutput("⚠ Update already queued for \(app.appInfo.appName)\n", source: CurrentPage.updater.title)
                return
            }

            GlobalConsoleManager.shared.appendOutput("Starting Sparkle update for \(app.appInfo.appName) (target version: \(app.availableVersion ?? "unknown"))...\n", source: CurrentPage.updater.title)

            UpdaterDebugLogger.shared.log(.sparkle, "═══ Initiating update for \(app.appInfo.appName)")
            UpdaterDebugLogger.shared.log(.sparkle, "  Bundle ID: \(app.appInfo.bundleIdentifier)")
            UpdaterDebugLogger.shared.log(.sparkle, "  Current version: \(app.appInfo.appVersion)")
            UpdaterDebugLogger.shared.log(.sparkle, "  Target version: \(app.availableVersion ?? "unknown")")

            // Set initial downloading status
            updateStatus(for: app, status: .downloading, progress: 0.0)

            // Wait for the queued operation to finish so batch updates and their
            // progress do not report completion while Sparkle is still running.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let operation = SparkleUpdateOperation(
                    app: app,
                    includePreReleases: self.includeSparklePreReleases,
                    progressCallback: { [weak self] progress, status in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.updateStatus(for: app, status: status, progress: progress)
                        }
                    },
                    completionCallback: { [weak self] success, error in
                        Task { @MainActor in
                            guard let self = self else {
                                continuation.resume()
                                return
                            }
                            if success {
                                UpdaterDebugLogger.shared.log(.sparkle, "═══ Update completed successfully for \(app.appInfo.appName)")
                                GlobalConsoleManager.shared.appendOutput("✓ Successfully updated \(app.appInfo.appName) via Sparkle\n", source: CurrentPage.updater.title)
                                await self.removeFromUpdatesList(appID: app.id, source: .sparkle)
                                await self.refreshApps(updatedApp: app.appInfo)
                            } else {
                                let message = error?.localizedDescription ?? "Unknown error"
                                UpdaterDebugLogger.shared.log(.sparkle, "═══ Update failed for \(app.appInfo.appName): \(message)")
                                GlobalConsoleManager.shared.appendOutput("✗ Failed to update \(app.appInfo.appName) via Sparkle: \(message)\n", source: CurrentPage.updater.title)
                                self.updateStatus(for: app, status: .failed(message), progress: 0.0)
                            }
                            continuation.resume()
                        }
                    }
                )
                UpdateQueue.shared.addOperation(operation)
            }

        case .unsupported:
            // Unsupported apps cannot be updated - do nothing
            UpdaterDebugLogger.shared.log(.sparkle, "⚠️ Cannot update unsupported app: \(app.appInfo.appName)")
            break

        case .current:
            // Current apps are already up-to-date - do nothing
            UpdaterDebugLogger.shared.log(.sparkle, "ℹ️ App is already current: \(app.appInfo.appName)")
            break
        }
    }

    /// Update an iOS app from the App Store
    func updateIOSApp(_ app: UpdateableApp) async {
        guard app.isIOSApp else { return }
        await updateApp(app)
    }

    func updateAll(source: UpdateSource) async {
        guard let apps = updatesBySource[source] else { return }

        // Only update apps that are selected for update
        let selectedApps = apps.filter { $0.isSelectedForUpdate }

        GlobalConsoleManager.shared.appendOutput("Starting batch update for \(selectedApps.count) app(s) from \(source.rawValue)...\n", source: CurrentPage.updater.title)

        for app in selectedApps {
            await updateApp(app)
        }

        GlobalConsoleManager.shared.appendOutput("Batch update completed for \(source.rawValue)\n", source: CurrentPage.updater.title)
    }

    /// Update all selected apps across all sources (concurrent per-source)
    func updateSelectedApps() async {
        // Use the same app-centric ownership decision as the UI. This keeps an
        // App Store-owned app out of Update All even if Sparkle also reports it,
        // and prevents an alternate source from running behind the visible row.
        let candidates = appCentricItems
            .filter { $0.section == .available }
            .compactMap(\.primaryApp)
            .filter { $0.isSelectedForUpdate }

        // The same bundle can be reported by both Homebrew and Sparkle. Never
        // run two installers against it concurrently; honor Homebrew ownership
        // when both sources were selected.
        var selectedByPath: [URL: UpdateableApp] = [:]
        for app in candidates.sorted(by: { batchPriority($0.source) < batchPriority($1.source) }) {
            if selectedByPath[app.appInfo.path] == nil {
                selectedByPath[app.appInfo.path] = app
            }
        }
        let selectedApps = Array(selectedByPath.values)

        totalAppsToUpdate = selectedApps.count
        completedAppsInBatch = 0
        isUpdatingAll = true

        defer {
            isUpdatingAll = false
            totalAppsToUpdate = 0
            completedAppsInBatch = 0
        }

        GlobalConsoleManager.shared.appendOutput("Starting updates for \(selectedApps.count) selected app(s) across all sources...\n", source: CurrentPage.updater.title)

        await withTaskGroup(of: Void.self) { group in
            // Process each source's updates concurrently in separate Tasks
            for source in [UpdateSource.homebrew, .sparkle] {
                let sourceApps = selectedApps.filter { $0.source == source }
                if !sourceApps.isEmpty {
                    group.addTask {
                        // Within each source, process apps sequentially
                        for app in sourceApps {
                            await self.updateApp(app)
                            await self.markBatchItemCompleted()
                        }
                    }
                }
            }
        }

        GlobalConsoleManager.shared.appendOutput("All selected updates completed\n", source: CurrentPage.updater.title)
    }

    private func markBatchItemCompleted() {
        completedAppsInBatch += 1
    }

    private func batchPriority(_ source: UpdateSource) -> Int {
        source == .homebrew ? 0 : 1
    }

    private func appStoreURL(for app: UpdateableApp) -> URL? {
        let rawURL = app.appStoreURL ?? app.adamID.map { "https://apps.apple.com/app/id\($0)" }
        guard let rawURL, var components = URLComponents(string: rawURL) else { return nil }
        components.scheme = "macappstore"
        return components.url
    }

    /// Update the status and progress of an app in the updates list
    private func updateStatus(for app: UpdateableApp, status: UpdateStatus, progress: Double) {
        if var apps = updatesBySource[app.source],
           let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].status = status
            apps[index].progress = progress
            updatesBySource[app.source] = apps
        }
    }

    // REMOVED: refreshSparkleAppWithURL - no longer needed with simplified Sparkle approach
    // Alternate feed URLs are not supported when using SPUUpdater directly

    /// Remove an app from the updates list
    private func removeFromUpdatesList(appID: UUID, source: UpdateSource) async {
        updatesBySource[source]?.removeAll { $0.id == appID }
    }

    /// Refresh all apps after an update
    /// - Parameter updatedApp: Optional specific app that was updated (only flushes that bundle for performance)
    private func refreshApps(updatedApp: AppInfo? = nil) async {
        let folderPaths = await MainActor.run {
            FolderSettingsManager.shared.folderPaths
        }

        // Only flush cache for the app that was just updated (or all if none specified)
        if let app = updatedApp {
            Pearcleaner.flushBundleCaches(for: [app])
        } else {
            Pearcleaner.flushBundleCaches(for: AppState.shared.sortedApps)
        }

        await loadAppsAsync(folderPaths: folderPaths, useStreaming: false)
    }
}
