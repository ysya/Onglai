import XCTest
@testable import Pearcleaner

final class NativeArchiveExtractorTests: XCTestCase {
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
