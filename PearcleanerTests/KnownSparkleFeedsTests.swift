import XCTest
@testable import Pearcleaner

final class KnownSparkleFeedsTests: XCTestCase {
    private let bundledRules = UpdaterRuleSet.bundled()

    func testResolvesVerifiedRuntimeFeedsByExactBundleIdentifier() {
        let expected = [
            "com.openai.codex": "https://persistent.oaistatic.com/codex-app-prod/appcast.xml",
            "com.mitchellh.ghostty": "https://release.files.ghostty.org/appcast.xml",
            "io.tailscale.ipn.macsys": "https://pkgs.tailscale.com/stable/appcast.xml",
            "dev.kdrag0n.MacVirt": "https://api-updates.orbstack.dev/arm64/appcast.xml?bucket=",
            "company.thebrowser.dia": "https://releases.diabrowser.com/BoostBrowser-updates.xml",
            "com.cloudflare.1dot1dot1dot1.macos": "https://downloads.cloudflareclient.com/v1/update/sparkle/macos/ga"
        ]

        for (identifier, url) in expected {
            XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: identifier, information: [:], architecture: "arm64", rules: bundledRules)?.absoluteString, url)
        }
    }

    func testDoesNotInferFeedsForSimilarNamesOrUnsafeMappings() {
        for identifier in ["com.openai.chat", "com.openai.codex.beta", "com.mitchellh.ghostty.debug", "io.tailscale.ipn.macos", "com.teamviewer.TeamViewer", "info.marcel-dierkes.KeepingYouAwake"] {
            XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: identifier, information: [:], architecture: "arm64", rules: bundledRules))
        }
    }

    func testKeepsAnExplicitTipFeedInsteadOfSwitchingGhosttyToStable() {
        let information = ["SUFeedURL": "https://tip.files.ghostty.org/appcast.xml"]
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.mitchellh.ghostty", information: information, rules: bundledRules)?.absoluteString, "https://tip.files.ghostty.org/appcast.xml")
    }

    func testDoesNotSwitchStableGhosttyToTipBasedOnlyOnVersionText() {
        let information = ["CFBundleShortVersionString": "1.4.0-dev+abcdef"]
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.mitchellh.ghostty", information: information, rules: bundledRules)?.absoluteString, "https://release.files.ghostty.org/appcast.xml")
    }

    func testOnlyUsesTheVerifiedOrbStackArchitecture() {
        XCTAssertNotNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "dev.kdrag0n.MacVirt", information: [:], architecture: "arm64", rules: bundledRules))
        XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "dev.kdrag0n.MacVirt", information: [:], architecture: "x86_64", rules: bundledRules))
        XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "dev.kdrag0n.MacVirt", information: [:], architecture: "unknown", rules: bundledRules))
    }

    func testRejectsMalformedExplicitFeedsAndUsesKnownRuntimeFallback() {
        for rawFeed in ["", "NULL", "(null)", "nil", "relative/appcast.xml", "file:///tmp/appcast.xml", "https:///appcast.xml"] {
            XCTAssertNil(KnownSparkleFeeds.validatedFeedURL(from: rawFeed))
            XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.mitchellh.ghostty", information: ["SUFeedURL": rawFeed], rules: bundledRules)?.absoluteString, "https://release.files.ghostty.org/appcast.xml")
            XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "example.unknown", information: ["SUFeedURL": rawFeed], rules: bundledRules))
        }
    }

    func testPreservesAValidExplicitPublisherFeed() {
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "example.unknown", information: ["SUFeedURL": "  'https://publisher.example/appcast.xml'  "], rules: bundledRules)?.absoluteString, "https://publisher.example/appcast.xml")
    }

    func testStableAndReleaseChannelsAreNotPrereleases() {
        for channel in [nil, "", "release", "stable", "Stable"] as [String?] {
            XCTAssertFalse(KnownSparkleFeeds.isPrereleaseChannel(channel))
        }
        for channel in ["beta", "nightly", "tip", "canary"] {
            XCTAssertTrue(KnownSparkleFeeds.isPrereleaseChannel(channel))
        }
        XCTAssertEqual(KnownSparkleFeeds.allowedChannels(includePreReleases: false), ["release", "stable"])
        XCTAssertTrue(KnownSparkleFeeds.allowedChannels(includePreReleases: true).isSuperset(of: ["stable", "release", "beta", "alpha", "nightly", "rc", "dev"]))
    }

    func testRejectsMalformedSigningKeysWithoutChangingLegacyDSAHandling() {
        for value: Any in ["", "NULL", "-----BEGIN PUBLIC KEY-----\ninvalid\n-----END PUBLIC KEY-----", Data(repeating: 1, count: 31).base64EncodedString(), 123] {
            XCTAssertTrue(KnownSparkleFeeds.hasInvalidEdDSAPublicKey(in: ["SUPublicEDKey": value]))
        }
        XCTAssertFalse(KnownSparkleFeeds.hasInvalidEdDSAPublicKey(in: ["SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]))
        XCTAssertFalse(KnownSparkleFeeds.hasInvalidEdDSAPublicKey(in: ["SUPublicDSAKeyFile": "dsa_pub.pem"]))
        XCTAssertFalse(KnownSparkleFeeds.hasInvalidEdDSAPublicKey(in: [:]))
    }
    func testInjectedRulesCanReplaceKnownFeedsAndAddAnExactBundleIdentifier() throws {
        let rules = try rules([
            ["bundleIdentifier": "com.mitchellh.ghostty", "feedURL": "https://updates.example.com/ghostty.xml"],
            ["bundleIdentifier": "com.example.NewEditor", "feedURL": "https://updates.example.com/editor.xml"]
        ])
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.mitchellh.ghostty", information: [:], rules: rules)?.absoluteString,
                       "https://updates.example.com/ghostty.xml")
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.example.NewEditor", information: [:], rules: rules)?.absoluteString,
                       "https://updates.example.com/editor.xml")
        XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.example.NewEditor.beta", information: [:], rules: rules))
    }

    func testInjectedFeedArchitectureRestrictionsStillYieldToAnExplicitPublisherFeed() throws {
        let rules = try rules([
            ["bundleIdentifier": "com.example.NewEditor", "feedURL": "https://updates.example.com/editor.xml", "architectures": ["arm64"]]
        ])
        XCTAssertNotNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.example.NewEditor", information: [:], architecture: "arm64", rules: rules))
        XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.example.NewEditor", information: [:], architecture: "x86_64", rules: rules))
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.example.NewEditor",
                                               information: ["SUFeedURL": "https://publisher.example.com/intel.xml"],
                                               architecture: "x86_64", rules: rules)?.absoluteString,
                       "https://publisher.example.com/intel.xml")
    }

    private func rules(_ feeds: [[String: Any]]) throws -> UpdaterRuleSet {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "revision": 2, "sparkleFeeds": feeds, "officialSources": [], "catalogVersions": []
        ])
        return try UpdaterRuleSet.decodeValidated(data)
    }


}
