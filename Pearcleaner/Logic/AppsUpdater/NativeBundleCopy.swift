import Foundation
import Darwin

/// Bundle-aware system copying with write-level cancellation and an aggregate byte budget.
/// No clone flag: clones skip progress callbacks and would bypass the copy-time budget.
enum NativeBundleCopy {
    private final class Budget {
        var entries = 0
        var bytes: Int64 = 0
        var progressByFile: [String: Int64] = [:]
        var copiedAttributes = Set<String>()
        var error: Error?
    }

    static func copy(_ source: URL, to destination: URL) throws {
        try NativeAppValidation.validateTree(source)
        guard let state = copyfile_state_alloc() else { throw NativeInstallError.invalidPayload("Cannot allocate the bundle copy state.") }
        defer { copyfile_state_free(state) }
        let budget = Budget()
        let context = Unmanaged.passUnretained(budget).toOpaque()
        let callback: copyfile_callback_t = { what, stage, state, source, _, context in
            guard let context else { return COPYFILE_QUIT }
            let budget = Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue()
            if Task.isCancelled { budget.error = CancellationError(); return COPYFILE_QUIT }
            if stage == COPYFILE_ERR || what == COPYFILE_RECURSE_ERROR {
                budget.error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                return COPYFILE_QUIT
            }
            if stage == COPYFILE_START, what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR {
                budget.entries += 1
                guard budget.entries <= NativeAppValidation.maximumEntries, let source else {
                    budget.error = NativeInstallError.invalidPayload("The bundle copy exceeds its file count limit.")
                    return COPYFILE_QUIT
                }
                var info = stat()
                guard lstat(source, &info) == 0,
                      [S_IFREG, S_IFDIR, S_IFLNK].contains(info.st_mode & S_IFMT),
                      info.st_size <= NativeAppValidation.maximumFileBytes else {
                    budget.error = NativeInstallError.invalidPayload("A source file changed or exceeds the copy size limit.")
                    return COPYFILE_QUIT
                }
            }
            if what == COPYFILE_COPY_XATTR, let source {
                var name: UnsafePointer<CChar>?
                guard copyfile_state_get(state, UInt32(COPYFILE_STATE_XATTRNAME), &name) == 0, let name else {
                    budget.error = NativeInstallError.invalidPayload("Cannot inspect a source extended attribute.")
                    return COPYFILE_QUIT
                }
                let size = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0, size <= NativeAppValidation.maximumAttributeBytes else {
                    budget.error = NativeInstallError.invalidPayload("A source extended attribute exceeds the copy limit.")
                    return COPYFILE_QUIT
                }
                let key = String(cString: source) + "\0" + String(cString: name)
                if budget.copiedAttributes.insert(key).inserted { budget.bytes += Int64(size) }
                guard budget.bytes <= NativeAppValidation.maximumExpandedBytes else {
                    budget.error = NativeInstallError.invalidPayload("The bundle metadata exceeds the copy limit.")
                    return COPYFILE_QUIT
                }
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let source {
                var copied: off_t = 0
                guard copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 else { return COPYFILE_QUIT }
                let path = String(cString: source)
                let previous = budget.progressByFile[path] ?? 0
                budget.bytes += max(0, copied - previous)
                budget.progressByFile[path] = copied
                guard copied <= NativeAppValidation.maximumFileBytes,
                      budget.bytes <= NativeAppValidation.maximumExpandedBytes else {
                    budget.error = NativeInstallError.invalidPayload("The bundle copy exceeds its expanded size limit.")
                    return COPYFILE_QUIT
                }
            }
            return COPYFILE_CONTINUE
        }
        let function = unsafeBitCast(callback, to: UnsafeRawPointer.self)
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), function) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context) == 0 else {
            throw NativeInstallError.invalidPayload("Cannot configure the bounded bundle copy.")
        }
        var bufferSize: UInt32 = 1024 * 1024
        var noCrossMount = true
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT), &noCrossMount) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_DST_BSIZE), &bufferSize) == 0 else {
            throw NativeInstallError.invalidPayload("Cannot configure the bundle copy limits.")
        }
        // ACLs from untrusted archives are not propagated into the installed app.
        let flags = copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST | COPYFILE_EXCL)
        guard copyfile(source.path, destination.path, state, flags) == 0 else {
            throw budget.error ?? NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try NativeAppValidation.validateTree(destination)
    }

}
