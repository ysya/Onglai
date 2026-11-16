import XCTest
@testable import Pearcleaner

final class OfficialUpdateCheckerTests: XCTestCase {
    func testAggregatesUpdatesCurrentAndFailuresWithoutTreatingFailuresAsCurrent() async {
        let apps = [app("com.microsoft.VSCode"), app("com.hnc.Discord"),
                    app("com.anthropic.claudefordesktop"), app("com.postmanlabs.mac")]
        let result = await OfficialUpdateChecker.checkForUpdates(apps: apps) { request, _ in
            switch request.url?.host {
            case "update.code.visualstudio.com": return self.response(request, #"{"productVersion":"2.0.0","version":"abcdef"}"#)
            case "discord.com": return self.response(request, #"{"name":"1.0.0"}"#)
            case "api.anthropic.com": return self.response(request, #"{"unexpected":"2.0.0"}"#)
            default: throw URLError(.notConnectedToInternet)
            }
        }
        XCTAssertEqual(result.updates.map(\.appInfo.bundleIdentifier), ["com.microsoft.VSCode"])
        XCTAssertEqual(result.updates.first?.availableVersion, "2.0.0")
        XCTAssertEqual(result.updates.first?.source, .official)
        XCTAssertEqual(result.updates.first?.externalURL, "https://code.visualstudio.com/download")
        XCTAssertEqual(result.updates.first?.canUpdate, false)
        XCTAssertEqual(result.currentAppPaths, [apps[1].path])
        XCTAssertEqual(Set(result.failures.map(\.appPath)), [apps[2].path, apps[3].path])
    }

    func testEligibilityRejectsStoreWebWrappedAndLookalikeBundleIDs() {
        XCTAssertTrue(OfficialUpdateChecker.isEligible(app("com.postmanlabs.mac", cask: "postman")))
        XCTAssertFalse(OfficialUpdateChecker.isEligible(app("com.postmanlabs.mac", store: true)))
        XCTAssertFalse(OfficialUpdateChecker.isEligible(app("com.postmanlabs.mac", web: true)))
        XCTAssertFalse(OfficialUpdateChecker.isEligible(app("com.postmanlabs.mac", wrapped: true)))
        XCTAssertFalse(OfficialUpdateChecker.isEligible(app("com.postmanlabs.mac.evil")))
        XCTAssertFalse(OfficialUpdateChecker.isEligible(app("com.microsoft.VSCodeInsiders")))
    }

    func testHTTP204MeansNoOfferedUpdateButHTTPFailureDoesNot() async {
        let target = app("com.hnc.Discord")
        let current = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in self.response(request, "", status: 204) }
        XCTAssertEqual(current.currentAppPaths, [target.path])
        let failed = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in self.response(request, "", status: 503) }
        XCTAssertTrue(failed.currentAppPaths.isEmpty)
        XCTAssertEqual(failed.failures.count, 1)
    }

    func testConditionalHTTP204CannotConfirmAnUnknownInstalledVersion() async {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.hnc.Discord"] {
            for version in ["unknown", "", "EAP AI-263.1"] {
                let result = await OfficialUpdateChecker.checkForUpdates(apps: [app(id, version: version)]) { request, _ in
                    self.response(request, "", status: 204)
                }
                XCTAssertTrue(result.currentAppPaths.isEmpty, "\(id): \(version)")
                XCTAssertEqual(result.failures.count, 1, "\(id): \(version)")
            }
        }
    }

    func testNumericBuildCannotEstablishAnUnknownInstalledChannel() async {
        let targets = [app("com.google.android.studio", version: "EAP AI-263.1", build: "AI-263.1"),
                       app("com.brave.Browser", version: "unknown", build: "999.0"),
                       app("com.jetbrains.toolbox", version: "unknown", build: "999.0")]
        for target in targets {
            let result = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in
                switch target.bundleIdentifier {
                case "com.google.android.studio":
                    return self.response(request, "<products><product><channel status=\"release\"><build number=\"AI-262.1\" version=\"Stable | 2026.2\"/></channel></product></products>")
                case "com.brave.Browser":
                    return self.response(request, "<rss><channel><item><enclosure sparkle:version=\"199.57\" sparkle:shortVersionString=\"1.99.57.0\"/></item></channel></rss>")
                default:
                    return self.response(request, #"{"TBA":[{"version":"3.9.1","build":"3.9.1.89198","type":"release"}]}"#)
                }
            }
            XCTAssertTrue(result.updates.isEmpty, target.bundleIdentifier)
            XCTAssertTrue(result.currentAppPaths.isEmpty, target.bundleIdentifier)
            XCTAssertEqual(result.failures.count, 1, target.bundleIdentifier)
        }
    }

    func testHTTP204FromNonconditionalMetadataCannotBeReportedCurrent() async {
        for id in ["com.linear", "com.postmanlabs.mac", "com.anthropic.claudefordesktop",
                   "com.termius-dmg.mac", "me.proton.pass.electron", "com.google.Chrome", "md.obsidian"] {
            let result = await OfficialUpdateChecker.checkForUpdates(apps: [app(id)]) { request, _ in
                self.response(request, "", status: 204)
            }
            XCTAssertEqual(result.failures.count, 1, id)
            XCTAssertTrue(result.currentAppPaths.isEmpty, id)
        }
    }

    func testChecksAreBoundedAndAggregateInInputOrderWhenResponsesFinishOutOfOrder() async {
        let tracker = ConcurrentOfficialLoads()
        let targets = (0..<9).map { index in
            app("com.postmanlabs.mac", path: URL(fileURLWithPath: "/fixture/\(index)"))
        }
        let result = await OfficialUpdateChecker.checkForUpdates(apps: targets) { request, _ in
            let count = await tracker.start()
            try await Task.sleep(nanoseconds: count.isMultiple(of: 2) ? 1_000_000 : 20_000_000)
            await tracker.finish()
            return self.response(request, #"{"version":"2.0.0"}"#)
        }
        let maximum = await tracker.maximum
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 4)
        XCTAssertEqual(result.updates.map(\.appInfo.path), targets.map(\.path))
    }

    func testMalformedOrPrereleaseNumericVersionIsAFailure() async {
        for version in ["latest", "2.0.0-beta.1", "", "v2.0.0"] {
            let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("com.postmanlabs.mac")]) { request, _ in
                self.response(request, "{\"version\":\"\(version)\"}")
            }
            XCTAssertEqual(result.failures.count, 1, version)
            XCTAssertTrue(result.currentAppPaths.isEmpty, version)
        }
    }

    func testLinearUsesHEADAndExtractsVersionFromOfficialFilename() async {
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("com.linear")]) { request, _ in
            self.response(request, "", status: request.httpMethod == "HEAD" ? 200 : 405,
                          headers: ["Content-Disposition": "attachment; filename=\"Linear-1.32.8-universal.dmg\""])
        }
        XCTAssertEqual(result.updates.first?.availableVersion, "1.32.8")
        XCTAssertEqual(result.updates.first?.externalURL, "https://linear.app/download")
    }

    func testTermiusUsesInstalledArchitectureAndRejectsUnsupportedKernel() async {
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("com.termius-dmg.mac")]) { request, _ in
            guard request.url?.path == "/mac-arm64/latest-mac.yml" else { throw URLError(.badURL) }
            return self.response(request, "version: 10.4.1\nminimumSystemVersion: 999.0.0\n")
        }
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testRemainingVendorJSONAndTermiusProfilesDetectVersionsFromVerifiedEndpoints() async {
        let fixtures = [
            ("com.todesktop.230313mzl4w4u92", "api2.cursor.sh", "/updates/api/update/darwin-arm64/cursor/0.0.1/stable", #"{"name":"2.0.0"}"#),
            ("com.anthropic.claudefordesktop", "api.anthropic.com", "/api/desktop/darwin/universal/dmg/latest", #"{"version":"2.0.0"}"#),
            ("com.postmanlabs.mac", "dl.pstmn.io", "/api/version/latest", #"{"version":"2.0.0"}"#),
            ("com.termius-dmg.mac", "autoupdate.termius.com", "/mac-arm64/latest-mac.yml", "version: '2.0.0'\nminimumSystemVersion: 1.0.0\n")
        ]
        for (id, host, path, document) in fixtures {
            let result = await OfficialUpdateChecker.checkForUpdates(apps: [app(id)]) { request, _ in
                guard request.url?.host == host, request.url?.path == path else { throw URLError(.badURL) }
                return self.response(request, document)
            }
            XCTAssertEqual(result.updates.first?.availableVersion, "2.0.0", id)
            XCTAssertTrue(result.failures.isEmpty, id)
        }
    }

    func testUnknownInstalledVersionCannotBeReportedCurrent() async {
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("com.postmanlabs.mac", version: "unknown")]) { request, _ in
            self.response(request, #"{"version":"2.0.0"}"#)
        }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.currentAppPaths.isEmpty)
    }

    func testInstalledPrereleaseCannotBeMovedToAnUnverifiedStableChannel() async {
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("com.postmanlabs.mac", version: "1.0.0-beta.1")]) { request, _ in
            self.response(request, #"{"version":"2.0.0"}"#)
        }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertTrue(result.currentAppPaths.isEmpty)
    }

    func testRiderValidatesLocalProductCodeBeforeUsingVendorMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let file = resources.appendingPathComponent("product-info.json")
        try Data(#"{"productCode":"RD"}"#.utf8).write(to: file)
        let target = app("com.jetbrains.rider", path: directory)
        let loader: OfficialUpdateChecker.DocumentLoader = { request, _ in
            guard request.url?.query?.contains("code=RD") == true else { throw URLError(.badURL) }
            return self.response(request, #"{"RD":[{"version":"2.0.0","build":"263.1","type":"release"}]}"#)
        }
        let valid = await OfficialUpdateChecker.checkForUpdates(apps: [target], documentLoader: loader)
        XCTAssertEqual(valid.updates.first?.availableVersion, "2.0.0")
        try Data(#"{"productCode":"OTHER"}"#.utf8).write(to: file)
        let invalid = await OfficialUpdateChecker.checkForUpdates(apps: [target], documentLoader: loader)
        XCTAssertEqual(invalid.failures.count, 1)
        XCTAssertTrue(invalid.currentAppPaths.isEmpty)
    }

    func testProtonPassSkipsBetaAndIncompleteRollouts() async {
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("me.proton.pass.electron")]) { request, _ in
            self.response(request, #"{"Releases":[{"Version":"9.0.0","CategoryName":"Beta","RolloutPercentage":1},{"Version":"8.0.0","CategoryName":"Stable","RolloutPercentage":0},{"Version":"7.0.0","CategoryName":"Stable","RolloutPercentage":0.2},{"Version":"2.0.0","CategoryName":"Stable","RolloutPercentage":1}]}"#)
        }
        XCTAssertEqual(result.updates.first?.availableVersion, "2.0.0")
    }

    func testChromeRejectsZeroFractionsAndEndedServingRecords() async {
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("com.google.Chrome")]) { request, _ in
            guard request.url?.path.contains("mac_arm64/channels/stable/versions/all/releases") == true else { throw URLError(.badURL) }
            return self.response(request, #"{"releases":[{"version":"8.0.0","fraction":0,"serving":{"startTime":"2026-01-01"}},{"version":"7.0.0","fraction":1,"serving":{"endTime":"2026-01-01"}},{"version":"2.0.0","fraction":0.5,"serving":{"startTime":"2026-01-01"}}]}"#)
        }
        XCTAssertEqual(result.updates.first?.availableVersion, "2.0.0")
    }

    func testToolboxComparesFullBuildInsteadOfMarketingVersion() async {
        let target = app("com.jetbrains.toolbox", version: "3.9.1.89100", build: "3.9.1.89100")
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in
            XCTAssertFalse(request.url?.query?.contains("latest=true") == true)
            return self.response(request, #"{"TBA":[{"version":"3.9.1","build":"3.9.1.89198","type":"release"},{"version":"3.9.1","build":"3.9.1.89100","type":"release"}]}"#)
        }
        XCTAssertEqual(result.updates.first?.availableVersion, "3.9.1")
        XCTAssertEqual(result.updates.first?.availableBuildNumber, "3.9.1.89198")
    }

    func testToolboxUnknownNumericBuildCannotBeAssumedToBelongToStableChannel() async {
        let target = app("com.jetbrains.toolbox", version: "4.0.0.90000", build: "4.0.0.90000")
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in
            self.response(request, #"{"TBA":[{"version":"3.9.1","build":"3.9.1.89198","type":"release"}]}"#)
        }
        XCTAssertTrue(result.currentAppPaths.isEmpty)
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testAndroidStudioComparesBuildAndSelectsOnlyReleaseChannel() async throws {
        let target = try studioApp()
        defer { try? FileManager.default.removeItem(at: target.path) }
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in
            self.response(request, """
            <products><product name="Android Studio"><code>AI</code>
            <channel status="eap"><build number="AI-999.0.0" version="Future | 2099.1"/></channel>
            <channel status="release"><build number="AI-262.2.0" version="Rabbit 2 | 2026.2.2 Patch 1"/></channel>
            </product></products>
            """)
        }
        XCTAssertEqual(result.updates.first?.availableBuildNumber, "262.2.0")
        XCTAssertEqual(result.updates.first?.availableVersion, "2026.2.2")
    }

    func testAndroidStudioRequiresVerifiedStableLocalProductMetadata() async throws {
        let preview = try studioApp(suffix: "EAP", dataDirectory: "AndroidStudioPreview2026.2")
        let mismatched = try studioApp(build: "262.1.2")
        defer {
            try? FileManager.default.removeItem(at: preview.path)
            try? FileManager.default.removeItem(at: mismatched.path)
        }
        let missing = app("com.google.android.studio", version: "2026.2", build: "AI-262.1.1")
        for target in [preview, mismatched, missing] {
            let result = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in
                self.response(request, "<products><product><channel status=\"release\"><build number=\"AI-262.1.1\" version=\"Stable | 2026.2\"/></channel></product></products>")
            }
            XCTAssertTrue(result.currentAppPaths.isEmpty)
            XCTAssertTrue(result.updates.isEmpty)
            XCTAssertEqual(result.failures.count, 1)
        }
    }

    func testBraveComparesBundleBuildAndFiltersIncompatibleItems() async {
        let target = app("com.brave.Browser", version: "157.1.99.56", build: "199.56")
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in
            self.response(request, """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><sparkle:minimumSystemVersion>999.0</sparkle:minimumSystemVersion><enclosure sparkle:version="300.0" sparkle:shortVersionString="2.0.0"/></item>
            <item><enclosure sparkle:version="199.57" sparkle:shortVersionString="1.99.57.0"/></item>
            </channel></rss>
            """)
        }
        XCTAssertEqual(result.updates.first?.availableBuildNumber, "199.57")
    }

    func testBraveExcludesPrereleaseChannelRegardlessOfElementOrder() async {
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("com.brave.Browser", build: "199.56")]) { request, _ in
            self.response(request, """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><sparkle:channel>beta</sparkle:channel><enclosure sparkle:version="300.0" sparkle:shortVersionString="2.0.0"/></item>
            <item><enclosure sparkle:version="199.57" sparkle:shortVersionString="1.99.57.0"/></item>
            </channel></rss>
            """)
        }
        XCTAssertEqual(result.updates.first?.availableBuildNumber, "199.57")
    }

    func testRejectsRedirectedMetadataHostAndOversizedDocuments() async {
        let target = app("com.postmanlabs.mac")
        let foreign = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { _, _ in
            let url = URL(string: "https://example.com/feed")!
            return (Data(#"{"version":"2.0.0"}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(foreign.failures.count, 1)
        let oversized = await OfficialUpdateChecker.checkForUpdates(apps: [target]) { request, _ in
            self.response(request, String(repeating: " ", count: 2 * 1024 * 1024 + 1))
        }
        XCTAssertEqual(oversized.failures.count, 1)
        XCTAssertTrue(foreign.currentAppPaths.isEmpty)
        XCTAssertTrue(oversized.currentAppPaths.isEmpty)
    }

    func testVerifiedGitHubMappingsUseOnlyTheirOwnedRepository() async {
        let mappings = [("app.freelens.Freelens", "freelensapp/freelens"),
                        ("com.carriez.rustdesk", "rustdesk/rustdesk"),
                        ("com.utmapp.UTM", "utmapp/UTM"),
                        ("info.marcel-dierkes.KeepingYouAwake", "newmarcel/KeepingYouAwake")]
        for (id, repository) in mappings {
            let result = await OfficialUpdateChecker.checkForUpdates(apps: [app(id)]) { request, _ in
                guard request.url?.path == "/repos/\(repository)/releases/latest" else { throw URLError(.badURL) }
                return self.response(request, "{\"tag_name\":\"v2.0.0\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://github.com/\(repository)/releases/tag/v2.0.0\"}")
            }
            XCTAssertEqual(result.updates.count, 1, id)
            XCTAssertEqual(result.updates.first?.externalURL, "https://github.com/\(repository)/releases", id)
        }
    }

    func testGitHubUsesInstallerTagAndRejectsDraftPrereleaseOrForeignReleaseURL() async {
        for fragment in [#""draft":true,"prerelease":false,"html_url":"https://github.com/obsidianmd/obsidian-releases/releases/tag/v2.0.0""#,
                         #""draft":false,"prerelease":true,"html_url":"https://github.com/obsidianmd/obsidian-releases/releases/tag/v2.0.0""#,
                         #""draft":false,"prerelease":false,"html_url":"https://example.com/obsidianmd/obsidian-releases/releases/tag/v2.0.0""#] {
            let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("md.obsidian")]) { request, _ in
                self.response(request, "{\"tag_name\":\"v2.0.0\",\(fragment)}")
            }
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertTrue(result.currentAppPaths.isEmpty)
        }
        let result = await OfficialUpdateChecker.checkForUpdates(apps: [app("md.obsidian")]) { request, _ in
            self.response(request, #"{"tag_name":"v2.0.0","draft":false,"prerelease":false,"html_url":"https://github.com/obsidianmd/obsidian-releases/releases/tag/v2.0.0"}"#)
        }
        XCTAssertEqual(result.updates.first?.availableVersion, "2.0.0")
        XCTAssertEqual(result.updates.first?.externalURL, "https://obsidian.md/download")
    }

    private func response(_ request: URLRequest, _ body: String, status: Int = 200,
                          headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    private func studioApp(suffix: String = "", dataDirectory: String = "AndroidStudio2026.2.2",
                           build: String = "262.1.1") throws -> AppInfo {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = directory.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let metadata = ["productCode": "AI", "versionSuffix": suffix,
                        "dataDirectoryName": dataDirectory, "buildNumber": build]
        try JSONSerialization.data(withJSONObject: metadata).write(to: resources.appendingPathComponent("product-info.json"))
        return app("com.google.android.studio", version: "2026.2", build: "AI-262.1.1", path: directory)
    }

    private func app(_ id: String, version: String = "1.0.0", build: String? = nil,
                     cask: String? = nil, store: Bool = false, web: Bool = false, wrapped: Bool = false,
                     path: URL? = nil) -> AppInfo {
        AppInfo(id: UUID(), path: path ?? URL(fileURLWithPath: "/fixture/\(id).app"), bundleIdentifier: id,
                appName: id, appVersion: version, appBuildNumber: build, appIcon: nil,
                webApp: web, wrapped: wrapped, system: false, arch: .arm, cask: cask,
                steam: false, hasSparkle: false, isAppStore: store, adamID: nil,
                autoUpdates: nil, bundleSize: 0, lipoSavings: nil, fileSize: [:], fileIcon: [:],
                creationDate: nil, contentChangeDate: nil, lastUsedDate: nil, dateAdded: nil,
                entitlements: nil, teamIdentifier: nil)
    }
}

private actor ConcurrentOfficialLoads {
    private var active = 0
    private var total = 0
    private(set) var maximum = 0
    func start() -> Int {
        active += 1
        total += 1
        maximum = max(maximum, active)
        return total
    }
    func finish() { active -= 1 }
}
