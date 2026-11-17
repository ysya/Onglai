import XCTest
import Darwin
@testable import Pearcleaner

final class NativeBundleCopyTests: XCTestCase {
    func testPreservesContainedLinksAndExtendedAttributes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-copy-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("data")
        try Data("payload".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "data")
        let attribute = Data("metadata".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes { setxattr(file.path, "com.example.native-test", $0.baseAddress, $0.count, 0, 0) }, 0)
        let copy = root.appendingPathComponent("Copy.app")
        try NativeBundleCopy.copy(source, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("link")), Data("payload".utf8))
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = getxattr(copy.appendingPathComponent("data").path, "com.example.native-test", &buffer, buffer.count, 0, 0)
        XCTAssertEqual(size, 8)
        XCTAssertEqual(Data(buffer.prefix(8)), attribute)
    }

    func testCopiesResourceForkAndRejectsOversizedResourceFork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-fork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("data")
        try Data("data".utf8).write(to: file)
        let fork = Data("resource-fork".utf8)
        XCTAssertEqual(fork.withUnsafeBytes { setxattr(file.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }, 0)
        let copy = root.appendingPathComponent("Copy.app")
        try NativeBundleCopy.copy(source, to: copy)
        var bytes = [UInt8](repeating: 0, count: 32)
        let size = getxattr(copy.appendingPathComponent("data").path, "com.apple.ResourceFork", &bytes, bytes.count, 0, 0)
        XCTAssertEqual(size, fork.count)
        XCTAssertEqual(Data(bytes.prefix(fork.count)), fork)
        let descriptor = open(file.path + "/..namedfork/rsrc", O_WRONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(ftruncate(descriptor, NativeAppValidation.maximumAttributeBytes + 1), 0)
        XCTAssertEqual(fsync(descriptor), 0)
        close(descriptor)
        XCTAssertThrowsError(try NativeBundleCopy.copy(source, to: root.appendingPathComponent("Rejected.app")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rejected.app").path))
    }

    func testRejectsOversizedSparseFileBeforeCopyingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-copy-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("oversized")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(NativeAppValidation.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try NativeBundleCopy.copy(source, to: root.appendingPathComponent("Copy.app")))
    }
}
