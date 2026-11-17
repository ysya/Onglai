import XCTest
@testable import Pearcleaner

final class NativeMachOTests: XCTestCase {
    func testAcceptsNativeMacOSHeaderAndRejectsWrongCPUPlatformAndMinimum() throws {
        let nativeCPU: UInt32 = NativeMachO.hostArchitecture == "arm64" ? 0x0100000c : 0x01000007
        let foreignCPU: UInt32 = NativeMachO.hostArchitecture == "arm64" ? 0x01000007 : 0x0100000c
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-macho-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try macho(cpu: nativeCPU, platform: 1, minimum: 0x000d0000).write(to: file)
        XCTAssertNoThrow(try NativeMachO.validate(file))
        for data in [macho(cpu: foreignCPU, platform: 1, minimum: 0x000d0000),
                     macho(cpu: nativeCPU, platform: 2, minimum: 0x000d0000),
                     macho(cpu: nativeCPU, platform: 1, minimum: 0x00630000),
                     Data([0xcf, 0xfa, 0xed, 0xfe])] {
            try data.write(to: file)
            XCTAssertThrowsError(try NativeMachO.validate(file))
        }
    }

    private func macho(cpu: UInt32, platform: UInt32, minimum: UInt32) -> Data {
        let subtype: UInt32 = cpu == 0x0100000c ? 0 : 3
        let words: [UInt32] = [0xfeedfacf, cpu, subtype, 2, 1, 24, 0, 0, 0x32, 24, platform, minimum, minimum, 0]
        return words.reduce(into: Data()) { data, word in
            var word = word.littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
    }
}
