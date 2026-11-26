import Foundation
import Security
import Darwin

/// Validation is repeated before and after the atomic replacement.
enum NativeAppValidation {
    static let maximumExpandedBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maximumFileBytes: Int64 = 1024 * 1024 * 1024
    static let maximumEntries = 100_000
    static let maximumAttributeBytes: Int64 = 16 * 1024 * 1024

    struct Metadata {
        let identifier: String
        let version: String
        let build: String?
    }

    static func metadata(_ app: URL) throws -> Metadata {
        try validateAppPath(app)
        let info = app.appendingPathComponent("Contents/Info.plist")
        let attributes = try FileManager.default.attributesOfItem(atPath: info.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024,
              let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let version = dictionary["CFBundleShortVersionString"] as? String, !version.isEmpty,
              dictionary["CFBundlePackageType"] as? String == "APPL",
              let executable = dictionary["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
              dictionary["LSRequiresIPhoneOS"] as? Bool != true,
              dictionary["KSUpdateURL"] == nil, dictionary["KSProductID"] == nil,
              dictionary["CrAppModeShortcutID"] == nil else {
            throw NativeInstallError.invalidPayload("The application has unsupported or invalid metadata.")
        }
        if let minimum = dictionary["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard let order = UpdateVersionComparator.compare(installed: minimum, available: current), order != .orderedDescending else {
                throw NativeInstallError.invalidPayload("The update requires a newer macOS version.")
            }
        }
        if let platforms = dictionary["CFBundleSupportedPlatforms"] as? [String], !platforms.contains("MacOSX") {
            throw NativeInstallError.invalidPayload("The update is not a macOS application.")
        }
        let executableURL = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard isContained(executableURL.resolvingSymlinksInPath(), in: app), FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NativeInstallError.invalidPayload("The application executable is missing or escapes its bundle.")
        }
        let architecture = NativeMachO.hostArchitecture
        try NativeMachO.validate(executableURL)
        if let minimums = dictionary["LSMinimumSystemVersionByArchitecture"] as? [String: String], let minimum = minimums[architecture] {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard let order = UpdateVersionComparator.compare(installed: minimum, available: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"), order != .orderedDescending else {
                throw NativeInstallError.invalidPayload("The update requires a newer macOS version for this architecture.")
            }
        }
        return Metadata(identifier: identifier, version: version, build: dictionary["CFBundleVersion"] as? String)
    }

    static func validateAppPath(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              url.path != Bundle.main.bundleURL.resolvingSymlinksInPath().path else {
            throw NativeInstallError.invalidPayload("The application path is unsupported or is a symbolic link.")
        }
        guard !url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
            throw NativeInstallError.invalidPayload("Nested application bundles cannot be updated independently.")
        }
        for prefix in ["/System", "/usr", "/bin", "/sbin", "/Library", "/opt", "/Volumes", "/Applications/Utilities"] {
            guard url.path != prefix, !url.path.hasPrefix(prefix + "/") else {
                throw NativeInstallError.invalidPayload("System applications cannot be replaced by this updater.")
            }
        }
        for relative in ["Contents/_MASReceipt/receipt", "Wrapper", "WrappedBundle"] {
            // Wrapped and receipt-backed applications have a separate installation owner.
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(relative).path) {
                throw NativeInstallError.invalidPayload("Store and wrapped applications use their own updater.")
            }
        }
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw NativeInstallError.invalidPayload("The application is not a directory.") }
    }

    static func validateTree(_ root: URL) throws {
        var bytes = try extendedAttributeBytes(root)
        var count = 0
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw NativeInstallError.invalidPayload("Cannot inspect the application bundle.")
        }
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumEntries else { throw NativeInstallError.invalidPayload("The payload contains too many files.") }
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw NativeInstallError.invalidPayload("Cannot inspect a payload entry.") }
            bytes += try extendedAttributeBytes(file)
            guard bytes <= maximumExpandedBytes else { throw NativeInstallError.invalidPayload("The bundle metadata exceeds the expanded size limit.") }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                guard !destination.hasPrefix("/"), isContained(file.resolvingSymlinksInPath(), in: root),
                      FileManager.default.fileExists(atPath: file.path) else {
                    throw NativeInstallError.invalidPayload("The payload contains an escaping or broken symbolic link.")
                }
            case S_IFREG:
                guard info.st_size >= 0, info.st_size <= maximumFileBytes, info.st_nlink == 1,
                      (info.st_mode & (S_ISUID | S_ISGID)) == 0 else {
                    throw NativeInstallError.invalidPayload("The payload contains an unsupported file.")
                }
                bytes += info.st_size
                guard bytes <= maximumExpandedBytes else { throw NativeInstallError.invalidPayload("The expanded payload exceeds the size limit.") }
            case S_IFDIR: break
            default: throw NativeInstallError.invalidPayload("The payload contains a special file.")
            }
        }
        if let enumerationError { throw enumerationError }
    }

    static func extendedAttributeBytes(_ url: URL) throws -> Int64 {
        let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard length >= 0, length <= 64 * 1024 else {
            throw NativeInstallError.invalidPayload("Cannot inspect bounded bundle metadata.")
        }
        if length == 0 { return 0 }
        var names = [CChar](repeating: 0, count: length)
        let actual = listxattr(url.path, &names, names.count, XATTR_NOFOLLOW)
        guard actual >= 0, actual <= length else { throw NativeInstallError.invalidPayload("The bundle metadata changed during inspection.") }
        var total: Int64 = 0
        for name in names.prefix(actual).split(separator: 0) {
            let name = String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0, size <= maximumAttributeBytes else {
                throw NativeInstallError.invalidPayload("An extended attribute or resource fork exceeds the supported size.")
            }
            total += Int64(size)
            guard total <= maximumFileBytes else { throw NativeInstallError.invalidPayload("The file metadata exceeds the supported size.") }
        }
        return total
    }

    static func isContained(_ url: URL, in root: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    static func checkVersions(_ request: NativeInstallRequest, installed: Metadata, candidate: Metadata) throws {
        try checkIdentities(request, installed: installed, candidate: candidate)
        try checkNewerRelease(request, installed: installed, candidate: candidate)
    }

    /// Applies only to the inspected download. The replacement transaction still requires a newer exact release.
    static func requiresReplacement(_ request: NativeInstallRequest, installed: Metadata, candidate: Metadata,
                                    signatureCheck: (URL, URL) throws -> Void = checkSignature) throws -> Bool {
        try checkIdentities(request, installed: installed, candidate: candidate)
        try signatureCheck(request.candidateURL, request.targetURL)
        if installed.version == candidate.version, let build = installed.build, !build.isEmpty,
           request.installedBuild == build, candidate.build == build {
            return false
        }
        try checkNewerRelease(request, installed: installed, candidate: candidate)
        return true
    }

    private static func checkIdentities(_ request: NativeInstallRequest, installed: Metadata, candidate: Metadata) throws {
        guard installed.identifier == request.bundleIdentifier, candidate.identifier == request.bundleIdentifier,
              installed.identifier != Bundle.main.bundleIdentifier,
              !installed.identifier.hasPrefix("com.apple."),
              !installed.identifier.hasSuffix("-setapp") else {
            throw NativeInstallError.invalidPayload(String(localized: "The application identity does not match the update."))
        }
        guard installed.version == request.installedVersion,
              request.installedBuild.map({ installed.build == $0 }) ?? true else {
            throw NativeInstallError.invalidPayload(String(localized: "The installed app changed. Check for updates again."))
        }
    }

    private static func checkNewerRelease(_ request: NativeInstallRequest, installed: Metadata, candidate: Metadata) throws {
        guard candidate.version == request.expectedVersion,
              request.expectedBuild.map({ candidate.build == $0 }) ?? true else { throw NativeInstallError.releaseMismatch }
        let order = UpdateVersionComparator.compare(installed: installed.version, available: candidate.version)
        let newerBuild = order == .orderedSame && installed.build.flatMap { local in
            candidate.build.flatMap { UpdateVersionComparator.compare(installed: local, available: $0) }
        } == .orderedAscending
        guard order == .orderedAscending || newerBuild else {
            throw NativeInstallError.invalidPayload("The update must be strictly newer than the installed application.")
        }
    }

    static func checkSignature(_ candidate: URL, installed: URL) throws {
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        func code(_ url: URL) throws -> SecStaticCode {
            var result: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &result) == errSecSuccess, let result else {
                throw NativeInstallError.invalidPayload("Cannot read the application's signature.")
            }
            return result
        }
        var apple: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &apple) == errSecSuccess, let apple else {
            throw NativeInstallError.invalidPayload("Cannot construct the publisher trust requirement.")
        }
        let oldCode = try code(installed)
        guard SecStaticCodeCheckValidity(oldCode, flags, apple) == errSecSuccess else {
            throw NativeInstallError.invalidPayload("The installed app does not have a valid Apple-issued signature.")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(oldCode, [], &requirement) == errSecSuccess, let requirement else {
            throw NativeInstallError.invalidPayload("Cannot read the installed publisher's signing requirement.")
        }
        let newCode = try code(candidate)
        guard SecStaticCodeCheckValidity(newCode, flags, apple) == errSecSuccess,
              SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            throw NativeInstallError.invalidPayload("The update signature is invalid or does not match the installed publisher.")
        }
    }

    static func isRunning(_ app: URL) throws -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw NativeInstallError.invalidPayload("Cannot inspect running applications.") }
        var pids = [pid_t](repeating: 0, count: Int(count) + 1024)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0, actual < pids.count else { throw NativeInstallError.invalidPayload("Cannot obtain a complete process snapshot.") }
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            if length > 0 {
                let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
                if isContained(executable, in: app) { return true }
            }
        }
        return false
    }
}

/// Runs only fixed system utilities; downloaded executables and scripts are never invoked.
enum NativeSystemTool {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120,
                    cancellable: Bool = true, monitor: (() throws -> Void)? = nil) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("native-tool-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw NativeInstallError.invalidPayload("Cannot create a private tool output file.")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": NSHomeDirectory()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                if cancellable { try Task.checkCancellation() }
                guard Date() < deadline else { throw NativeInstallError.invalidPayload("A system update utility timed out.") }
                guard try handle.offset() <= 2 * 1024 * 1024 else { throw NativeInstallError.invalidPayload("A system update utility exceeded its output limit.") }
                try monitor?()
                usleep(20_000)
            }
            process.waitUntilExit()
        } catch {
            process.terminate()
            usleep(50_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw NativeInstallError.invalidPayload("The system utility \(URL(fileURLWithPath: executable).lastPathComponent) could not verify or process this update.")
        }
        return try Data(contentsOf: output)
    }
}
