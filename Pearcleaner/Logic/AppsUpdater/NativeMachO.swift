import Foundation
import Darwin

/// Reads bounded Mach-O headers directly; no Xcode/Command Line Tools dependency.
enum NativeMachO {
    static var hostArchitecture: String {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0, arm == 1 { return "arm64" }
        return "x86_64"
    }

    static func validate(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 32, length <= UInt64(NativeAppValidation.maximumFileBytes) else { throw invalid() }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= length, UInt64(count) <= length - offset else { throw invalid() }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { throw invalid() }
            return data
        }
        let first = try read(0, 32)
        let cpu: UInt32 = hostArchitecture == "arm64" ? 0x0100000c : 0x01000007
        var offset: UInt64 = 0
        var sliceSize = length
        let magic = first.word(0, bigEndian: true)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = Int(first.word(4, bigEndian: true))
            let entrySize = magic == 0xcafebabf ? 32 : 20
            guard count > 0, count <= 64 else { throw invalid() }
            let table = try read(8, count * entrySize)
            var found = false
            for index in 0..<count {
                let base = index * entrySize
                if table.word(base, bigEndian: true) == cpu {
                    guard !found else { continue }
                    if entrySize == 32 {
                        offset = table.longWord(base + 8)
                        sliceSize = table.longWord(base + 16)
                    } else {
                        offset = UInt64(table.word(base + 8, bigEndian: true))
                        sliceSize = UInt64(table.word(base + 12, bigEndian: true))
                    }
                    guard offset >= UInt64(8 + count * entrySize), offset <= length, sliceSize <= length - offset else { throw invalid() }
                    found = true
                }
            }
            guard found else { throw invalid() }
        }
        let header = try read(offset, 32)
        guard header.word(0) == 0xfeedfacf, header.word(4) == cpu,
              header.word(12) == 2 else { throw invalid() } // MH_EXECUTE, not a dylib or object.
        let subtype = header.word(8) & 0x00ff_ffff
        if cpu == 0x0100000c {
            guard [0, 1, 2].contains(subtype) else { throw invalid() }
        } else if subtype == 8 {
            var supported: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.optional.avx2_0", &supported, &size, nil, 0) == 0, supported == 1 else { throw invalid() }
        } else if subtype != 3 { throw invalid() }
        let commandCount = Int(header.word(16))
        let commandsSize = Int(header.word(20))
        guard commandCount > 0, commandCount <= 65_536, commandsSize <= 16 * 1024 * 1024,
              UInt64(commandsSize + 32) <= sliceSize else { throw invalid() }
        let commands = try read(offset + 32, commandsSize)
        var cursor = 0
        var minimum: UInt32?
        for _ in 0..<commandCount {
            guard cursor + 8 <= commands.count else { throw invalid() }
            let command = commands.word(cursor)
            let size = Int(commands.word(cursor + 4))
            guard size >= 8, size % 4 == 0, size <= commands.count - cursor else { throw invalid() }
            if command == 0x32 { // LC_BUILD_VERSION
                guard size >= 24, commands.word(cursor + 8) == 1, minimum == nil else { throw invalid() }
                minimum = commands.word(cursor + 12)
            } else if command == 0x24 { // LC_VERSION_MIN_MACOSX
                guard size >= 16, minimum == nil else { throw invalid() }
                minimum = commands.word(cursor + 8)
            } else if [0x25, 0x2f, 0x30].contains(command) {
                throw invalid() // iOS, tvOS and watchOS minimum-version commands.
            }
            cursor += size
        }
        guard cursor == commands.count, let minimum else { throw invalid() }
        let version = "\(minimum >> 16).\((minimum >> 8) & 255).\(minimum & 255)"
        let current = ProcessInfo.processInfo.operatingSystemVersion
        guard let order = UpdateVersionComparator.compare(installed: version, available: "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"), order != .orderedDescending else { throw invalid() }
    }

    private static func invalid() -> NativeInstallError {
        .invalidPayload("The executable has an unsupported architecture, platform, or minimum macOS version.")
    }
}

private extension Data {
    func word(_ index: Int, bigEndian: Bool = false) -> UInt32 {
        if bigEndian {
            return UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
        }
        return UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }
    func longWord(_ index: Int) -> UInt64 { UInt64(word(index, bigEndian: true)) << 32 | UInt64(word(index + 4, bigEndian: true)) }
}
