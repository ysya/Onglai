import XCTest
@testable import Pearcleaner

final class UpdaterRuleSetTests: XCTestCase {
    private var credentialBearingURL: String {
        var components = URLComponents(string: "https://updates.example.com/feed.xml")!
        components.user = "fixture-user"
        components.password = "fixture-value"
        return components.url!.absoluteString
    }

    func testNativeJSONRuleFieldsAreOptionalAndConservativelyValidated() throws {
        var rule = UpdaterRuleFixture.official()
        rule["nativeDownloadURLKey"] = "url"
        rule["nativeSHA256Key"] = "sha256hash"
        rule["nativeFormat"] = "zip"
        let rules = try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule]))
        XCTAssertEqual(rules.officialSources.first?.nativeDownloadURLKey, "url")
        XCTAssertEqual(rules.officialSources.first?.nativeFormat, .zip)
        for (field, invalid) in [("nativeDownloadURLKey", "nested.url"), ("nativeSHA256Key", ""), ("nativeFormat", "pkg")] {
            var bad = rule
            bad[field] = invalid
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [bad])))
        }
        for field in ["nativeDownloadURLKey", "nativeSHA256Key"] {
            var incomplete = rule
            incomplete.removeValue(forKey: field)
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [incomplete])))
        }
        var wrongAdapter = rule
        wrongAdapter["kind"] = "linear"
        wrongAdapter.removeValue(forKey: "versionKey")
        XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [wrongAdapter])))
    }

    func testDefaultsAndExactLookupsPreserveArchitectureAndIdentity() throws {
        let rules = try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(
            sparkleFeeds: [["bundleIdentifier": "com.example.App", "feedURL": "https://updates.example.com/feed.xml", "architectures": ["arm64"]]],
            officialSources: [UpdaterRuleFixture.official()],
            catalogVersions: [["token": "example", "bundleIdentifier": "com.example.App", "format": "plusBuild"]]
        ))
        XCTAssertEqual(rules.sparkleFeed(bundleIdentifier: "com.example.App", architecture: "arm64")?.feedURL,
                       "https://updates.example.com/feed.xml")
        XCTAssertNil(rules.sparkleFeed(bundleIdentifier: "com.example.App", architecture: "x86_64"))
        XCTAssertNil(rules.sparkleFeed(bundleIdentifier: "com.example.app", architecture: "arm64"))
        XCTAssertFalse(try XCTUnwrap(rules.officialSource(bundleIdentifier: "com.example.App")).usesBuild)
        XCTAssertEqual(rules.officialSource(bundleIdentifier: "com.example.App")?.channelPolicy, .numericStable)
        XCTAssertFalse(try XCTUnwrap(rules.officialSource(bundleIdentifier: "com.example.App")).allowsNoUpdate204)
        XCTAssertEqual(rules.catalogVersion(token: "example", bundleIdentifier: "com.example.App")?.format, .plusBuild)
        XCTAssertNil(rules.catalogVersion(token: "example@beta", bundleIdentifier: "com.example.App"))
        XCTAssertNil(rules.catalogVersion(token: "example", bundleIdentifier: "com.example.Other"))
    }

    #if !SWIFT_PACKAGE
    func testBundledResourceRetainsAllPreviouslyVerifiedProviders() {
        let rules = UpdaterRuleSet.bundled()
        XCTAssertEqual(rules.sparkleFeeds.count, 6)
        XCTAssertEqual(rules.officialSources.count, 18)
        XCTAssertEqual(rules.catalogVersions.count, 7)
        XCTAssertEqual(rules.sparkleFeed(bundleIdentifier: "dev.kdrag0n.MacVirt", architecture: "arm64")?.feedURL,
                       "https://api-updates.orbstack.dev/arm64/appcast.xml?bucket=")
        XCTAssertNil(rules.sparkleFeed(bundleIdentifier: "dev.kdrag0n.MacVirt", architecture: "x86_64"))
        XCTAssertEqual(rules.officialSource(bundleIdentifier: "com.jetbrains.toolbox")?.endpointTemplate,
                       "https://data.services.jetbrains.com/products/releases?code=TBA&type=release")
        XCTAssertEqual(rules.catalogVersion(token: "rider", bundleIdentifier: "com.jetbrains.rider")?.buildPrefix, "RD-")
    }
    #endif

    func testRejectsUnknownSchemaAndNonpositiveRevision() throws {
        for schema in [0, 2] {
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(schemaVersion: schema)))
        }
        for revision in [0, -1] {
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(revision: revision)))
        }
    }

    func testRejectsMalformedOversizedAndUnknownAdapterDocuments() throws {
        XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(Data("{}".utf8)))
        XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(Data(repeating: 32, count: 256 * 1024 + 1)))
        for field in ["kind", "channelPolicy"] {
            var rule = UpdaterRuleFixture.official()
            rule[field] = "future-adapter"
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])))
        }
        XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(catalogVersions: [
            ["token": "example", "bundleIdentifier": "com.example.App", "format": "future-format"]
        ])))
    }

    func testRejectsDuplicateIdentifiersInEveryRuleFamily() throws {
        let sparkle: [String: Any] = ["bundleIdentifier": "com.example.App", "feedURL": "https://updates.example.com/feed"]
        let official = UpdaterRuleFixture.official()
        let catalog: [String: Any] = ["token": "example", "bundleIdentifier": "com.example.App", "format": "downloadHash"]
        for document in [
            UpdaterRuleFixture.data(sparkleFeeds: [sparkle, sparkle]),
            UpdaterRuleFixture.data(officialSources: [official, official]),
            UpdaterRuleFixture.data(catalogVersions: [catalog, catalog])
        ] {
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(document))
        }
    }

    func testRejectsUnsafeURLsAcrossFeedsEndpointsAndLandingPages() throws {
        let unsafe = [
            "http://updates.example.com/feed", credentialBearingURL,
            "https://updates.example.com/feed#fragment", "https://localhost/feed",
            "https://updates.local/feed", "https://localhost.localdomain/feed", "https://updates.internal/feed", "https://updates.lan/feed",
            "https://router.home.arpa/feed", "https://127.0.0.1/feed", "https://[::1]/feed",
            "https://[::ffff:127.0.0.1]/feed", "https://10.0.0.1/feed", "https://192.168.1.1/feed",
            "https://172.16.0.1/feed", "https://169.254.169.254/feed", "https://0.0.0.0/feed",
            "https://2130706433/feed", "https://0177.0.0.1/feed", "https://0x7f.0x0.0x0.0x1/feed",
            "https://127.1/feed", "https://example.com./feed",
            "https://example.com\\@localhost/feed", " https://updates.example.com/feed"
        ]
        for value in unsafe {
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(sparkleFeeds: [
                ["bundleIdentifier": "com.example.App", "feedURL": value]
            ])), value)
            for field in ["endpointTemplate", "page"] {
                var rule = UpdaterRuleFixture.official()
                rule[field] = value
                XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])), value)
            }
        }
    }

    func testOnlyKnownPlaceholdersOutsideTheHostAreAccepted() throws {
        for placeholder in ["darwinPlatform", "macPlatform", "chromePlatform", "braveChannel"] {
            var rule = UpdaterRuleFixture.official()
            rule["endpointTemplate"] = "https://updates.example.com/{\(placeholder)}/latest"
            XCTAssertNoThrow(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])))
        }
        for endpoint in ["https://{darwinPlatform}.example.com/latest", "https://updates.example.com/{unknown}",
                         "https://updates.example.com/{darwinPlatform", "https://updates.example.com/latest}"] {
            var rule = UpdaterRuleFixture.official()
            rule["endpointTemplate"] = endpoint
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])))
        }
    }

    func testAdapterSpecificRequiredFieldsAndGitHubIdentityAreValidated() throws {
        var json = UpdaterRuleFixture.official()
        json.removeValue(forKey: "versionKey")
        var jetbrains = UpdaterRuleFixture.official(kind: "jetbrains")
        jetbrains.removeValue(forKey: "versionKey")
        var github = UpdaterRuleFixture.official(kind: "github")
        github.removeValue(forKey: "versionKey")
        for rule in [json, jetbrains, github] {
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])))
        }
        github["githubOwner"] = "example-org"
        github["githubRepository"] = "example-app"
        github["endpointTemplate"] = "https://api.github.com/repos/example-org/example-app/releases/latest"
        XCTAssertNoThrow(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [github])))
        for endpoint in ["https://api.github.com/repos/another-org/example-app/releases/latest",
                         "https://updates.example.com/repos/example-org/example-app/releases/latest",
                         "https://api.github.com/repos/example-org/example-app/releases/latest?redirect=1"] {
            github["endpointTemplate"] = endpoint
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [github])))
        }
    }

    func testRejectsInvalidArchitecturesIdentifiersAndBuildPrefixes() throws {
        for architecture in [[], ["arm64", "arm64"], ["future-cpu"]] as [[String]] {
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(sparkleFeeds: [
                ["bundleIdentifier": "com.example.App", "feedURL": "https://updates.example.com/feed", "architectures": architecture]
            ])))
        }
        for bundleID in ["", "com.example.*", "com.example.App ", "example"] {
            var rule = UpdaterRuleFixture.official()
            rule["bundleIdentifier"] = bundleID
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])))
        }
        for prefix in [nil, "", "DB-\n"] as [String?] {
            var rule: [String: Any] = ["token": "example", "bundleIdentifier": "com.example.App", "format": "prefixedBuild"]
            rule["buildPrefix"] = prefix
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(catalogVersions: [rule])))
        }
    }

    func testJetBrainsLocalProductAliasIsScopedAndValidated() throws {
        var rule = UpdaterRuleFixture.official(kind: "jetbrains")
        rule.removeValue(forKey: "versionKey")
        rule["productCode"] = "DG"
        rule["localProductCode"] = "DB"
        let rules = try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule]))
        XCTAssertEqual(rules.officialSource(bundleIdentifier: "com.example.App")?.localProductCode, "DB")
        for code in ["", "DB ", "../DB", "db"] {
            rule["localProductCode"] = code
            XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])))
        }
        rule["productCode"] = "TBA"
        rule["localProductCode"] = "DB"
        rule["usesBuild"] = true
        XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [rule])))
        var json = UpdaterRuleFixture.official()
        json["localProductCode"] = "DB"
        XCTAssertThrowsError(try UpdaterRuleSet.decodeValidated(UpdaterRuleFixture.data(officialSources: [json])))
    }
}

enum UpdaterRuleFixture {
    static func data(schemaVersion: Int = 1, revision: Int = 1,
                     sparkleFeeds: [[String: Any]] = [], officialSources: [[String: Any]] = [],
                     catalogVersions: [[String: Any]] = []) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion, "revision": revision, "sparkleFeeds": sparkleFeeds,
            "officialSources": officialSources, "catalogVersions": catalogVersions
        ], options: [.sortedKeys])
    }

    static func rules(revision: Int = 1) -> UpdaterRuleSet {
        try! UpdaterRuleSet.decodeValidated(data(revision: revision, officialSources: [official()]))
    }

    static func official(kind: String = "json") -> [String: Any] {
        ["bundleIdentifier": "com.example.App", "kind": kind, "versionKey": "version",
         "endpointTemplate": "https://updates.example.com/latest", "page": "https://example.com/download"]
    }
}
