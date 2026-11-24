import XCTest
import Darwin
@testable import Pearcleaner

final class NativeArchiveExtractorTests: XCTestCase {
    func testDiskImageWithRootTIFFBackgroundSelectsTheApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data([0x4d, 0x4d, 0x00, 0x2a]).write(to: root.appendingPathComponent(".background.tiff"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Applications").path, withDestinationPath: "/Applications"
        )

        let selected = try NativeArchiveExtractor.selectApplication(in: root, format: .dmg)
        XCTAssertEqual(selected.resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)

        try Data("installer".utf8).write(to: root.appendingPathComponent("Installer.pkg"))
        XCTAssertThrowsError(try NativeArchiveExtractor.selectApplication(in: root, format: .dmg))
    }

    func testArchivesRejectTIFFBackgroundOutsideTheDiskImageRootAndRejectInvalidHeaders() throws {
        let tiff = Data([0x49, 0x49, 0x2a, 0x00])
        let cases: [(format: NativeUpdateArtifact.Format, path: String, contents: Data)] = [
            (.zip, ".background.tiff", tiff),
            (.dmg, "resources/.background.tiff", tiff),
            (.dmg, ".background.tiff", Data("not a TIFF".utf8))
        ]
        for test in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Fixture.app"), withIntermediateDirectories: true
            )
            let file = root.appendingPathComponent(test.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try test.contents.write(to: file)

            XCTAssertThrowsError(try NativeArchiveExtractor.selectApplication(in: root, format: test.format), test.path)
        }
    }

    func testSandboxedExtractionThroughAnAliasedWorkspacePreservesQuarantine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-alias-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Fixture.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source.appendingPathComponent("payload"))
        let archive = root.appendingPathComponent("payload.zip")
        _ = try NativeSystemTool.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, archive.path])
        try NativeArtifactDownload.quarantine(archive)
        let actual = root.appendingPathComponent("actual")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let app = try NativeArchiveExtractor.extract(archive, format: .zip, in: alias)
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("payload")), Data("fixture".utf8))
        XCTAssertGreaterThan(getxattr(app.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)
    }

    func testLiveBudgetToleratesAnEntryThatDisappearsDuringMetadataInspection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-live-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let transient = root.appendingPathComponent(".BC.fixture")
        try Data("temporary".utf8).write(to: transient)
        var observed = false
        XCTAssertNoThrow(try NativeArchiveExtractor.checkExtractionBudget(root, metadataBytes: { url in
            if url.lastPathComponent == transient.lastPathComponent {
                observed = true
                try FileManager.default.removeItem(at: url)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            return 0
        }))
        XCTAssertTrue(observed)
        XCTAssertThrowsError(try NativeAppValidation.extendedAttributeBytes(transient))
    }

    func testLiveBudgetStillRejectsInvalidMetadataForAnExistingEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-strict-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data("fixture".utf8).write(to: file)
        XCTAssertThrowsError(try NativeArchiveExtractor.checkExtractionBudget(root, metadataBytes: { url in
            if url.lastPathComponent == file.lastPathComponent {
                throw NativeInstallError.invalidPayload("Fixture oversized metadata")
            }
            return 0
        }))
    }

    func testExtractionSandboxStillRejectsWritesOutsideThePhysicalDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-sandbox-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let profile = try NativeArchiveExtractor.extractionProfile(for: alias)
        let outside = root.appendingPathComponent("outside")
        XCTAssertThrowsError(try NativeSystemTool.run("/usr/bin/sandbox-exec", ["-p", profile, "/bin/sh", "-c", "printf fixture > \"$1\"", "sandbox-test", outside.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testRejectsTraversalAndAbsoluteArchivePaths() throws {
        for path in ["../escape", "/tmp/escape", "App.app/../../escape", "App.app\\..\\escape"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = root.appendingPathComponent("bad.zip")
            try nativeTestZIP(name: path).write(to: archive)
            XCTAssertThrowsError(try NativeArchiveExtractor.inspectZIP(archive))
        }
    }

    func testRejectsDeclaredExpansionBomb() throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try nativeTestZIP(name: "App.app/file", expandedSize: UInt32.max - 1).write(to: archive)
        XCTAssertThrowsError(try NativeArchiveExtractor.inspectZIP(archive))
    }

    func testAcceptsOrdinaryBoundedZIPInventory() throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try nativeTestZIP(name: "App.app/file").write(to: archive)
        XCTAssertNoThrow(try NativeArchiveExtractor.inspectZIP(archive))
    }
}

private func nativeTestZIP(name: String, expandedSize: UInt32 = 0) -> Data {
    func u16(_ value: UInt16) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    func u32(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    let name = Data(name.utf8)
    var local = u32(0x04034b50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
    local += u32(0) + u32(0) + u32(expandedSize) + u16(UInt16(name.count)) + u16(0) + name
    var central = u32(0x02014b50) + u16(0x0314) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
    central += u32(0) + u32(0) + u32(expandedSize) + u16(UInt16(name.count)) + u16(0) + u16(0)
    central += u16(0) + u16(0) + u32(0o100644 << 16) + u32(0) + name
    let end = u32(0x06054b50) + u16(0) + u16(0) + u16(1) + u16(1) + u32(UInt32(central.count)) + u32(UInt32(local.count)) + u16(0)
    return local + central + end
}
