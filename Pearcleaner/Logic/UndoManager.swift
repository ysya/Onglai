//
//  UndoManager.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 2/24/25.
//

import Foundation
import SwiftUI
import AlinFoundation
import Darwin

enum FileSystemItemStatus {
    case present, missing, unreadable
}

func fileSystemItemStatus(at url: URL) -> FileSystemItemStatus {
    var info = stat()
    if lstat(url.path, &info) == 0 { return .present }
    return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
}

/// Retain unknown paths for authorization; only proven absence is safe to skip.
func fileSystemItemMayExist(at url: URL) -> Bool {
    fileSystemItemStatus(at: url) != .missing
}

struct TrashResult {
    let moved: Set<URL>
    let failed: Set<URL>

    var succeeded: Bool { !moved.isEmpty && failed.isEmpty }

    static func confirmed(
        requested: [URL], filePairs: [(trashURL: URL, originalURL: URL)]
    ) -> TrashResult {
        let moved = Set(filePairs.compactMap { pair in
            fileSystemItemStatus(at: pair.originalURL) == .missing
                && fileSystemItemStatus(at: pair.trashURL) == .present ? pair.originalURL : nil
        })
        return TrashResult(moved: moved, failed: Set(requested).subtracting(moved))
    }
}

class FileManagerUndo {
    // MARK: - Singleton Instance
    static let shared = FileManagerUndo()

    // Private initializer to enforce singleton pattern
    private init() {}

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // NSUndoManager instance to handle undo/redo actions
    let undoManager = UndoManager()

    // MARK: - Path Validation
    /// Validates that a path is safe to delete (not a critical system path or app folder)
    private func validatePath(_ path: String) -> Bool {
        // Normalize path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        // Block empty paths
        guard !normalizedPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            printOS("⚠️ Blocked deletion: Empty path")
            return false
        }

        // Combine critical system paths + user app folder paths into single set
        let criticalSystemPaths = [
            "/",
            "/Applications",
            "/Library",
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
            "/private",
            "/opt",
            NSHomeDirectory()
        ]

        let userAppPaths = FolderSettingsManager.shared.folderPaths
        let blockedPaths = Set(criticalSystemPaths + userAppPaths)

        // Block if path exactly matches any blocked path
        if blockedPaths.contains(normalizedPath) {
            printOS("⚠️ Blocked deletion: Protected path '\(normalizedPath)'")
            return false
        }

        return true
    }

    func deleteFiles(at urls: [URL], isCLI: Bool = false, bundleName: String? = nil) -> Bool {
        guard !urls.isEmpty else { return false }
        // Legacy callers retry a whole batch. Previously moved sources are
        // already absent and must not make every subsequent attempt fail.
        let remaining = urls.filter { fileSystemItemMayExist(at: $0) }
        guard !remaining.isEmpty else { return true }
        return deleteFilesWithResult(at: remaining, isCLI: isCLI, bundleName: bundleName).succeeded
    }

    static func uninstallMoveOrder(
        _ eligible: [URL], requestedCount: Int, appBundle: URL
    ) -> (urls: [URL], stopOnFailure: Bool) {
        let bundlePath = appBundle.standardizedFileURL.path
        let data = eligible.filter { $0.standardizedFileURL.path != bundlePath }
        guard data.count + 1 == requestedCount,
              let bundle = eligible.first(where: { $0.standardizedFileURL.path == bundlePath }) else {
            return (data, false)
        }
        return (data + [bundle], true)
    }

    func deleteFilesWithResult(
        at urls: [URL], isCLI: Bool = false, bundleName: String? = nil, appBundleToMoveLast: URL? = nil
    ) -> TrashResult {
        // Filter out invalid/dangerous paths before deletion
        var validURLs = urls.filter { validatePath($0.path) }
        var separator = " ; "
        if let appBundleToMoveLast {
            let order = Self.uninstallMoveOrder(
                filterValidFiles(fileURLs: validURLs), requestedCount: urls.count, appBundle: appBundleToMoveLast
            )
            validURLs = order.urls
            if order.stopOnFailure { separator = " && " }
        }

        // If no valid paths remain, return early
        guard !validURLs.isEmpty else {
            printOS("⚠️ All paths were blocked - no files deleted")
            return TrashResult(moved: [], failed: Set(urls))
        }

        // Log if any paths were filtered out
        if validURLs.count < urls.count {
            printOS("⚠️ Filtered out \(urls.count - validURLs.count) dangerous path(s)")
        }
        let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")

        var tempFilePairs: [(trashURL: URL, originalURL: URL)] = []
        var seenFileNames: [String: Int] = [:]

        // Moving an item requires write access to its parent directory, not to
        // the item itself. Use that as the privilege boundary so ordinary
        // files go straight to Trash without an unnecessary password prompt.
        let requiresPrivileges = validURLs.contains {
            !$0.deletingLastPathComponent().isWritable
        }

        // Create bundle folder name with app name and timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())

        let folderName: String
        if let customBundleName = bundleName {
            folderName = customBundleName
        } else if !AppState.shared.appInfo.appName.isEmpty {
            folderName = AppState.shared.appInfo.appName
        } else {
            // Fallback for plugins: use the first file's name or "Mixed Files"
            if let firstFile = validURLs.first {
                folderName = firstFile.deletingPathExtension().lastPathComponent
            } else {
                folderName = "Mixed Files"
            }
        }

        let bundleFolderName = "\(folderName)_\(timestamp)"
        let bundleFolderPath = (trashPath as NSString).appendingPathComponent(bundleFolderName)
        let bundleFolderURL = URL(fileURLWithPath: bundleFolderPath)

        // Create the bundle folder first
        let createFolderCommand = "/bin/mkdir -p \(shellQuoted(bundleFolderPath))"

        let mvCommands = validURLs.map { file -> String in
            let baseName = file.lastPathComponent
            var count = seenFileNames[baseName] ?? 0
            var finalName = baseName

            // Check for duplicate names within the bundle folder
            repeat {
                if count > 0 {
                    finalName = "\(baseName)-\(count)"
                }
                count += 1
            } while FileManager.default.fileExists(atPath: (bundleFolderPath as NSString).appendingPathComponent(finalName))

            seenFileNames[baseName] = count

            let destinationURL = bundleFolderURL.appendingPathComponent(finalName)
            tempFilePairs.append((trashURL: destinationURL, originalURL: file))

            let source = shellQuoted(file.path)
            let destination = shellQuoted(destinationURL.path)
            return "/bin/mv \(source) \(destination)"
        }.joined(separator: separator)

        // Combine folder creation and file moves
        let finalCommands = "\(createFolderCommand)\(separator)\(mvCommands)"
        _ = executeFileCommands(finalCommands, requiresPrivileges: requiresPrivileges)
        let result = TrashResult.confirmed(requested: urls, filePairs: tempFilePairs)
        let filePairs = tempFilePairs.filter { result.moved.contains($0.originalURL) }

        if !filePairs.isEmpty {
            updateOnMain { [self] in
                undoManager.registerUndo(withTarget: self) { target in
                    let result = target.restoreFiles(filePairs: filePairs)
                    if !result {
                        printOS("Trash Error: Could not restore files.")
                    }
                }
                undoManager.setActionName("Delete File")
            }

            // Record in persistent history
            Task { @MainActor in
                UndoHistoryManager.shared.addRecord(
                    appName: folderName,
                    bundleFolderPath: bundleFolderPath,
                    filePairs: filePairs.map { ($0.originalURL.path, $0.trashURL.path) }
                )
            }

            // Play trash sound after successful deletion
            if !isCLI {
                playTrashSound()
            }

        }
        updateOnMain { AppState.shared.trashError = !result.failed.isEmpty }
        return result
    }

    func restoreFiles(filePairs: [(trashURL: URL, originalURL: URL)], isCLI: Bool = false) -> Bool {
        let dispatchSemaphore = DispatchSemaphore(value: 0)
        var finalStatus = true

        let requiresPrivileges = filePairs.contains {
            !$0.originalURL.deletingLastPathComponent().isWritable
        }

        let commands = filePairs.map {
            let source = shellQuoted($0.trashURL.path)
            let destination = shellQuoted($0.originalURL.path)
            return "/bin/mv \(source) \(destination)"
        }.joined(separator: " ; ")

        // Determine the bundle folder to clean up after restore
        var bundleFolderToRemove: String? = nil
        if let firstFilePair = filePairs.first {
            let bundleFolder = firstFilePair.trashURL.deletingLastPathComponent()
            // Only remove if it looks like our generated bundle folder (contains underscore for timestamp)
            if bundleFolder.lastPathComponent.contains("_") {
                bundleFolderToRemove = bundleFolder.path
            }
        }

        // Add bundle folder cleanup command if we have one to remove
        let finalCommands = if let bundleFolder = bundleFolderToRemove {
            "\(commands) ; /bin/rmdir \(shellQuoted(bundleFolder))"
        } else {
            commands
        }

        if executeFileCommands(finalCommands, requiresPrivileges: requiresPrivileges, isRestore: true) {
            // Remove from persistent history after successful restore
            if let bundleFolder = bundleFolderToRemove {
                Task { @MainActor in
                    UndoHistoryManager.shared.removeRecord(bundleFolderPath: bundleFolder)
                }
            }

            finalStatus = true
        } else {
            //            printOS("Trash Error: \(isCLI ? "Failed to run restore CLI commands" : "Failed to run restore privileged commands")")
            updateOnMain {
                AppState.shared.trashError = true
            }
            finalStatus = false
        }

        dispatchSemaphore.signal()
        dispatchSemaphore.wait()
        return finalStatus
    }

    // Helper function to perform shell commands based on available privileges
    private func executeFileCommands(_ commands: String, requiresPrivileges: Bool, isRestore: Bool = false) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var status = false

        // Most deletions operate entirely inside user-writable directories.
        // Run those directly so they never trigger an administrator prompt.
        if !requiresPrivileges {
            let directResult = runDirectShellCommand(command: commands)
            if directResult.0 {
                return true
            }
            printOS(isRestore ? "Restore Error: \(directResult.1)" : "Trash Error: \(directResult.1)")
            updateOnMain {
                AppState.shared.trashError = true
            }
            return false
        }

        // Protected paths get exactly one authorization attempt. If the user
        // cancels, return failure; never fall back and execute the deletion.
        Task {
            do {
                let result = try await runSUCommand(
                    commands,
                    errorContext: isRestore ? "Undo restore operation failed" : "Undo delete operation failed",
                    throwOnFailure: false
                )
                status = result.0

                if !status {
                    printOS(isRestore ? "Restore Error: \(result.1)" : "Trash Error: \(result.1)")
                    updateOnMain {
                        AppState.shared.trashError = true
                    }
                }
            } catch {
                printOS(isRestore ? "Restore Error: \(error.localizedDescription)" : "Trash Error: \(error.localizedDescription)")
                updateOnMain {
                    AppState.shared.trashError = true
                }
                status = false
            }

            semaphore.signal()
        }
        semaphore.wait()

        return status
    }

    // Helper to run direct non-privileged shell commands
    private func runDirectShellCommand(command: String) -> (Bool, String) {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        task.launch()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if output.lowercased().contains("permission denied") {
            return (false, output)
        }

        return (task.terminationStatus == 0, output)
    }

}

extension URL {
    var isWritable: Bool {
        FileManager.default.isWritableFile(atPath: self.path)
    }

    var isProtected: Bool {
        !isWritable
    }
}
