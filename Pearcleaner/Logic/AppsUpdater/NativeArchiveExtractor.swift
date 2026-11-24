import Foundation
import Darwin

/// Uses Apple's bundle-aware extractor behind a write-restricted Seatbelt sandbox.
/// Unsupported ZIP features fail closed before any extraction starts.
enum NativeArchiveExtractor {
    static func extract(_ archive: URL, format: NativeUpdateArtifact.Format, in workspace: URL) throws -> URL {
        let destination = workspace.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        switch format {
        case .zip:
            try inspectZIP(archive)
            let profile = try extractionProfile(for: destination)
            // A fixed shell fragment sets a per-file kernel limit, then replaces itself with ditto.
            // No payload text is interpreted as shell syntax; paths are separate argv values.
            _ = try NativeSystemTool.run("/usr/bin/sandbox-exec", ["-p", profile, "/bin/sh", "-c",
                "ulimit -f \"$1\" || exit 1; shift; exec /usr/bin/ditto -x -k --rsrc --qtn \"$1\" \"$2\"", "native-extract",
                String(NativeAppValidation.maximumFileBytes / 1024), archive.path, destination.path],
                timeout: 300, monitor: { try checkExtractionBudget(destination) })
            let app = try selectApplication(in: destination, format: format)
            try NativeAppValidation.validateTree(app)
            return app
        case .dmg:
            let mount = workspace.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var detachNeeded = true
            defer { if detachNeeded, isMounted(mount) { try? detach(mount) } }
            do {
                _ = try NativeSystemTool.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-owners", "off", "-mountpoint", mount.path, archive.path], timeout: 180, cancellable: false)
                try Task.checkCancellation()
                let app = try selectApplication(in: mount, format: format)
                try NativeAppValidation.validateTree(app)
                let copied = destination.appendingPathComponent(app.lastPathComponent)
                try NativeBundleCopy.copy(app, to: copied)
                try NativeAppValidation.validateTree(copied)
                try detach(mount)
                detachNeeded = false
                return copied
            } catch {
                if !isMounted(mount) { detachNeeded = false; throw error }
                do { try detach(mount); detachNeeded = false }
                catch { throw NativeInstallError.recoveryRequired(mount) }
                throw error
            }
        }
    }

    static func inspectZIP(_ archive: URL) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 22, length <= 4 * 1024 * 1024 * 1024 else { throw invalidZIP() }
        let tailSize = min(length, 65_557)
        try file.seek(toOffset: length - tailSize)
        let tail = try read(file, Int(tailSize))
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(index) == 0x06054b50, index + 22 + Int(tail.u16(index + 20)) == tail.count { end = index; break }
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10) else { throw invalidZIP() }
        let entries = Int(tail.u16(end + 10))
        let centralSize = UInt64(tail.u32(end + 12))
        let centralOffset = UInt64(tail.u32(end + 16))
        guard entries > 0, entries < 65_535, entries <= NativeAppValidation.maximumEntries,
              centralOffset + centralSize == length - tailSize + UInt64(end), centralSize <= 128 * 1024 * 1024 else { throw invalidZIP() }
        var offset = centralOffset
        var expanded: UInt64 = 0
        var names = Set<String>()
        var symlinks = Set<String>()
        for _ in 0..<entries {
            try Task.checkCancellation()
            try file.seek(toOffset: offset)
            let header = try read(file, 46)
            guard header.u32(0) == 0x02014b50 else { throw invalidZIP() }
            let flags = header.u16(8)
            let method = header.u16(10)
            let compressedSize = UInt64(header.u32(20))
            let size = UInt64(header.u32(24))
            let nameLength = Int(header.u16(28))
            let extraLength = Int(header.u16(30))
            let commentLength = Int(header.u16(32))
            let localOffset = UInt64(header.u32(42))
            guard flags & 0x2041 == 0, method == 0 || method == 8,
                  header.u16(34) == 0, nameLength > 0, nameLength <= 4096,
                  size <= UInt64(NativeAppValidation.maximumFileBytes), compressedSize < UInt32.max,
                  localOffset + 30 < centralOffset else { throw invalidZIP() }
            let rawName = try read(file, nameLength)
            guard let name = String(data: rawName, encoding: .utf8), validArchivePath(name) else { throw invalidZIP() }
            let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(normalized).inserted else { throw invalidZIP() }
            let mode = UInt16(header.u32(38) >> 16)
            let type = mode & UInt16(S_IFMT)
            guard [0, UInt16(S_IFREG), UInt16(S_IFDIR), UInt16(S_IFLNK)].contains(type), mode & UInt16(S_ISUID | S_ISGID) == 0 else { throw invalidZIP() }
            if type == UInt16(S_IFLNK) { symlinks.insert(normalized) }
            expanded += size
            guard expanded <= UInt64(NativeAppValidation.maximumExpandedBytes) else { throw invalidZIP() }
            offset += UInt64(46 + nameLength + extraLength + commentLength)
            guard offset <= centralOffset + centralSize else { throw invalidZIP() }
            try file.seek(toOffset: localOffset)
            let local = try read(file, 30)
            guard local.u32(0) == 0x04034b50, local.u16(6) == flags, local.u16(8) == method,
                  Int(local.u16(26)) == nameLength,
                  localOffset + UInt64(30 + nameLength + Int(local.u16(28))) + compressedSize <= centralOffset,
                  try read(file, nameLength) == rawName else { throw invalidZIP() }
            if flags & 8 == 0 {
                guard local.u32(18) == UInt32(compressedSize), local.u32(22) == UInt32(size) else { throw invalidZIP() }
            }
        }
        guard offset == centralOffset + centralSize else { throw invalidZIP() }
        for name in names {
            var components = name.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                guard !symlinks.contains(components.joined(separator: "/")) else { throw invalidZIP() }
            }
        }
    }

    static func selectApplication(in root: URL, format: NativeUpdateArtifact.Format) throws -> URL {
        var apps: [URL] = []
        var count = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        func visit(_ directory: URL, depth: Int) throws {
            guard depth <= 4 else { throw NativeInstallError.invalidPayload("The archive has an unsupported directory layout.") }
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
                count += 1
                guard count <= NativeAppValidation.maximumEntries else { throw invalidZIP() }
                let name = item.lastPathComponent
                let attributes = try item.resourceValues(forKeys: keys)
                if attributes.isSymbolicLink == true {
                    if name == "Applications", try FileManager.default.destinationOfSymbolicLink(atPath: item.path) == "/Applications" { continue }
                    throw NativeInstallError.invalidPayload("The archive has an unexpected top-level symbolic link.")
                }
                if item.pathExtension.lowercased() == "app", attributes.isDirectory == true { apps.append(item); continue }
                if [".DS_Store", ".VolumeIcon.icns", ".background", "__MACOSX", ".fseventsd", ".Trashes"].contains(name) { continue }
                // Some disk-image builders store Finder window artwork directly at the volume root.
                if format == .dmg, depth == 0, name == ".background.tiff", attributes.isRegularFile == true,
                   try hasTIFFHeader(item) { continue }
                if attributes.isDirectory == true { try visit(item, depth: depth + 1); continue }
                let lower = name.lowercased()
                guard lower.hasPrefix("readme") || lower.hasPrefix("license") || lower.hasPrefix("licence") else {
                    throw NativeInstallError.invalidPayload("The archive includes additional installation components.")
                }
            }
        }
        try visit(root, depth: 0)
        guard apps.count == 1, let app = apps.first else { throw NativeInstallError.invalidPayload("The archive must contain exactly one application.") }
        return app
    }

    private static func hasTIFFHeader(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 4) else { return false }
        return header == Data([0x49, 0x49, 0x2a, 0x00]) || header == Data([0x4d, 0x4d, 0x00, 0x2a])
    }

    static func extractionProfile(for destination: URL) throws -> String {
        // Foundation may retain system aliases such as /var. Seatbelt checks the physical /private/var path.
        guard destination.isFileURL, let physical = realpath(destination.path, nil) else {
            throw NativeInstallError.invalidPayload("Cannot resolve the extraction directory.")
        }
        defer { free(physical) }
        return "(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)(allow file-read*)(allow file-write* (subpath \(sandboxLiteral(String(cString: physical)))))"
    }

    static func checkExtractionBudget(_ root: URL,
                                      metadataBytes: (URL) throws -> Int64 = NativeAppValidation.extendedAttributeBytes) throws {
        var size = try metadataBytes(root)
        var entries = 0
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { throw invalidZIP() }
        for case let file as URL in iterator {
            entries += 1
            guard entries <= NativeAppValidation.maximumEntries else { throw invalidZIP() }
            do {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                let attributes = try metadataBytes(file)
                if values.isSymbolicLink != true { size += Int64(values.fileSize ?? 0) }
                size += attributes
            } catch {
                // ditto atomically moves .BC.* temporary entries. Only a confirmed disappearance is transient.
                var info = stat()
                if lstat(file.path, &info) != 0, errno == ENOENT { continue }
                throw error
            }
            guard size <= NativeAppValidation.maximumExpandedBytes else { throw invalidZIP() }
        }
    }

    private static func isMounted(_ mount: URL) -> Bool {
        var filesystem = statfs()
        guard statfs(mount.path, &filesystem) == 0 else { return false }
        let path = withUnsafePointer(to: &filesystem.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().path
    }

    private static func detach(_ mount: URL) throws {
        do { _ = try NativeSystemTool.run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 30, cancellable: false) }
        catch { _ = try NativeSystemTool.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], timeout: 30, cancellable: false) }
    }

    private static func validArchivePath(_ value: String) -> Bool {
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains("..") && !parts.contains(".") && !parts.dropLast().contains("")
    }
    private static func sandboxLiteral(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private static func invalidZIP() -> NativeInstallError { .invalidPayload("The archive is malformed, unsafe, or exceeds supported extraction limits.") }
    private static func read(_ file: FileHandle, _ count: Int) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else { throw invalidZIP() }
        return data
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
