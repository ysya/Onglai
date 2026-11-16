import XCTest
@testable import Pearcleaner

final class CatalogUpdateCheckerTests: XCTestCase {
    func testParsesExactIdentityHintsAndPlatformVariation() throws {
        let data = Data(#"""
        [{"token":"example","name":["Example","Example Editor"],"version":"1.0",
          "bundle_version":"100","bundle_short_version":"1.0",
          "artifacts":[{"app":["nested/Example.app"]},
            {"uninstall":[{"quit":["com.example.editor","com.example.*"]}]},
            {"zap":[{"trash":["~/Library/Preferences/com.example.editor.plist",
              "~/Library/Preferences/com.other.*.plist","~/Library/Saved Application State/com.example.saved.savedState"]}]}],
          "variations":{"arm64_tahoe":{"version":"2.0","bundle_version":"200","bundle_short_version":"2.0",
            "artifacts":[{"app":["Example ARM.app"]},{"uninstall":[{"quit":"com.example.arm"}]}]}}}]
        """#.utf8)

        let base = try XCTUnwrap(CatalogUpdateChecker.parseCatalog(data, osCodename: "sonoma", isArm: false).first)
        XCTAssertEqual(base.names, ["Example", "Example Editor"])
        XCTAssertEqual(base.appNames, ["Example.app"])
        XCTAssertEqual(base.bundleIdentifiers, ["com.example.editor", "com.example.saved"])
        let arm = try XCTUnwrap(CatalogUpdateChecker.parseCatalog(data, osCodename: "tahoe", isArm: true).first)
        XCTAssertEqual(arm.version, "2.0")
        XCTAssertEqual(arm.bundleVersion, "200")
        XCTAssertEqual(arm.appNames, ["Example ARM.app"])
        XCTAssertEqual(arm.bundleIdentifiers, ["com.example.arm"])
    }

    func testRequiresExactBundleIdentityAndExactFilenameOrName() {
        let cask = entry()
        XCTAssertEqual(matchedToken(app: app(), entries: [cask]), "example")
        XCTAssertNil(matchedToken(app: app(bundleID: "com.unrelated.editor"), entries: [cask]))
        XCTAssertNil(matchedToken(app: app(name: "Example Helper", filename: "Example Helper.app"), entries: [cask]))
        XCTAssertEqual(matchedToken(app: app(name: "Example", filename: "Renamed.app"), entries: [cask]), "example")
    }

    func testRejectsAmbiguousMatchesAndPinnedReleaseLines() {
        XCTAssertNil(matchedToken(app: app(), entries: [entry(), entry(token: "another-example")]))
        XCTAssertNil(matchedToken(app: app(), entries: [entry(token: "example@1")]))
    }

    func testKeepsStableAndPrereleaseChannelsSeparate() {
        let stable = entry(version: "2.0")
        let beta = entry(token: "example@beta", version: "2.1b2")
        XCTAssertEqual(matchedToken(app: app(version: "1.0"), entries: [stable, beta]), "example")
        XCTAssertEqual(matchedToken(app: app(version: "2.1b1"), entries: [stable, beta]), "example@beta")
        XCTAssertNil(matchedToken(app: app(version: "2.1b1"), entries: [stable]))
        XCTAssertNil(matchedToken(app: app(name: "Example Beta", version: "1.0"), entries: [stable]))
    }

    func testRejectsConflictingChannelEvidence() {
        XCTAssertNil(matchedToken(app: app(name: "Example Beta", version: "2.0rc1"),
                                  entries: [entry(token: "example@beta", version: "2.0b3")]))
        XCTAssertNil(matchedToken(app: app(version: "1.0"), entries: [entry(version: "2.0b3")]))
        XCTAssertNil(matchedToken(app: app(version: "2.0b1"), entries: [entry(token: "example@beta", version: "2.0rc1")]))
    }

    func testParsesRenamedAppArtifactTarget() throws {
        let data = Data(#"""
        [{"token":"example","name":["Example"],"version":"2.0","artifacts":[
          {"app":["nested/Original.app",{"target":"Example.app"}],"target":"/Applications/Example.app"},
          {"uninstall":[{"quit":"com.example.editor"}]}]}]
        """#.utf8)
        let entries = try CatalogUpdateChecker.parseCatalog(data, osCodename: "tahoe", isArm: true)
        XCTAssertEqual(matchedToken(app: app(name: "Unrelated Display Name"), entries: entries), "example")
    }

    func testExcludesReceiptsAndActualSystemPathsButAllowsApplicationsSystemFlag() {
        XCTAssertFalse(CatalogUpdateChecker.isEligible(app(isAppStore: true)))
        XCTAssertFalse(CatalogUpdateChecker.isEligible(app(filename: "Example.app", parent: "/System/Applications")))
        XCTAssertFalse(CatalogUpdateChecker.isEligible(app(webApp: true)))
        XCTAssertFalse(CatalogUpdateChecker.isEligible(app(wrapped: true)))
        XCTAssertFalse(CatalogUpdateChecker.isEligible(app(cask: "example")))
        XCTAssertTrue(CatalogUpdateChecker.isEligible(app(system: true)))
    }

    func testCatalogUpdatesUseTrustedExternalPageWithoutAdopting() async {
        let results = await catalogUpdates(apps: [app()]) { [self.entry(version: "2.0")] }
        XCTAssertEqual(results.updates.count, 1)
        let update = results.updates.first
        XCTAssertEqual(update?.source, .catalog)
        XCTAssertEqual(update?.externalURL, "https://formulae.brew.sh/cask/example")
        XCTAssertNil(update?.appInfo.cask)
        XCTAssertEqual(update?.isSelectedForUpdate, false)
        XCTAssertEqual(update?.canUpdate, false)
        XCTAssertTrue(results.currentAppPaths.isEmpty)
    }

    func testOnlyValidSuccessfulComparisonsConfirmCurrent() async {
        let local = app(version: "2.0")
        let current = await catalogUpdates(apps: [local]) { [self.entry(version: "2.0")] }
        XCTAssertEqual(current.currentAppPaths, [local.path])
        for version in ["latest", "unknown", ""] {
            let unknown = await catalogUpdates(apps: [local]) { [self.entry(version: version)] }
            XCTAssertTrue(unknown.currentAppPaths.isEmpty, version)
            XCTAssertEqual(unknown.failures.count, 1, version)
        }
    }

    func testExactFullInstalledBuildPreventsTruncatedMarketingVersionFalseUpdate() async {
        for (short, build) in [("16.115", "16.115.26110837"), ("119.0", "119.0.1.0")] {
            let local = app(version: short, build: build)
            let results = await catalogUpdates(apps: [local]) { [self.entry(version: build)] }
            XCTAssertTrue(results.updates.isEmpty, build)
            XCTAssertTrue(results.failures.isEmpty, build)
            XCTAssertEqual(results.currentAppPaths, [local.path], build)
        }
    }

    func testUnverifiedCommaSuffixCannotConfirmCurrent() async {
        for remote in ["4.0,23", "4.0,opaque", "4.0,23,1742287964"] {
            let results = await catalogUpdates(apps: [app(version: "4.0.0", build: "4.0.0")]) {
                [self.entry(version: remote)]
            }
            XCTAssertTrue(results.updates.isEmpty, remote)
            XCTAssertTrue(results.currentAppPaths.isEmpty, remote)
            XCTAssertEqual(results.failures.count, 1, remote)
        }
    }

    func testMatchingCommaSuffixCanBeConfirmedWithoutInferringItsOrdering() async {
        let local = app(version: "4.0.0", build: "23")
        let results = await catalogUpdates(apps: [local]) { [self.entry(version: "4.0,23")] }
        XCTAssertTrue(results.updates.isEmpty)
        XCTAssertTrue(results.failures.isEmpty)
        XCTAssertEqual(results.currentAppPaths, [local.path])
        let extra = await catalogUpdates(apps: [local]) { [self.entry(version: "4.0,23,opaque")] }
        XCTAssertTrue(extra.currentAppPaths.isEmpty)
        XCTAssertEqual(extra.failures.count, 1)
    }

    func testNewerMarketingVersionCanUpdateDespiteUnverifiedCommaSuffix() async {
        let results = await catalogUpdates(apps: [app(version: "3.0", build: "3.0")]) {
            [self.entry(version: "4.0,opaque")]
        }
        XCTAssertEqual(results.updates.first?.availableVersion, "4.0")
        XCTAssertTrue(results.failures.isEmpty)
    }

    func testIgnoresStaleBundleMetadataAndComparesVerifiedBuilds() async {
        let local = app(version: "2.0", build: "200")
        let stale = entry(version: "2.0", bundleVersion: "999", bundleShortVersion: "1.0")
        let staleResult = await catalogUpdates(apps: [local]) { [stale] }
        XCTAssertTrue(staleResult.updates.isEmpty)
        XCTAssertEqual(staleResult.currentAppPaths, [local.path])

        let verified = entry(version: "2.0", bundleVersion: "201", bundleShortVersion: "2.0")
        let buildResult = await catalogUpdates(apps: [local]) { [verified] }
        XCTAssertEqual(buildResult.updates.first?.availableBuildNumber, "201")
    }

    func testMissingBuildCannotConfirmSameMarketingVersionWithVerifiedRemoteBuild() async {
        let verified = entry(version: "2.0", bundleVersion: "201", bundleShortVersion: "2.0")
        let results = await catalogUpdates(apps: [app(version: "2.0")]) { [verified] }
        XCTAssertTrue(results.currentAppPaths.isEmpty)
        XCTAssertEqual(results.failures.count, 1)
    }

    func testLoadErrorsRemainFailuresAndDoNotConfirmCurrent() async {
        let results = await catalogUpdates(apps: [app()]) { throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(results.currentAppPaths.isEmpty)
        XCTAssertTrue(results.updates.isEmpty)
        XCTAssertEqual(results.failures.count, 1)
    }

    func testParsesSignalAndRejectsWildcardAndUnrelatedHints() throws {
        let data = Data(#"""
        [{"token":"example","name":["Example"],"version":"1.0","artifacts":[
          {"uninstall":[{"signal":["KILL","com.example.editor"],"launchctl":"com.example.daemon","pkgutil":"com.example.pkg"}]},
          {"zap":[{"trash":["~/Library/Preferences/ByHost/com.example.helper.*.plist","~/Library/Preferences/com.example.*.plist"]}]}]}]
        """#.utf8)
        let parsed = try XCTUnwrap(CatalogUpdateChecker.parseCatalog(data, osCodename: "tahoe", isArm: true).first)
        XCTAssertEqual(parsed.bundleIdentifiers, ["com.example.editor"])
    }

    func testMalformedCatalogDoesNotBecomeEmptySuccessfulCatalog() {
        XCTAssertThrowsError(try CatalogUpdateChecker.parseCatalog(Data("{}".utf8), osCodename: "tahoe", isArm: true))
        XCTAssertThrowsError(try CatalogUpdateChecker.parseCatalog(Data("[]".utf8), osCodename: "tahoe", isArm: true))
    }

    func testRespectsPlatformRequirements() throws {
        let data = Data(#"""
        [{"token":"example","name":["Example"],"version":"1.0",
          "depends_on":{"macos":{">=":["14.0"]},"arch":[{"type":"arm","bits":64}]}}]
        """#.utf8)
        let cask = try XCTUnwrap(CatalogUpdateChecker.parseCatalog(data, osCodename: "tahoe", isArm: true).first)
        XCTAssertEqual(cask.minimumMacOSVersion, "14.0")
        XCTAssertEqual(cask.architectures, ["arm64"])
        XCTAssertFalse(CatalogUpdateChecker.supportsPlatform(cask, osVersion: "13.7", architecture: "arm64"))
        XCTAssertFalse(CatalogUpdateChecker.supportsPlatform(cask, osVersion: "14.0", architecture: "x86_64"))
        XCTAssertTrue(CatalogUpdateChecker.supportsPlatform(cask, osVersion: "14.0", architecture: "arm64"))
    }

    func testRespectsExactMacOSReleaseRequirements() throws {
        let data = Data(#"""
        [{"token":"example","name":["Example"],"version":"1.0","depends_on":{"macos":{"==":["10.13","10.14"]}}}]
        """#.utf8)
        let cask = try XCTUnwrap(CatalogUpdateChecker.parseCatalog(data, osCodename: "tahoe", isArm: true).first)
        XCTAssertTrue(CatalogUpdateChecker.supportsPlatform(cask, osVersion: "10.14.6", architecture: "arm64"))
        XCTAssertFalse(CatalogUpdateChecker.supportsPlatform(cask, osVersion: "15.0", architecture: "arm64"))
    }

    func testConcurrentCatalogLoadsShareOneSuccessfulFetch() async throws {
        let counter = CatalogLoadCounter()
        let cask = entry()
        let cache = CatalogCache(loader: {
            await counter.increment()
            try await Task.sleep(nanoseconds: 10_000_000)
            return [cask]
        })
        async let first = cache.load()
        async let second = cache.load()
        let loaded = try await (first, second)
        XCTAssertEqual(loaded.0.map(\.token), ["example"])
        XCTAssertEqual(loaded.1.map(\.token), ["example"])
        _ = try await cache.load()
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testExpiredCatalogCacheFetchesAgain() async throws {
        let counter = CatalogLoadCounter()
        let cask = entry()
        let cache = CatalogCache(maxAge: 0, loader: {
            await counter.increment()
            return [cask]
        })
        _ = try await cache.load()
        _ = try await cache.load()
        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    func testFailedCatalogLoadCanRetryWithoutCachingFailure() async throws {
        let counter = CatalogLoadCounter()
        let cask = entry()
        let cache = CatalogCache(loader: {
            let count = await counter.increment()
            if count == 1 { throw URLError(.timedOut) }
            return [cask]
        })
        do {
            _ = try await cache.load()
            XCTFail("The first load should fail")
        } catch {}
        let loaded = try await cache.load()
        XCTAssertEqual(loaded.map(\.token), ["example"])
    }

    func testPublisherDownloadTokensDoNotInvalidateMatchingAppVersions() async {
        for (token, id, version, build, remote) in [
            ("claude", "com.anthropic.claudefordesktop", "5.11492.5", "5.11492.5", "5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2"),
            ("microsoft-edge", "com.microsoft.edgemac", "157.0.4341.60", "157.0.4341.60", "157.0.4341.60,e6f68d66-b355-497a-9ea2-dde37f87e4cb"),
            ("postgres-app", "com.postgresapp.Postgres2", "2.9.7", "396", "2.9.7,14-15-16-17-18")
        ] {
            let target = app(bundleID: id, version: version, build: build)
            let cask = CatalogCask(token: token, names: ["Example"], version: remote,
                                   appNames: ["Example.app"], bundleIdentifiers: [id])
            let result = await catalogUpdates(apps: [target]) { [cask] }
            XCTAssertEqual(result.currentAppPaths, [target.path], token)
            XCTAssertTrue(result.failures.isEmpty, token)
        }
    }

    func testLMStudioAndJetBrainsCompoundBuildsUseInstalledBuildEvidence() async {
        for (token, id, version, build, remote) in [
            ("lm-studio", "ai.elementlabs.lmstudio", "0.4.28+2", "0.4.28+2", "0.4.28,2"),
            ("datagrip", "com.jetbrains.datagrip", "2026.3", "DB-263.7307.216", "2026.3,263.7307.216"),
            ("rider", "com.jetbrains.rider", "2026.3", "RD-263.7307.258", "2026.3,263.7307.258")
        ] {
            let target = app(bundleID: id, version: version, build: build)
            let cask = CatalogCask(token: token, names: ["Example"], version: remote,
                                   appNames: ["Example.app"], bundleIdentifiers: [id])
            let result = await catalogUpdates(apps: [target]) { [cask] }
            XCTAssertEqual(result.currentAppPaths, [target.path], token)
            XCTAssertTrue(result.failures.isEmpty, token)
        }
        let target = app(bundleID: "ai.elementlabs.lmstudio", version: "0.4.28+1", build: "0.4.28+1")
        let cask = CatalogCask(token: "lm-studio", names: ["Example"], version: "0.4.28,2",
                               appNames: ["Example.app"], bundleIdentifiers: [target.bundleIdentifier])
        let result = await catalogUpdates(apps: [target]) { [cask] }
        XCTAssertEqual(result.updates.first?.availableVersion, "0.4.28+2")
    }

    func testParallelsSeparatesMarketingVersionAndBuild() async {
        let target = app(bundleID: "com.parallels.desktop.console", version: "26.4.2", build: "57518")
        let cask = CatalogCask(token: "parallels", names: ["Example"], version: "27.1.0-58756",
                               appNames: ["Example.app"], bundleIdentifiers: [target.bundleIdentifier])
        let result = await catalogUpdates(apps: [target]) { [cask] }
        XCTAssertEqual(result.updates.first?.availableVersion, "27.1.0")
        XCTAssertEqual(result.updates.first?.availableBuildNumber, "58756")
    }

    func testComparisonLimitationsAreUnavailableButTransportFailuresRemainErrors() async {
        let target = app(version: "4.0.0", build: "4.0.0")
        let unknown = await catalogUpdates(apps: [target]) { [self.entry(version: "4.0,23")] }
        XCTAssertTrue(unknown.currentAppPaths.isEmpty)
        XCTAssertEqual(unknown.failures.first?.kind, .unavailable)
        let offline = await catalogUpdates(apps: [target]) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline.failures.first?.kind, .failed)
    }

    func testPublisherProjectionsRequireVerifiedIdentityAndFieldShape() async {
        for (token, id, local, build, remote) in [
            ("claude", "com.unrelated.app", "5.11492.5", "5.11492.5", "5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2"),
            ("claude", "com.anthropic.claudefordesktop", "5.11492.5", "5.11492.5", "5.11492.5,unknown"),
            ("microsoft-edge", "com.microsoft.edgemac", "157.0.4341.60", "157.0.4341.60", "157.0.4341.60,unknown"),
            ("postgres-app", "com.postgresapp.Postgres2", "2.9.7", "396", "2.9.7,unknown"),
            ("lm-studio", "ai.elementlabs.lmstudio", "0.4.28+1", "0.4.28+1", "0.4.28,2beta"),
            ("datagrip", "com.jetbrains.datagrip", "2026.3", "DB-263.7307.216", "2026.3,264beta")
        ] {
            let target = app(bundleID: id, version: local, build: build)
            let cask = CatalogCask(token: token, names: ["Example"], version: remote,
                                   appNames: ["Example.app"], bundleIdentifiers: [id])
            let result = await catalogUpdates(apps: [target]) { [cask] }
            XCTAssertTrue(result.updates.isEmpty, token)
            XCTAssertTrue(result.currentAppPaths.isEmpty, token)
            XCTAssertEqual(result.failures.first?.kind, .unavailable, token)
        }
    }

    func testNewConfiguredIdentityUsesExistingFormatWithoutCodeMapping() async throws {
        let id = "com.example.remote"
        let target = app(bundleID: id, version: "2.0", build: "CUSTOM-200")
        let configured = UpdaterRuleSet(revision: 2, catalogVersions: [
            CatalogVersionRule(token: "custom-editor", bundleIdentifier: id, format: .prefixedBuild, buildPrefix: "CUSTOM-")
        ])
        let rules = try UpdaterRuleSet.decodeValidated(JSONEncoder().encode(configured))
        let cask = CatalogCask(token: "custom-editor", names: ["Example"], version: "2.0,201",
                               appNames: ["Example.app"], bundleIdentifiers: [id])
        let result = await CatalogUpdateChecker.checkForUpdates(apps: [target], rules: rules) { [cask] }
        XCTAssertEqual(result.updates.first?.availableBuildNumber, "201")
        XCTAssertTrue(result.failures.isEmpty)
    }

    private func catalogUpdates(apps: [AppInfo], loader: () async throws -> [CatalogCask]) async -> UpdateCheckResults {
        await CatalogUpdateChecker.checkForUpdates(apps: apps, rules: .bundled(), loader: loader)
    }

    private func matchedToken(app: AppInfo, entries: [CatalogCask]) -> String? {
        CatalogUpdateChecker.match(for: app, in: entries)?.token
    }

    private func entry(token: String = "example", version: String = "2.0", bundleVersion: String? = nil, bundleShortVersion: String? = nil) -> CatalogCask {
        CatalogCask(token: token, names: ["Example"], version: version, bundleVersion: bundleVersion,
                    bundleShortVersion: bundleShortVersion, appNames: ["Example.app"],
                    bundleIdentifiers: ["com.example.editor"])
    }

    private func app(name: String = "Example", filename: String = "Example.app", parent: String = "/Applications",
                     bundleID: String = "com.example.editor", version: String = "1.0", build: String? = nil,
                     isAppStore: Bool = false, system: Bool = false, webApp: Bool = false,
                     wrapped: Bool = false, cask: String? = nil) -> AppInfo {
        AppInfo(id: UUID(), path: URL(fileURLWithPath: parent).appendingPathComponent(filename),
                bundleIdentifier: bundleID, appName: name, appVersion: version, appBuildNumber: build,
                appIcon: nil, webApp: webApp, wrapped: wrapped, system: system, arch: .universal,
                cask: cask, steam: false, hasSparkle: false, isAppStore: isAppStore, adamID: nil,
                autoUpdates: nil, bundleSize: 0, lipoSavings: nil, fileSize: [:], fileIcon: [:],
                creationDate: nil, contentChangeDate: nil, lastUsedDate: nil, dateAdded: nil,
                entitlements: nil, teamIdentifier: nil)
    }
}

private actor CatalogLoadCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
