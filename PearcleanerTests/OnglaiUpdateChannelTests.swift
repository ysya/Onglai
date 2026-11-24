import Foundation
import Sparkle
import XCTest
@testable import Pearcleaner

final class OnglaiUpdateChannelTests: XCTestCase {
    func testStableIgnoresBetaReleases() throws {
        let releases = try [release("5.6.3-beta.2", prerelease: true), release("5.6.2")]

        XCTAssertEqual(OnglaiUpdateChannel.stable.preferredRelease(in: releases)?.tagName, "5.6.2")
        XCTAssertEqual(OnglaiUpdateChannel.stable.sparkleChannels, [])
        XCTAssertEqual(OnglaiUpdateChannel.stable.releasesURL.path, "/repos/ysya/Onglai/releases/latest")
        XCTAssertEqual(OnglaiUpdateChannel.beta.releasesURL.path, "/repos/ysya/Onglai/releases")
    }

    func testBetaChoosesHighestVersionAndCanReturnToStable() throws {
        let releases = try [
            release("5.6.3-beta.10", prerelease: true),
            release("5.6.3-beta.2", prerelease: true),
            release("5.6.2")
        ]
        let beta = OnglaiUpdateChannel.beta.preferredRelease(in: releases)

        XCTAssertEqual(beta?.tagName, "5.6.3-beta.10")
        XCTAssertEqual(beta?.appcastURL?.absoluteString,
                       "https://github.com/ysya/Onglai/releases/download/5.6.3-beta.10/appcast.xml")
        XCTAssertEqual(OnglaiUpdateChannel.beta.sparkleChannels, ["beta"])

        let promoted = try release("5.6.3")
        XCTAssertEqual(OnglaiUpdateChannel.beta.preferredRelease(in: releases + [promoted])?.tagName, "5.6.3")
    }

    func testBetaRejectsDraftsWrongChannelsAndMissingAppcasts() throws {
        let releases = try [
            release("6.0.0-beta.3", prerelease: true, draft: true),
            release("6.0.0-beta.2", prerelease: true, appcastState: "open"),
            release("6.0.0-beta.1", prerelease: true, appcastState: nil),
            release("6.0.0-rc.1", prerelease: true),
            release("6.0.0-beta.4"),
            release("6.0.0-beta.5/../../other", prerelease: true),
            release("5.6.3-beta.2", prerelease: true)
        ]
        XCTAssertEqual(OnglaiUpdateChannel.beta.preferredRelease(in: releases)?.tagName, "5.6.3-beta.2")
    }

    func testInstalledBetaKeepsItsReleaseTagAndComparesWithinTheSameMarketingVersion() {
        let installed = OnglaiUpdateChannel.installedVersion(marketingVersion: "5.6.3", releaseTag: "5.6.3-beta.2")
        XCTAssertEqual(installed, "5.6.3-beta.2")
        XCTAssertEqual(UpdateVersionComparator.compare(installed: installed, available: "5.6.3-beta.3"), .orderedAscending)
        XCTAssertEqual(UpdateVersionComparator.compare(installed: installed, available: "5.6.3-beta.1"), .orderedDescending)
        XCTAssertEqual(OnglaiUpdateChannel.installedVersion(marketingVersion: "5.6.3", releaseTag: "5.6.2-beta.1"), "5.6.3")
        XCTAssertEqual(OnglaiUpdateChannel.installedVersion(marketingVersion: "5.6.3", releaseTag: nil), "5.6.3")
    }

    @MainActor
    func testSparkleUsesTheSelectedBetaFeedAndRestoresTheStableFeed() throws {
        let delegate = OnglaiSparkleDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil
        )
        let updater = controller.updater
        let stableFeed = try XCTUnwrap(updater.feedURL)
        XCTAssertEqual(stableFeed.path, "/ysya/Onglai/releases/latest/download/appcast.xml")

        delegate.channel = .beta
        delegate.betaFeed = try release("5.6.3-beta.2", prerelease: true).appcastURL
        XCTAssertEqual(updater.feedURL?.path, "/ysya/Onglai/releases/download/5.6.3-beta.2/appcast.xml")
        XCTAssertEqual(delegate.allowedChannels(for: updater), ["beta"])

        delegate.channel = .stable
        XCTAssertEqual(updater.feedURL, stableFeed)
        XCTAssertEqual(delegate.allowedChannels(for: updater), [])
    }

    private func release(
        _ tag: String, prerelease: Bool = false, draft: Bool = false, appcastState: String? = "uploaded"
    ) throws -> OnglaiRelease {
        let raw: [String: Any] = [
            "id": 1,
            "tag_name": tag,
            "html_url": "https://github.com/ysya/Onglai/releases",
            "published_at": "2026-11-25T00:00:00Z",
            "draft": draft,
            "prerelease": prerelease,
            "assets": appcastState.map {
                [["name": "appcast.xml", "state": $0, "browser_download_url": "https://example.invalid/appcast.xml"]]
            } ?? []
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OnglaiRelease.self, from: JSONSerialization.data(withJSONObject: raw))
    }
}
