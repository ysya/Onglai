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
    private var reportedUpdatePathsBySource: [UpdateSource: Set<URL>] = [:]

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
    private var checkElectron: Bool { sources.electron.enabled }
    private var showAutoUpdatesInHomebrew: Bool { sources.homebrew.showAutoUpdates }
    private var includeSparklePreReleases: Bool { sources.sparkle.includePreReleases }
    private var showUnsupported: Bool { display.showUnsupported }
    private var showCurrent: Bool { display.showCurrent }

    private let defaults: UserDefaults
    private let openURL: (URL) -> Bool
    private var hasAutoScannedOnce = false
    private var pendingScanSources: Set<UpdateSource> = []
    private var managedSparkleOverrides: [URL: ManagedUpdateMechanism] = [:]

    private func isSourceEnabled(_ source: UpdateSource) -> Bool {
        sources.enabledSources.contains(source)
    }

    func sourceSettingsDidChange(_ source: UpdateSource, enabled: Bool) async {
        var settings = sources
        switch source {
        case .homebrew: settings.homebrew.enabled = enabled
        case .sparkle: settings.sparkle.enabled = enabled
        case .appStore: settings.appStore.enabled = enabled
        case .electron: settings.electron.enabled = enabled
        case .official: settings.official.enabled = enabled
        case .catalog: settings.catalog.enabled = enabled
        case .managed, .unsupported, .current: return
        }
        sources = settings
        updatesBySource[source] = nil
        currentAppPathsBySource[source] = nil
        reportedUpdatePathsBySource[source] = nil
        scanFailuresBySource[source] = nil
        hiddenUpdates.removeAll { $0.source == source }
        if source == .sparkle { managedSparkleOverrides = [:] }
        if enabled {
            if isScanning { pendingScanSources.insert(source) }
            else {
                let task = Task { await self.scanIfNeeded(sources: [source]) }
                currentScanTask = task
                await task.value
            }
        } else {
            pendingScanSources.remove(source)
            scanningSources.remove(source)
            await rebuildDerivedResults(apps: AppState.shared.sortedApps)
        }
    }

    init(defaults: UserDefaults = .standard, observesAppLoading: Bool = true,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.openURL = openURL
        _sourcesData = AppStorage(wrappedValue: UpdaterSourcesSettings.defaultEncoded(), "settings.updater.sources", store: defaults)
        _displayData = AppStorage(wrappedValue: UpdaterDisplaySettings.defaultEncoded(), "settings.updater.display", store: defaults)
        _debugLogging = AppStorage(wrappedValue: false, "settings.updater.debugLogging", store: defaults)
        _hiddenAppsData = AppStorage(wrappedValue: Data(), "settings.updater.hiddenAppsData", store: defaults)
        _ignoredAppsData = AppStorage(wrappedValue: Data(), "settings.updater.ignoredAppsData", store: defaults)
        // Migrate old settings to new consolidated format
        migrateSettingsIfNeeded()

        // Migrate old hiddenApps data to new ignoredApps format on first launch
        migrateHiddenAppsIfNeeded()

        // Subscribe to notification for automatic background scanning
        guard observesAppLoading else { return }
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
            let oldCheckAppStore = defaults.bool(forKey: "settings.updater.checkAppStore")
            let oldCheckHomebrew = defaults.bool(forKey: "settings.updater.checkHomebrew")
            let oldCheckSparkle = defaults.bool(forKey: "settings.updater.checkSparkle")
            let oldShowAutoUpdates = defaults.bool(forKey: "settings.updater.showAutoUpdatesInHomebrew")
            let oldIncludePreReleases = defaults.bool(forKey: "settings.updater.includeSparklePreReleases")

            // Check if any old settings exist (they default to false if never set)
            let hasOldSettings = defaults.object(forKey: "settings.updater.checkAppStore") != nil ||
                                defaults.object(forKey: "settings.updater.checkHomebrew") != nil ||
                                defaults.object(forKey: "settings.updater.checkSparkle") != nil

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
            let oldShowUnsupported = defaults.bool(forKey: "settings.updater.showUnsupported")

            if defaults.object(forKey: "settings.updater.showUnsupported") != nil {
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
        appCentricItems.filter { $0.section == .available || $0.section == .external }.count
    }

    /// Presents one row per installed app instead of one row per update source.
    /// The underlying source results remain intact so existing update and detail
    /// flows can continue to operate on their original records.
    var appCentricItems: [UpdaterListItem] {
        let sourceApps = updatesBySource.filter {
            isSourceEnabled($0.key) || [.current, .managed, .unsupported].contains($0.key)
        }.values.flatMap { $0 }
        let actionableApps = sourceApps.filter {
            $0.source != .current && $0.source != .managed && $0.source != .unsupported
        }
        var items: [UpdaterListItem] = []

        for (_, candidates) in Dictionary(grouping: actionableApps, by: { $0.appInfo.path.standardizedFileURL }) {
            guard let primary = preferredUpdate(from: candidates) else { continue }
            items.append(
                UpdaterListItem(
                    id: "update:\(primary.appInfo.path.standardizedFileURL.path)",
                    section: primary.canUpdate ? .available : .external,
                    appInfo: primary.appInfo,
                    primaryApp: primary,
                    alternateApps: candidates.filter { $0.id != primary.id },
                    issues: []
                )
            )
        }

        let pathsWithUpdates = Set(actionableApps.map { $0.appInfo.path.standardizedFileURL })
        var issuesByPath: [URL: [UpdaterSourceIssue]] = [:]
        for (source, failures) in scanFailuresBySource where isSourceEnabled(source) {
            for failure in failures {
                let path = failure.appPath.standardizedFileURL
                guard !pathsWithUpdates.contains(path) else { continue }
                issuesByPath[path, default: []].append(
                    UpdaterSourceIssue(source: source, message: failure.message, kind: failure.kind)
                )
            }
        }

        let confirmedCurrentPaths = Set((updatesBySource[.current] ?? []).filter {
            isConfirmedCurrent($0.appInfo)
        }.map { $0.appInfo.path.standardizedFileURL })
        for (path, issues) in issuesByPath {
            let isUnavailable = issues.allSatisfy { $0.kind == .unavailable }
            if isUnavailable && confirmedCurrentPaths.contains(path) { continue }
            let appInfo = AppState.shared.sortedApps.first { $0.path.standardizedFileURL == path }
            let isUnsupportedConfiguration = issues.allSatisfy {
                $0.message == SparkleUpdateChecker.invalidFeedConfigurationMessage ||
                $0.message == SparkleUpdateChecker.invalidSigningConfigurationMessage
            }
            items.append(
                UpdaterListItem(
                    id: "issue:\(path.path)",
                    section: isUnsupportedConfiguration ? .unsupported : (isUnavailable ? .unverified : .attention),
                    appInfo: appInfo,
                    primaryApp: nil,
                    alternateApps: [],
                    issues: issues.sorted { $0.source.rawValue < $1.source.rawValue }
                )
            )
        }

        for source in [UpdateSource.current, .managed, .unsupported] {
            let section: UpdaterItemSection
            switch source {
            case .current: section = .current
            case .managed: section = .managed
            default: section = .unsupported
            }
            for app in updatesBySource[source] ?? [] {
                if source == .current && !isConfirmedCurrent(app.appInfo) { continue }
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
        if app.source == .official { return 3 }
        if app.source == .electron { return 4 }
        if app.source == .catalog { return 6 }
        if app.source == .homebrew { return 5 }
        if app.source == .appStore { return 7 }
        return 8
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
        guard let value = ignoredApps[app.uniqueIdentifier]?[app.source.rawValue] ?? nil else { return nil }
        let fields = value.components(separatedBy: "|build=")
        guard fields.count == 2, !fields[0].hasSuffix("+" + fields[1]) else { return fields[0] }
        return fields[0] + " (" + fields[1] + ")"
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
        let path = app.appInfo.path.standardizedFileURL
        let candidates = updatesBySource.values.flatMap { $0 }.filter {
            $0.appInfo.path.standardizedFileURL == path
        }
        var ignored = ignoredApps
        var versions = ignored[app.uniqueIdentifier] ?? [:]
        let selectedVersion = skipVersion == app.availableVersion ? versionIdentity(for: app) : skipVersion
        if skipVersion == nil {
            // The list presents one app, so permanent hiding applies to every source.
            for source in UpdateSource.allCases { versions[source.rawValue] = .some(nil) }
            var hidden = hiddenApps
            hidden[app.uniqueIdentifier] = app.source
            hiddenApps = hidden
        } else {
            // Each provider may spell the same release differently; skip the
            // version it actually reported so an alternate cannot resurface.
            for candidate in candidates + [app] where versionsMatch(versionIdentity(for: candidate), selectedVersion) {
                versions[candidate.source.rawValue] = .some(selectedVersion)
            }
        }
        ignored[app.uniqueIdentifier] = versions
        ignoredApps = ignored
        for source in updatesBySource.keys {
            updatesBySource[source]?.removeAll {
                $0.appInfo.path.standardizedFileURL == path &&
                    (skipVersion == nil || versionsMatch(versionIdentity(for: $0), selectedVersion))
            }
        }
        if !hiddenUpdates.contains(where: { $0.uniqueIdentifier == app.uniqueIdentifier }) {
            hiddenUpdates.append(app)
        }
    }

    /// Rescan a single app to get fresh update data
    func recheckUpdate(for app: UpdateableApp) async -> UpdateableApp? {
        guard isSourceEnabled(app.source),
              let freshAppInfo = AppState.shared.sortedApps.first(where: {
                  $0.path.standardizedFileURL == app.appInfo.path.standardizedFileURL
              }) else { return nil }

        let checkedRuleRevision = UpdaterRuleStore.shared.snapshot.revision
        let results: UpdateCheckResults
        switch app.source {
        case .homebrew:
            results = await HomebrewUpdateChecker.checkForUpdates(
                apps: [freshAppInfo], includeFormulae: false,
                showAutoUpdatesInHomebrew: showAutoUpdatesInHomebrew
            )
        case .appStore:
            results = await AppStoreUpdateChecker.checkForUpdates(apps: [freshAppInfo])
        case .sparkle:
            results = await SparkleUpdateChecker.checkForUpdates(
                apps: [freshAppInfo], includePreReleases: includeSparklePreReleases
            )
        case .official:
            results = await OfficialUpdateChecker.checkForUpdates(apps: [freshAppInfo])
        case .catalog:
            results = await CatalogUpdateChecker.checkForUpdates(apps: [freshAppInfo])
        case .electron:
            results = await ElectronUpdateChecker.checkForUpdates(apps: [freshAppInfo])
        case .managed, .unsupported, .current:
            return nil
        }
        guard isSourceEnabled(app.source) else { return nil }
        let path = freshAppInfo.path.standardizedFileURL
        guard recordSourceEvidence(results, source: app.source, replacingAppPaths: [path],
                                   checkedRuleRevision: checkedRuleRevision) else { return nil }
        var visible = updatesBySource[app.source] ?? []
        visible.removeAll { $0.appInfo.path.standardizedFileURL == path }
        visible.append(contentsOf: results.updates)
        await processSourceResults(source: app.source, apps: visible)
        await rebuildDerivedResults(apps: AppState.shared.sortedApps)
        return results.updates.first
    }

    /// Restore every source for an app hidden from the app-centric list.
    func unhideApp(_ app: UpdateableApp) async {
        var ignored = ignoredApps
        let sourceNames = ignored.removeValue(forKey: app.uniqueIdentifier)?.keys.map { $0 } ?? [app.source.rawValue]
        ignoredApps = ignored
        var hidden = hiddenApps
        hidden.removeValue(forKey: app.uniqueIdentifier)
        hiddenApps = hidden
        hiddenUpdates.removeAll { $0.uniqueIdentifier == app.uniqueIdentifier }

        for source in sourceNames.compactMap(UpdateSource.init(rawValue:)) where isSourceEnabled(source) {
            // Reconstruct the source record without relying on a stale hidden row.
            let candidate = UpdateableApp(
                appInfo: app.appInfo, availableVersion: nil, availableBuildNumber: nil,
                source: source, adamID: app.adamID, appStoreURL: app.appStoreURL,
                isSelectedForUpdate: false, releaseTitle: nil, releaseDescription: nil,
                releaseNotesLink: nil, releaseDate: nil, isPreRelease: false,
                isIOSApp: app.isIOSApp, foundInRegion: nil, appcastItem: nil
            )
            _ = await recheckUpdate(for: candidate)
        }
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
            let pending = pendingScanSources.intersection(self.sources.enabledSources)
            pendingScanSources.removeAll()
            if !Task.isCancelled, !pending.isEmpty {
                currentScanTask = Task { await self.scanIfNeeded(sources: pending) }
            }
        }

        // Determine which sources to scan
        var sourcesToScan: Set<UpdateSource>
        if let sources = sources {
            // Selective scan - only scan specified sources
            sourcesToScan = sources.intersection(self.sources.enabledSources)

            // Only clear specified sources from updatesBySource (preserve others)
            for source in sources {
                updatesBySource[source] = nil
                currentAppPathsBySource[source] = nil
                reportedUpdatePathsBySource[source] = nil
                scanFailuresBySource[source] = nil
            }
            // Don't clear hiddenUpdates - will be rebuilt at end
        } else {
            // Full scan - scan all enabled sources (current behavior)
            sourcesToScan = []
            sourcesToScan = self.sources.enabledSources
            managedSparkleOverrides = [:]

            // Clear all results
            updatesBySource = [:]
            hiddenUpdates = []  // Clear to prevent stale entries (will be rebuilt from persistent storage)
            currentAppPathsBySource = [:]
            reportedUpdatePathsBySource = [:]
            scanFailuresBySource = [:]
        }

        scanningSources = sourcesToScan
        if sourcesToScan.contains(.sparkle) { managedSparkleOverrides = [:] }
        guard !sourcesToScan.isEmpty else {
            await rebuildDerivedResults(apps: AppState.shared.sortedApps)
            return
        }

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

        // Refresh data rules once before taking source snapshots. A failed
        // refresh keeps the last validated or bundled rules and creates no app error.
        let previousRuleRevision = UpdaterRuleStore.shared.snapshot.revision
        if !sourcesToScan.isDisjoint(with: [.sparkle, .official, .catalog]) {
            await UpdaterRuleStore.shared.refreshIfNeeded(force: forceReload)
        }
        guard !Task.isCancelled else { return }
        let checkedRuleRevision = UpdaterRuleStore.shared.snapshot.revision
        sourcesToScan = sourcesAfterRuleRefresh(from: previousRuleRevision, to: checkedRuleRevision, requested: sourcesToScan)
        scanningSources = sourcesToScan

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

            if sourcesToScan.contains(.electron) {
                group.addTask {
                    let electronApps = apps.filter(ElectronUpdateChecker.isEligible)
                    let results = await ElectronUpdateChecker.checkForUpdates(apps: electronApps)
                    return (.electron, results)
                }
            }

            if sourcesToScan.contains(.official) {
                group.addTask {
                    (.official, await OfficialUpdateChecker.checkForUpdates(apps: apps))
                }
            }
            if sourcesToScan.contains(.catalog) {
                group.addTask {
                    (.catalog, await CatalogUpdateChecker.checkForUpdates(apps: apps))
                }
            }

            // Process results as they complete
            for await (source, results) in group {
                // Check for cancellation between source results
                if Task.isCancelled {
                    break
                }
                guard isSourceEnabled(source) else { continue }
                guard recordSourceEvidence(results, source: source, checkedRuleRevision: checkedRuleRevision) else { continue }
                UpdaterDebugLogger.shared.log(source, "Completed: \(results.updates.count) updates, \(results.currentAppPaths.count) current, \(results.failures.count) failed checks")
                await processSourceResults(source: source, apps: results.updates)
            }
        }

        // Check for cancellation before final processing
        if Task.isCancelled {
            return
        }

        await rebuildDerivedResults(apps: apps)
        lastScanDate = Date()
        if debugLogging { printOS("\n" + UpdaterDebugLogger.shared.generateDebugReport()) }
    }

    func rebuildDerivedResults(apps: [AppInfo]) async {
        // Rebuild presentation classes from current enabled-source evidence.
        updatesBySource[.managed] = nil
        updatesBySource[.unsupported] = nil
        updatesBySource[.current] = nil
        // Sparkle apps with runtime-only feeds or unusable external signing are
        // not truly unsupported: the host app still owns a working update path.
        var managedOverrides = managedSparkleOverrides
        if let sparkleFailures = scanFailuresBySource[.sparkle] {
            let externallyUncheckable = sparkleFailures.filter {
                $0.message == SparkleUpdateChecker.invalidFeedConfigurationMessage ||
                $0.message == SparkleUpdateChecker.invalidSigningConfigurationMessage
            }
            for failure in externallyUncheckable {
                managedOverrides[failure.appPath.standardizedFileURL] = ManagedUpdateMechanism(
                    title: String(localized: "Built-in Sparkle updater"),
                    description: String(localized: "This app's Sparkle feed can only be checked safely from inside the app.")
                )
            }
            managedSparkleOverrides = managedOverrides
            scanFailuresBySource[.sparkle] = sparkleFailures.filter {
                $0.message != SparkleUpdateChecker.invalidFeedConfigurationMessage &&
                $0.message != SparkleUpdateChecker.invalidSigningConfigurationMessage
            }
        }

        let pathsWithReportedUpdates = Set(
            updatesBySource.values
                .flatMap { $0 }
                .filter { $0.source != .managed && $0.source != .unsupported && $0.source != .current }
                .map { $0.appInfo.path.standardizedFileURL }
        )

        let extraResolvedPaths = Set([UpdateSource.official, .catalog].filter(isSourceEnabled).flatMap { source -> [URL] in
            let updatePaths = Array(reportedUpdatePathsBySource[source] ?? [])
            let currentPaths = (currentAppPathsBySource[source] ?? []).map { $0.standardizedFileURL }
            let failedPaths = (scanFailuresBySource[source] ?? []).map { $0.appPath.standardizedFileURL }
            return updatePaths + currentPaths + failedPaths
        })

        let managedApps = apps.compactMap { app -> UpdateableApp? in
            let path = app.path.standardizedFileURL
            guard !pathsWithReportedUpdates.contains(path),
                  !extraResolvedPaths.contains(path),
                  let mechanism = managedOverrides[path] ?? ManagedUpdateDetector.mechanism(for: app) else {
                return nil
            }

            return UpdateableApp(
                appInfo: app,
                availableVersion: nil,
                availableBuildNumber: nil,
                source: .managed,
                adamID: nil,
                appStoreURL: nil,
                status: .idle,
                progress: 0,
                isSelectedForUpdate: false,
                releaseTitle: mechanism.title,
                releaseDescription: mechanism.description,
                releaseNotesLink: nil,
                releaseDate: nil,
                isPreRelease: false,
                isIOSApp: false,
                foundInRegion: nil,
                appcastItem: nil
            )
        }

        await processSourceResults(source: .managed, apps: managedApps)

        // Calculate unsupported apps (always calculate - it's instant, toggle only controls UI visibility)
        let unsupportedApps = apps.filter { app in
            // Not a web app (web apps update with browser)
            !app.webApp &&
            !extraResolvedPaths.contains(app.path.standardizedFileURL) &&
            // Not an App Store app
            !app.isAppStore &&
            // Not a Homebrew cask/formula
            app.cask == nil &&
            // Doesn't have Sparkle
            !app.hasSparkle &&
            // No Electron metadata, even when the provider must run in-app
            !ElectronUpdateChecker.hasUpdateMetadata(for: app) &&
            // No known vendor-managed updater
            ManagedUpdateDetector.mechanism(for: app) == nil
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

        let failureCount = scanFailuresBySource.values.flatMap { $0 }.filter { $0.kind == .failed }.count
        if failureCount > 0 {
            GlobalConsoleManager.shared.appendOutput(
                "⚠ Could not verify updates for \(failureCount) app(s); they were not marked as current\n",
                source: CurrentPage.updater.title
            )
        }

    }

    func sourcesAfterRuleRefresh(from previousRevision: Int, to revision: Int, requested: Set<UpdateSource>) -> Set<UpdateSource> {
        let requested = requested.intersection(sources.enabledSources)
        guard previousRevision != revision else { return requested }
        let affected = Set([UpdateSource.sparkle, .official, .catalog]).intersection(sources.enabledSources)
        for source in affected {
            updatesBySource[source] = nil
            currentAppPathsBySource[source] = nil
            reportedUpdatePathsBySource[source] = nil
            scanFailuresBySource[source] = nil
        }
        hiddenUpdates.removeAll { affected.contains($0.source) }
        managedSparkleOverrides = [:]
        for source in [UpdateSource.current, .managed, .unsupported] { updatesBySource[source] = nil }
        return requested.union(affected)
    }

    /// Retains source-check evidence independently of presentation filters.
    @discardableResult
    func recordSourceEvidence(_ results: UpdateCheckResults, source: UpdateSource, replacingAppPaths: Set<URL>? = nil, checkedRuleRevision: Int? = nil) -> Bool {
        guard isSourceEnabled(source) else { return false }
        if [.sparkle, .official, .catalog].contains(source), let checkedRuleRevision,
           checkedRuleRevision != UpdaterRuleStore.shared.snapshot.revision { return false }
        let currentPaths = Set(results.currentAppPaths.map(\.standardizedFileURL))
        let updatePaths = Set(results.updates.map { $0.appInfo.path.standardizedFileURL })
        if let replacingAppPaths {
            let paths = Set(replacingAppPaths.map(\.standardizedFileURL))
            if source == .sparkle {
                managedSparkleOverrides = managedSparkleOverrides.filter { !paths.contains($0.key) }
            }
            currentAppPathsBySource[source, default: []].subtract(paths)
            currentAppPathsBySource[source, default: []].formUnion(currentPaths)
            reportedUpdatePathsBySource[source, default: []].subtract(paths)
            reportedUpdatePathsBySource[source, default: []].formUnion(updatePaths)
            scanFailuresBySource[source] = (scanFailuresBySource[source] ?? []).filter {
                !paths.contains($0.appPath.standardizedFileURL)
            } + results.failures
        } else {
            currentAppPathsBySource[source] = currentPaths
            reportedUpdatePathsBySource[source] = updatePaths
            scanFailuresBySource[source] = results.failures
        }
        return true
    }

    func isConfirmedCurrent(_ app: AppInfo) -> Bool {
        var applicableSources: [UpdateSource] = []

        if checkAppStore, app.isAppStore {
            applicableSources.append(.appStore)
        }
        if checkHomebrew,
           app.cask != nil,
           !(app.autoUpdates == true && !showAutoUpdatesInHomebrew) {
            applicableSources.append(.homebrew)
        }
        if checkSparkle, app.hasSparkle, !app.isAppStore,
           managedSparkleOverrides[app.path.standardizedFileURL] == nil {
            applicableSources.append(.sparkle)
        }
        if checkElectron, ElectronUpdateChecker.isEligible(app) {
            applicableSources.append(.electron)
        }

        if isSourceEnabled(.official), OfficialUpdateChecker.isEligible(app) {
            applicableSources.append(.official)
        }
        if isSourceEnabled(.catalog) {
            let path = app.path.standardizedFileURL
            let hasEvidence = currentAppPathsBySource[.catalog]?.contains(path) == true ||
                scanFailuresBySource[.catalog]?.contains { $0.appPath.standardizedFileURL == path } == true ||
                reportedUpdatePathsBySource[.catalog]?.contains(path) == true
            if hasEvidence { applicableSources.append(.catalog) }
        }

        // A source that cannot expose comparable metadata is not a failed
        // freshness check. Another applicable source may still verify currency.
        applicableSources.removeAll { source in
            let limitations = (scanFailuresBySource[source] ?? []).filter {
                $0.appPath.standardizedFileURL == app.path.standardizedFileURL
            }
            return !limitations.isEmpty && limitations.allSatisfy { $0.kind == .unavailable } &&
                reportedUpdatePathsBySource[source]?.contains(app.path.standardizedFileURL) != true
        }
        guard !applicableSources.isEmpty else { return false }
        return applicableSources.allSatisfy {
            currentAppPathsBySource[$0]?.contains(app.path.standardizedFileURL) == true
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

    func processSourceResults(source: UpdateSource, apps: [UpdateableApp]) async {
        // Sort alphabetically
        let sortedApps = apps.sorted { $0.appInfo.appName.sortKey < $1.appInfo.appName.sortKey }

        // Apply the app-centric ignore intent to late results and legacy data.
        let ignored = ignoredApps
        let permanentlyHidden = Set(hiddenApps.keys)
        func isIgnored(_ app: UpdateableApp) -> Bool {
            if permanentlyHidden.contains(app.uniqueIdentifier) { return true }
            guard let versions = ignored[app.uniqueIdentifier] else { return false }
            if versions.values.contains(where: { $0 == nil }) { return true }
            return versions.values.contains { versionsMatch(versionIdentity(for: app), $0) }
        }
        let visible = sortedApps.filter { !isIgnored($0) }
        let hiddenAppsFromSource = sortedApps.filter(isIgnored)
        hiddenUpdates.removeAll { $0.source == source }

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

    private func versionIdentity(for app: UpdateableApp) -> String? {
        guard let version = app.availableVersion else { return nil }
        guard let build = app.availableBuildNumber, !build.isEmpty else { return version }
        return version + "|build=" + build
    }

    private func versionsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = lhs.components(separatedBy: "|build=")
        let right = rhs.components(separatedBy: "|build=")
        let leftVersion = left[0].split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let rightVersion = right[0].split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        // Freshness comparison ignores SemVer build metadata; Skip must retain it.
        guard let leftCore = leftVersion.first, let rightCore = rightVersion.first,
              leftVersion.dropFirst().map(String.init) == rightVersion.dropFirst().map(String.init),
              UpdateVersionComparator.compare(installed: String(leftCore), available: String(rightCore)) == .orderedSame else {
            return lhs == rhs
        }
        if left.count == 2, right.count == 2 { return left[1] == right[1] }
        return true // Legacy ignores and sources without a build retain their version scope.
    }

    /// Cancel the current scan operation and any queued source scans.
    func cancelScan() {
        pendingScanSources.removeAll()
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

        case .electron, .official, .catalog, .managed:
            guard openURL(app.appInfo.path) else {
                let message = "Could not open this app"
                updateStatus(for: app, status: .failed(message), progress: 0)
                GlobalConsoleManager.shared.appendOutput("✗ \(message): \(app.appInfo.appName)\n", source: CurrentPage.updater.title)
                return
            }
            GlobalConsoleManager.shared.appendOutput(
                "Opened \(app.appInfo.appName). Use its built-in updater to check for updates.\n",
                source: CurrentPage.updater.title
            )

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

    @discardableResult
    func openOfficialUpdatePage(for app: UpdateableApp) -> Bool {
        guard let url = app.officialUpdateURL, openURL(url) else {
            GlobalConsoleManager.shared.appendOutput(
                "✗ Could not open this app's official update page: \(app.appInfo.appName)\n",
                source: CurrentPage.updater.title
            )
            return false
        }
        GlobalConsoleManager.shared.appendOutput(
            "Opened the official update page for \(app.appInfo.appName).\n",
            source: CurrentPage.updater.title
        )
        return true
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

    /// Invalidate every provider record after an installer changes this bundle.
    func invalidateResults(forAppAt path: URL) {
        let path = path.standardizedFileURL
        for source in UpdateSource.allCases {
            updatesBySource[source]?.removeAll { $0.appInfo.path.standardizedFileURL == path }
            currentAppPathsBySource[source]?.remove(path)
            reportedUpdatePathsBySource[source]?.remove(path)
            scanFailuresBySource[source]?.removeAll { $0.appPath.standardizedFileURL == path }
        }
        hiddenUpdates.removeAll { $0.appInfo.path.standardizedFileURL == path }
        managedSparkleOverrides.removeValue(forKey: path)
        lastScanDate = nil
    }

    /// Refresh all apps after an update
    /// - Parameter updatedApp: Optional specific app that was updated (only flushes that bundle for performance)
    private func refreshApps(updatedApp: AppInfo? = nil) async {
        if let updatedApp { invalidateResults(forAppAt: updatedApp.path) }
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
        if updatedApp != nil {
            await rebuildDerivedResults(apps: AppState.shared.sortedApps)
        }
    }
}
