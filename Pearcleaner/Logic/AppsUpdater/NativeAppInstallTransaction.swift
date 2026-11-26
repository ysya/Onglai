import Foundation
import Darwin

struct NativeAppInstallTransaction {
    var signatureCheck: (URL, URL) throws -> Void = NativeAppValidation.checkSignature
    var runningCheck: (URL) throws -> Bool = NativeAppValidation.isRunning
    var swap: (Int32, String, Int32, String) throws -> Void = { fromFD, from, toFD, to in
        guard renameatx_np(fromFD, from, toFD, to, UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    func install(_ request: NativeInstallRequest) throws -> NativeInstallResult {
        try request.validateURLs()
        guard geteuid() != 0 else {
            throw NativeInstallError.invalidPayload("Privileged native installation is not supported. Use the vendor updater.")
        }
        let manager = FileManager.default
        let target = request.targetURL.standardizedFileURL
        let candidate = request.candidateURL.standardizedFileURL
        guard target != candidate, !NativeAppValidation.isContained(candidate, in: target),
              !NativeAppValidation.isContained(target, in: candidate) else {
            throw NativeInstallError.invalidPayload("The source and destination overlap.")
        }
        try Task.checkCancellation()
        try NativeAppValidation.validateTree(target)
        try NativeAppValidation.validateTree(candidate)
        let original = try NativeAppValidation.metadata(target)
        let proposed = try NativeAppValidation.metadata(candidate)
        try NativeAppValidation.checkVersions(request, installed: original, candidate: proposed)
        try signatureCheck(candidate, target)
        if try runningCheck(target) { throw NativeInstallError.appRunning }

        let parent = target.deletingLastPathComponent()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw permissionError(errno) }
        defer { close(parentFD) }
        let parentBefore = try directoryIdentity(parentFD)
        let before = try snapshot(target)
        let stage = parent.appendingPathComponent(".native-update-\(UUID().uuidString)", isDirectory: true)
        guard mkdirat(parentFD, stage.lastPathComponent, 0o700) == 0 else { throw permissionError(errno) }
        var preserveStage = false
        defer { if !preserveStage { try? manager.removeItem(at: stage) } }
        let stageFD = openat(parentFD, stage.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw permissionError(errno) }
        defer { close(stageFD) }
        let staged = stage.appendingPathComponent(target.lastPathComponent)
        do {
            try NativeBundleCopy.copy(candidate, to: staged)
            try NativeAppValidation.validateTree(staged)
            let copied = try NativeAppValidation.metadata(staged)
            try NativeAppValidation.checkVersions(request, installed: original, candidate: copied)
            try signatureCheck(staged, target)
            try Task.checkCancellation()
            guard try snapshot(parent).identity == parentBefore, try snapshot(target) == before else {
                throw NativeInstallError.invalidPayload("The installed application changed while preparing the update.")
            }
            let current = try NativeAppValidation.metadata(target)
            try NativeAppValidation.checkVersions(request, installed: current, candidate: copied)
            try signatureCheck(staged, target)
            // Check executable paths, including background helpers, immediately before committing.
            if try runningCheck(target) { throw NativeInstallError.appRunning }
            try Task.checkCancellation()
            try swap(stageFD, staged.lastPathComponent, parentFD, target.lastPathComponent)
        } catch {
            if isPermissionError(error) { throw NativeInstallError.authorizationRequired }
            throw error
        }

        // Past this point authorizationRequired must never escape: the target has changed.
        do {
            try NativeAppValidation.validateTree(target)
            let installed = try NativeAppValidation.metadata(target)
            try NativeAppValidation.checkVersions(request, installed: original, candidate: installed)
            try signatureCheck(target, staged)
        } catch {
            var rolledBack = false
            do {
                try swap(stageFD, staged.lastPathComponent, parentFD, target.lastPathComponent)
                rolledBack = true
                guard try snapshot(target) == before else {
                    throw NativeInstallError.invalidPayload("Rollback did not restore the original application.")
                }
                try signatureCheck(target, target)
            } catch {
                preserveStage = true
                throw NativeInstallError.recoveryRequired(rolledBack ? target : staged)
            }
            throw NativeInstallError.invalidPayload("The installed update failed verification; the previous application was restored.")
        }
        do {
            try remove(stage)
            return .installed()
        } catch {
            preserveStage = true
            return .installed(recoveryURL: staged)
        }
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Snapshot: Equatable {
        let identity: DirectoryIdentity
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private func directoryIdentity(_ descriptor: Int32) throws -> DirectoryIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeInstallError.invalidPayload("The application location changed or is no longer a directory.")
        }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func snapshot(_ url: URL) throws -> Snapshot {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeInstallError.invalidPayload("The application location changed or is no longer a directory.")
        }
        // Target mtime detects entry changes; signatures recheck sealed contents.
        // Parent identity is compared separately because unrelated apps share its directory.
        return Snapshot(identity: DirectoryIdentity(device: info.st_dev, inode: info.st_ino),
                        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }

    private func permissionError(_ code: Int32) -> Error {
        if code == EACCES || code == EPERM { return NativeInstallError.authorizationRequired }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(EACCES) || error.code == Int(EPERM) }
        if error.domain == NSCocoaErrorDomain { return error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }
}
