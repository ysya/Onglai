import XCTest
@testable import Pearcleaner

@MainActor
final class UpdateManagerSourceTests: XCTestCase {
    func testExternalUpdatesOpenTheInstalledAppWithOrWithoutAWebsite() async {
        var opened: [URL] = []
        let manager = manager(openURL: { opened.append($0); return true })
        let target = app("external")
        for source in [UpdateSource.electron, .official, .catalog] {
            for website in [nil, "https://publisher.example.com/releases"] {
                var candidate = update(target, source: source)
                candidate.externalURL = website
                await manager.updateApp(candidate)
            }
        }
        XCTAssertEqual(opened, Array(repeating: target.path, count: 6))
    }

    func testOfficialPageActionOpensOnlyTheSeparateOfficialPage() async {
        var opened: [URL] = []
        let manager = manager(openURL: { opened.append($0); return true })
        let target = app("external")
        var candidate = update(target, source: .catalog)
        candidate.externalURL = "https://publisher.example.com/releases"
        await manager.updateApp(candidate)
        XCTAssertEqual(opened, [target.path])
        XCTAssertTrue(manager.openOfficialUpdatePage(for: candidate))
        XCTAssertEqual(opened, [target.path, URL(string: "https://publisher.example.com/releases")!])
    }

    func testOfficialPageActionRejectsMissingUnsafeAndCatalogURLs() {
        var opened: [URL] = []
        let manager = manager(openURL: { opened.append($0); return true })
        var authenticatedPage = URLComponents(string: "https://publisher.example.com/releases")!
        authenticatedPage.user = "fixture-user"
        authenticatedPage.password = "fixture-password"
        for website in [nil, "http://publisher.example.com/releases", "file:///tmp/installer",
                        authenticatedPage.url?.absoluteString,
                        "https://formulae.brew.sh/cask/example"] {
            var candidate = update(app("external"), source: .catalog)
            candidate.externalURL = website
            XCTAssertNil(candidate.officialUpdateURL)
            XCTAssertFalse(manager.openOfficialUpdatePage(for: candidate))
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func testFailedExternalAppLaunchReportsFailureWithoutOpeningItsWebsite() async {
        var opened: [URL] = []
        let manager = manager(openURL: { opened.append($0); return false })
        let target = app("external")
        var candidate = update(target, source: .official)
        candidate.externalURL = "https://publisher.example.com/releases"
        manager.updatesBySource[.official] = [candidate]
        await manager.updateApp(candidate)
        XCTAssertEqual(opened, [target.path])
        XCTAssertEqual(manager.updatesBySource[.official]?.first?.status, .failed("Could not open this app"))
    }

    func testSingleAppRecheckPreservesOtherAppsFailuresAndCurrentEvidence() {
        let manager = manager()
        let first = app("first")
        let second = app("second")
        let third = app("third")
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [third.path], failures: [failure(first), failure(second)]), source: .catalog)
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [first.path]), source: .catalog, replacingAppPaths: [first.path])
        XCTAssertEqual(manager.scanFailuresBySource[.catalog]?.map(\.appPath), [second.path])
        XCTAssertTrue(manager.isConfirmedCurrent(first))
        XCTAssertTrue(manager.isConfirmedCurrent(third))
        XCTAssertFalse(manager.isConfirmedCurrent(second))
    }

    func testIgnoredCatalogUpdateCannotBecomeCurrentFromAnotherSourcesResult() {
        let manager = manager()
        let target = app("editor", sparkle: true)
        let update = update(target, source: .catalog)
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [target.path]), source: .sparkle)
        manager.recordSourceEvidence(UpdateCheckResults(updates: [update]), source: .catalog)
        manager.updatesBySource[.catalog] = [update]
        manager.hideApp(update, skipVersion: "2.0")
        XCTAssertFalse(manager.isConfirmedCurrent(target))
    }

    func testSkipAppliesToAlternateSourcesAndNewVersionsReturn() async {
        let manager = manager()
        let target = app("editor")
        let official = update(target, source: .official)
        let catalog = update(target, source: .catalog)
        manager.updatesBySource[.official] = [official]
        manager.updatesBySource[.catalog] = [catalog]
        XCTAssertEqual(manager.appCentricItems.count, 1)
        manager.hideApp(official, skipVersion: "2.0")
        XCTAssertTrue(manager.appCentricItems.isEmpty)
        XCTAssertEqual(manager.getIgnoredVersion(for: catalog), "2.0")
        let newer = update(target, source: .catalog, version: "3.0")
        await manager.processSourceResults(source: .catalog, apps: [catalog])
        XCTAssertTrue(manager.appCentricItems.isEmpty)
        await manager.processSourceResults(source: .catalog, apps: [newer])
        XCTAssertEqual(manager.appCentricItems.first?.primaryApp?.availableVersion, "3.0")
    }

    func testPermanentHideSurvivesAResultFromAnotherSource() async {
        let manager = manager()
        let target = app("editor")
        let official = update(target, source: .official)
        manager.updatesBySource[.official] = [official]
        manager.hideApp(official)
        await manager.processSourceResults(source: .catalog, apps: [update(target, source: .catalog, version: "3.0")])
        XCTAssertTrue(manager.appCentricItems.isEmpty)
        XCTAssertEqual(manager.hiddenUpdates.count, 1)
    }

    func testDisablingSourceClearsItsEvidenceAndRejectsLateResults() async {
        let manager = manager()
        let target = app("editor", sparkle: true)
        let catalog = update(target, source: .catalog)
        manager.recordSourceEvidence(UpdateCheckResults(updates: [catalog]), source: .catalog)
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [target.path]), source: .sparkle)
        manager.updatesBySource[.catalog] = [catalog]
        await manager.sourceSettingsDidChange(.catalog, enabled: false)
        manager.recordSourceEvidence(UpdateCheckResults(failures: [failure(target)]), source: .catalog)
        XCTAssertNil(manager.scanFailuresBySource[.catalog])
        XCTAssertNil(manager.updatesBySource[.catalog])
        XCTAssertTrue(manager.isConfirmedCurrent(target))
        XCTAssertFalse(manager.appCentricItems.contains { $0.appInfo?.path == target.path })
    }

    func testSuccessfulSparkleRecheckReplacesManagedOverride() async {
        let manager = manager()
        let target = app("editor", sparkle: true)
        let invalidFeed = UpdateCheckFailure(appPath: target.path, appName: target.appName,
                                             message: SparkleUpdateChecker.invalidFeedConfigurationMessage)
        manager.recordSourceEvidence(UpdateCheckResults(failures: [invalidFeed]), source: .sparkle)
        await manager.rebuildDerivedResults(apps: [target])
        XCTAssertEqual(manager.appCentricItems.first?.section, .managed)
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [target.path]), source: .sparkle, replacingAppPaths: [target.path])
        await manager.rebuildDerivedResults(apps: [target])
        XCTAssertEqual(manager.appCentricItems.first?.section, .current)
    }

    func testSkippingOneVersionKeepsDifferentNewerAlternateVisible() {
        let manager = manager()
        let target = app("editor")
        let official = update(target, source: .official)
        let newer = update(target, source: .catalog, version: "3.0")
        manager.updatesBySource[.official] = [official]
        manager.updatesBySource[.catalog] = [newer]
        manager.hideApp(official, skipVersion: "2.0")
        XCTAssertEqual(manager.appCentricItems.first?.primaryApp?.availableVersion, "3.0")
        XCTAssertNil(manager.getIgnoredVersion(for: newer))
    }

    func testLegacyPermanentHideAppliesToNewSource() async {
        let target = app("editor")
        let manager = manager(ignored: [target.bundleIdentifier: [UpdateSource.sparkle.rawValue: nil]])
        await manager.processSourceResults(source: .catalog, apps: [update(target, source: .catalog)])
        XCTAssertTrue(manager.appCentricItems.isEmpty)
        XCTAssertEqual(manager.hiddenUpdates.count, 1)
    }

    func testSkippedVersionAppliesWhenEquivalentSourceArrivesLater() async {
        let target = app("editor")
        let manager = manager(ignored: [target.bundleIdentifier: [UpdateSource.official.rawValue: "2.0"]])
        await manager.processSourceResults(source: .catalog, apps: [update(target, source: .catalog, version: "2.0.0")])
        XCTAssertTrue(manager.appCentricItems.isEmpty)
        await manager.processSourceResults(source: .catalog, apps: [update(target, source: .catalog, version: "3.0")])
        XCTAssertEqual(manager.appCentricItems.first?.primaryApp?.availableVersion, "3.0")
    }

    func testSuccessfulInstallInvalidatesAllSourceEvidenceForOnlyThatPath() {
        let manager = manager()
        let first = app("first", sparkle: true)
        let second = app("second", sparkle: true)
        for source in [UpdateSource.homebrew, .sparkle, .official, .catalog] {
            manager.updatesBySource[source] = [update(first, source: source), update(second, source: source)]
        }
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [first.path, second.path]), source: .sparkle)
        manager.recordSourceEvidence(UpdateCheckResults(updates: [update(first, source: .catalog)], currentAppPaths: [second.path]), source: .catalog)
        manager.recordSourceEvidence(UpdateCheckResults(failures: [failure(first), failure(second)]), source: .official)
        manager.invalidateResults(forAppAt: first.path)
        XCTAssertTrue(manager.updatesBySource.values.flatMap { $0 }.allSatisfy { $0.appInfo.path == second.path })
        XCTAssertEqual(manager.scanFailuresBySource[.official]?.map(\.appPath), [second.path])
        XCTAssertFalse(manager.isConfirmedCurrent(first))
        XCTAssertTrue(manager.isConfirmedCurrent(second))
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [first.path]), source: .sparkle, replacingAppPaths: [first.path])
        XCTAssertTrue(manager.isConfirmedCurrent(first))
    }

    func testCatalogueLimitationDoesNotOverrideSuccessfulSparkleCheck() async {
        let manager = manager()
        let target = app("editor", sparkle: true)
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [target.path]), source: .sparkle)
        let limitation = UpdateCheckFailure(appPath: target.path, appName: target.appName,
                                             message: "Version metadata unavailable", kind: .unavailable)
        manager.recordSourceEvidence(UpdateCheckResults(failures: [limitation]), source: .catalog)
        await manager.rebuildDerivedResults(apps: [target])
        XCTAssertTrue(manager.isConfirmedCurrent(target))
        XCTAssertEqual(manager.appCentricItems.map(\.section), [.current])
    }

    func testUnavailableVersionUsesManualCheckButNetworkFailureUsesError() {
        let manager = manager()
        let target = app("editor")
        let limitation = UpdateCheckFailure(appPath: target.path, appName: target.appName,
                                             message: "Version metadata unavailable", kind: .unavailable)
        manager.recordSourceEvidence(UpdateCheckResults(failures: [limitation]), source: .catalog)
        XCTAssertEqual(manager.appCentricItems.first?.section, .unverified)
        XCTAssertFalse(manager.isConfirmedCurrent(target))
        manager.recordSourceEvidence(UpdateCheckResults(failures: [failure(target)]), source: .catalog)
        XCTAssertEqual(manager.appCentricItems.first?.section, .attention)
    }

    func testSkippingVerifiedBuildDoesNotHideANewerBuildOfSameMarketingVersion() async {
        for (version, olderBuild, newerVersion, newerBuild) in [
            ("0.4.28+2", "2", "0.4.28+3", "3"),
            ("2026.3", "263.7307.216", "2026.3", "263.7307.217"),
            ("27.1.0", "58756", "27.1.0", "58757")
        ] {
            let manager = manager()
            let target = app("editor")
            var older = update(target, source: .catalog, version: version)
            older.availableBuildNumber = olderBuild
            var newer = update(target, source: .catalog, version: newerVersion)
            newer.availableBuildNumber = newerBuild
            manager.updatesBySource[.catalog] = [older]
            manager.hideApp(older, skipVersion: older.availableVersion)
            await manager.processSourceResults(source: .catalog, apps: [older])
            XCTAssertTrue(manager.appCentricItems.isEmpty)
            await manager.processSourceResults(source: .catalog, apps: [newer])
            XCTAssertEqual(manager.appCentricItems.first?.primaryApp?.availableBuildNumber, newerBuild)
        }
    }

    func testSkippingElectronBuildMetadataDoesNotHideNextBuild() async {
        let manager = manager()
        let target = app("editor")
        let older = update(target, source: .electron, version: "0.4.28+2")
        let newer = update(target, source: .electron, version: "0.4.28+3")
        manager.updatesBySource[.electron] = [older]
        manager.hideApp(older, skipVersion: older.availableVersion)
        await manager.processSourceResults(source: .electron, apps: [newer])
        XCTAssertEqual(manager.appCentricItems.first?.primaryApp?.availableVersion, "0.4.28+3")
    }

    func testChangedRuleRevisionInvalidatesAndRescansEveryAffectedSource() {
        let manager = manager()
        let current = app("current", sparkle: true)
        let outdated = app("outdated")
        let independent = app("independent")
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [current.path]), source: .sparkle)
        manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [current.path]), source: .catalog)
        manager.recordSourceEvidence(UpdateCheckResults(failures: [failure(outdated)]), source: .official)
        for source in [UpdateSource.sparkle, .official, .catalog] {
            manager.updatesBySource[source] = [update(outdated, source: source)]
        }
        manager.updatesBySource[.homebrew] = [update(independent, source: .homebrew)]
        XCTAssertTrue(manager.isConfirmedCurrent(current))
        let unchanged = manager.sourcesAfterRuleRefresh(from: 1, to: 1, requested: [.catalog])
        XCTAssertEqual(unchanged, [.catalog])
        XCTAssertTrue(manager.isConfirmedCurrent(current))
        let requested = manager.sourcesAfterRuleRefresh(from: 1, to: 2, requested: [.catalog])
        XCTAssertEqual(requested, [.sparkle, .official, .catalog])
        for source in [UpdateSource.sparkle, .official, .catalog] {
            XCTAssertNil(manager.updatesBySource[source])
            XCTAssertNil(manager.scanFailuresBySource[source])
        }
        XCTAssertFalse(manager.isConfirmedCurrent(current))
        XCTAssertEqual(manager.updatesBySource[.homebrew]?.first?.appInfo.path, independent.path)
    }

    func testInFlightCheckFromOlderRulesCannotRestoreStaleEvidence() {
        let manager = manager()
        let target = app("editor")
        let revision = UpdaterRuleStore.shared.snapshot.revision
        let accepted = manager.recordSourceEvidence(UpdateCheckResults(currentAppPaths: [target.path]), source: .catalog,
                                                      checkedRuleRevision: revision - 1)
        XCTAssertFalse(accepted)
        XCTAssertFalse(manager.isConfirmedCurrent(target))
    }

    private func manager(ignored: [String: [String: String?]] = [:],
                         openURL: @escaping (URL) -> Bool = { _ in true }) -> UpdateManager {
        let suiteName = "UpdateManagerSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(try! JSONEncoder().encode(ignored), forKey: "settings.updater.ignoredAppsData")
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return UpdateManager(defaults: defaults, observesAppLoading: false, openURL: openURL)
    }

    private func failure(_ app: AppInfo) -> UpdateCheckFailure {
        UpdateCheckFailure(appPath: app.path, appName: app.appName, message: "Network unavailable")
    }

    private func app(_ name: String, sparkle: Bool = false) -> AppInfo {
        AppInfo(id: UUID(), path: URL(fileURLWithPath: "/fixture/\(name).app"),
                bundleIdentifier: "test.updater.\(name)", appName: name, appVersion: "1.0", appBuildNumber: nil,
                appIcon: nil, webApp: false, wrapped: false, system: false, arch: .empty, cask: nil, steam: false,
                hasSparkle: sparkle, isAppStore: false, adamID: nil, autoUpdates: nil, bundleSize: 0,
                lipoSavings: nil, fileSize: [:], fileIcon: [:], creationDate: nil, contentChangeDate: nil,
                lastUsedDate: nil, dateAdded: nil, entitlements: nil, teamIdentifier: nil)
    }

    private func update(_ app: AppInfo, source: UpdateSource, version: String = "2.0") -> UpdateableApp {
        UpdateableApp(appInfo: app, availableVersion: version, availableBuildNumber: nil, source: source,
                      adamID: nil, appStoreURL: nil, isSelectedForUpdate: false,
                      releaseTitle: nil, releaseDescription: nil, releaseNotesLink: nil,
                      releaseDate: nil, isPreRelease: false, isIOSApp: false, foundInRegion: nil, appcastItem: nil)
    }
}
