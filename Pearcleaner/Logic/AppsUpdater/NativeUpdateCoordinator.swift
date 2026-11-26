import AppKit
import Foundation

struct NativeUpdateCoordinator: @unchecked Sendable {
    typealias Progress = @Sendable (NativeInstallProgress) -> Void
    typealias Installer = @Sendable (NativeInstallTarget, NativeUpdateArtifact, @escaping Progress,
                                     @escaping NativeAppInstaller.PrepareReplacement) async throws -> NativeInstallResult

    private let isRunning: @MainActor (NativeInstallTarget) -> Bool
    private let confirmQuit: @MainActor (NativeInstallTarget) -> Bool
    private let terminate: @MainActor (NativeInstallTarget) -> Void
    private let installer: Installer

    init(isRunning: @escaping @MainActor (NativeInstallTarget) -> Bool = NativeUpdateCoordinator.running,
         confirmQuit: @escaping @MainActor (NativeInstallTarget) -> Bool = NativeUpdateCoordinator.askToQuit,
         terminate: @escaping @MainActor (NativeInstallTarget) -> Void = NativeUpdateCoordinator.requestTermination,
         install: @escaping Installer = { target, artifact, progress, prepareReplacement in
             try await NativeAppInstaller().install(target: target, artifact: artifact, progress: progress,
                                                    prepareReplacement: prepareReplacement)
         }) {
        self.isRunning = isRunning
        self.confirmQuit = confirmQuit
        self.terminate = terminate
        self.installer = install
    }

    func install(target: NativeInstallTarget, artifact: NativeUpdateArtifact,
                 progress: @escaping Progress) async throws -> NativeInstallResult {
        try Task.checkCancellation()
        return try await installer(target, artifact, progress) {
            try await prepareReplacement(for: target)
        }
    }

    private func prepareReplacement(for target: NativeInstallTarget) async throws {
        try Task.checkCancellation()
        if await isRunning(target) {
            guard await confirmQuit(target) else { throw CancellationError() }
            try Task.checkCancellation()
            await terminate(target)
            // The app may display its own Save/Cancel dialog. Never force quit it.
            for _ in 0..<150 {
                if !(await isRunning(target)) { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        try Task.checkCancellation()
        guard !(await isRunning(target)) else { throw CoordinatorError.appStillRunning }
    }

    @MainActor private static func applications(_ target: NativeInstallTarget) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            Self.matchesRunningApplication(bundleURL: $0.bundleURL, executableURL: $0.executableURL, targetURL: target.url)
        }
    }
    static func matchesRunningApplication(bundleURL: URL?, executableURL: URL?, targetURL: URL) -> Bool {
        let target = targetURL.resolvingSymlinksInPath().standardizedFileURL
        if let bundleURL { return bundleURL.resolvingSymlinksInPath().standardizedFileURL == target }
        guard let executableURL else { return false }
        return executableURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(target.path + "/")
    }
    @MainActor private static func running(_ target: NativeInstallTarget) -> Bool { !applications(target).isEmpty }
    @MainActor private static func requestTermination(_ target: NativeInstallTarget) {
        for application in applications(target) { application.terminate() }
    }
    @MainActor private static func askToQuit(_ target: NativeInstallTarget) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit App to Update?")
        alert.informativeText = String(format: String(localized: "%@ must quit before installing the update. Save your work first. You can cancel in the app's save dialog."), target.url.deletingPathExtension().lastPathComponent)
        alert.addButton(withTitle: String(localized: "Quit and Update"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private enum CoordinatorError: LocalizedError {
        case appStillRunning
        var errorDescription: String? { String(localized: "The app is still running. Quit it and try again.") }
    }
}
