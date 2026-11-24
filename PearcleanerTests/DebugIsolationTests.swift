import AppKit
import XCTest
@testable import Pearcleaner

final class DebugIsolationTests: XCTestCase {
    @MainActor
    func testHostedTestsRunWithoutOpeningOnglai() {
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
        XCTAssertTrue(NSApplication.shared.windows.isEmpty)
    }

    func testCleanupPreservesTheOtherVariantsUpdateFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let production = directory.appendingPathComponent("pearcleaner-appstore-fixture")
        let debug = directory.appendingPathComponent("onglai-debug-appstore-fixture")
        let unrelated = directory.appendingPathComponent("unrelated")
        for url in [production, debug, unrelated] {
            try Data("fixture".utf8).write(to: url)
        }

        cleanupPearcleanerTempDirs(in: directory)

        #if DEBUG
        XCTAssertTrue(FileManager.default.fileExists(atPath: production.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: debug.path))
        #else
        XCTAssertFalse(FileManager.default.fileExists(atPath: production.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: debug.path))
        #endif
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCLIDetectionUsesTheCurrentVariantsLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = OnglaiIdentity.isDebug ? "ong-debug" : "ong"
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(name),
            withDestinationURL: XCTUnwrap(Bundle.main.executableURL)
        )
        XCTAssertTrue(checkCLISymlink(in: directory))
    }

    func testRuntimeServicesMatchTheEmbeddedLaunchdDefinitions() throws {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        for (identifier, folder) in [
            (OnglaiIdentity.helperIdentifier, "LaunchDaemons"),
            (OnglaiIdentity.sentinelIdentifier, "LaunchAgents")
        ] {
            let url = contents.appendingPathComponent("Library/\(folder)/\(identifier).plist")
            let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            XCTAssertEqual(plist["Label"] as? String, identifier)
            XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [OnglaiIdentity.bundleIdentifier])
            if folder == "LaunchDaemons" {
                XCTAssertEqual(plist["MachServices"] as? [String: Bool], [identifier: true])
            }
        }
    }
}
