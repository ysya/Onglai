import XCTest
@testable import Pearcleaner

final class KnownSparkleFeedsTests: XCTestCase {
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
            XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: identifier, information: [:], architecture: "arm64")?.absoluteString, url)
        }
    }

    func testDoesNotInferFeedsForSimilarNamesOrUnsafeMappings() {
        for identifier in ["com.openai.chat", "com.openai.codex.beta", "com.mitchellh.ghostty.debug", "io.tailscale.ipn.macos", "com.teamviewer.TeamViewer", "info.marcel-dierkes.KeepingYouAwake"] {
            XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: identifier, information: [:], architecture: "arm64"))
        }
    }

    func testKeepsAnExplicitTipFeedInsteadOfSwitchingGhosttyToStable() {
        let information = ["SUFeedURL": "https://tip.files.ghostty.org/appcast.xml"]
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.mitchellh.ghostty", information: information)?.absoluteString, "https://tip.files.ghostty.org/appcast.xml")
    }

    func testDoesNotSwitchStableGhosttyToTipBasedOnlyOnVersionText() {
        let information = ["CFBundleShortVersionString": "1.4.0-dev+abcdef"]
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.mitchellh.ghostty", information: information)?.absoluteString, "https://release.files.ghostty.org/appcast.xml")
    }

    func testOnlyUsesTheVerifiedOrbStackArchitecture() {
        XCTAssertNotNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "dev.kdrag0n.MacVirt", information: [:], architecture: "arm64"))
        XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "dev.kdrag0n.MacVirt", information: [:], architecture: "x86_64"))
        XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "dev.kdrag0n.MacVirt", information: [:], architecture: "unknown"))
    }

    func testRejectsMalformedExplicitFeedsAndUsesKnownRuntimeFallback() {
        for rawFeed in ["", "NULL", "(null)", "nil", "relative/appcast.xml", "file:///tmp/appcast.xml", "https:///appcast.xml"] {
            XCTAssertNil(KnownSparkleFeeds.validatedFeedURL(from: rawFeed))
            XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "com.mitchellh.ghostty", information: ["SUFeedURL": rawFeed])?.absoluteString, "https://release.files.ghostty.org/appcast.xml")
            XCTAssertNil(KnownSparkleFeeds.feedURL(bundleIdentifier: "example.unknown", information: ["SUFeedURL": rawFeed]))
        }
    }

    func testPreservesAValidExplicitPublisherFeed() {
        XCTAssertEqual(KnownSparkleFeeds.feedURL(bundleIdentifier: "example.unknown", information: ["SUFeedURL": "  'https://publisher.example/appcast.xml'  "])?.absoluteString, "https://publisher.example/appcast.xml")
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
}
