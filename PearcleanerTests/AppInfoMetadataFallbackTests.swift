import XCTest
@testable import Pearcleaner

@MainActor
final class AppInfoMetadataFallbackTests: XCTestCase {
    func testEmptyMetadataLoadsAppFromBundle() throws {
        let appURL = try makeAppBundle()
        let app = try XCTUnwrap(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(fromMetadata: [:], atPath: appURL))

        XCTAssertEqual(app.path, appURL)
        XCTAssertEqual(app.bundleIdentifier, "com.example.metadata-fixture")
        XCTAssertEqual(app.appName, "Metadata Fixture")
        XCTAssertEqual(app.appVersion, "1.2.3")
    }

    func testMissingMetadataBundleIdentifierLoadsAppFromBundle() throws {
        let appURL = try makeAppBundle()
        let app = try XCTUnwrap(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(
            fromMetadata: ["kMDItemDisplayName": "Indexed Fixture.app"],
            atPath: appURL
        ))

        XCTAssertEqual(app.bundleIdentifier, "com.example.metadata-fixture")
        XCTAssertEqual(app.appVersion, "1.2.3")
    }

    func testAbsentMetadataLoadsAppFromBundle() throws {
        let appURL = try makeAppBundle()
        let app = try XCTUnwrap(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(fromMetadata: nil, atPath: appURL))

        XCTAssertEqual(app.bundleIdentifier, "com.example.metadata-fixture")
        XCTAssertEqual(app.appVersion, "1.2.3")
    }

    func testAppWithoutVersionIsStillLoaded() throws {
        let appURL = try makeAppBundle(includeVersion: false)
        let app = try XCTUnwrap(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(
            fromMetadata: ["kMDItemCFBundleIdentifier": "com.example.metadata-fixture"],
            atPath: appURL
        ))

        XCTAssertEqual(app.bundleIdentifier, "com.example.metadata-fixture")
        XCTAssertEqual(app.appVersion, "")
    }

    func testBundleFallbackPreservesAvailableMetadataDates() throws {
        let appURL = try makeAppBundle()
        let creation = Date(timeIntervalSince1970: 1_700_000_000)
        let changed = Date(timeIntervalSince1970: 1_700_000_100)
        let lastUsed = Date(timeIntervalSince1970: 1_700_000_200)
        let added = Date(timeIntervalSince1970: 1_700_000_300)
        let app = try XCTUnwrap(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(
            fromMetadata: [
                "kMDItemFSCreationDate": creation,
                "kMDItemFSContentChangeDate": changed,
                "kMDItemLastUsedDate": lastUsed,
                "kMDItemDateAdded": added
            ],
            atPath: appURL
        ))

        XCTAssertEqual(app.creationDate, creation)
        XCTAssertEqual(app.contentChangeDate, changed)
        XCTAssertEqual(app.lastUsedDate, lastUsed)
        XCTAssertEqual(app.dateAdded, added)
    }

    func testCompleteMetadataKeepsIndexedDisplayNameAndSize() throws {
        let appURL = try makeAppBundle()
        let app = try XCTUnwrap(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(
            fromMetadata: [
                "kMDItemDisplayName": "Indexed Fixture.app",
                "kMDItemCFBundleIdentifier": "com.example.metadata-fixture",
                "kMDItemLogicalSize": Int64(4096)
            ],
            atPath: appURL
        ))

        XCTAssertEqual(app.appName, "Indexed Fixture")
        XCTAssertEqual(app.bundleSize, 4096)
        XCTAssertEqual(app.appVersion, "1.2.3")
    }

    func testMissingBundleRemainsExcluded() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Missing.app")

        XCTAssertNil(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(fromMetadata: [:], atPath: appURL))
    }

    func testBundleWithoutIdentifierRemainsExcluded() throws {
        let appURL = try makeAppBundle(bundleIdentifier: nil)

        XCTAssertNil(MetadataAppInfoFetcher.getAppInfoMiniForStreaming(fromMetadata: [:], atPath: appURL))
    }

    func testFullLoadPreservesWrappedAppClassification() async throws {
        let originalAppURL = try makeAppBundle()
        let directory = originalAppURL.deletingLastPathComponent()
        let outerAppURL = directory.appendingPathComponent("Wrapped Fixture.app")
        let wrapper = outerAppURL.appendingPathComponent("Wrapper")
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        let innerAppURL = wrapper.appendingPathComponent(originalAppURL.lastPathComponent)
        try FileManager.default.moveItem(at: originalAppURL, to: innerAppURL)

        // Full loading must keep its direct fallback, which preserves wrapped classification.
        XCTAssertNil(MetadataAppInfoFetcher.getAppInfoMini(fromMetadata: [:], atPath: outerAppURL))

        let apps = await Task.detached {
            getSortedApps(paths: [directory.path], useStreaming: false)
        }.value
        let app = try XCTUnwrap(apps.first)

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(app.path.resolvingSymlinksInPath().path, innerAppURL.resolvingSymlinksInPath().path)
        XCTAssertTrue(app.wrapped)
    }

    private func makeAppBundle(includeVersion: Bool = true, bundleIdentifier: String? = "com.example.metadata-fixture") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appURL = directory.appendingPathComponent("Metadata Fixture.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        var info: [String: Any] = [
            "CFBundleName": "Metadata Fixture",
            "CFBundlePackageType": "APPL"
        ]
        if let bundleIdentifier {
            info["CFBundleIdentifier"] = bundleIdentifier
        }
        if includeVersion {
            info["CFBundleShortVersionString"] = "1.2.3"
            info["CFBundleVersion"] = "123"
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }
}
