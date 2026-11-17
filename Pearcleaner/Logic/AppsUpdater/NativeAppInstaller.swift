import Foundation
import Darwin

struct NativeInstallTarget: Sendable {
    let url: URL
    let bundleIdentifier: String
    let version: String
    let build: String?
}

struct NativeInstallRequest: Codable, Sendable {
    let targetURL: URL
    let candidateURL: URL
    let bundleIdentifier: String
    let installedVersion: String
    let installedBuild: String?
    let expectedVersion: String
    let expectedBuild: String?

    init(targetURL: URL, candidateURL: URL, bundleIdentifier: String, installedVersion: String,
         installedBuild: String?, expectedVersion: String, expectedBuild: String?) {
        self.targetURL = targetURL
        self.candidateURL = candidateURL
        self.bundleIdentifier = bundleIdentifier
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        self.expectedVersion = expectedVersion
        self.expectedBuild = expectedBuild
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        targetURL = try values.decode(URL.self, forKey: .targetURL)
        candidateURL = try values.decode(URL.self, forKey: .candidateURL)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        installedVersion = try values.decode(String.self, forKey: .installedVersion)
        installedBuild = try values.decodeIfPresent(String.self, forKey: .installedBuild)
        expectedVersion = try values.decode(String.self, forKey: .expectedVersion)
        expectedBuild = try values.decodeIfPresent(String.self, forKey: .expectedBuild)
        try validateURLs()
    }

    func validateURLs() throws {
        try Self.validateFileURL(targetURL)
        try Self.validateFileURL(candidateURL)
    }

    static func validateFileURL(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              url.isFileURL, url.scheme == "file", (url.host ?? "").isEmpty,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, decodedPath.hasPrefix("/"),
              !decodedPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeInstallError.invalidPayload("The installation request contains an invalid local file URL.")
        }
    }
}

struct NativeInstallResult: Codable, Sendable {
    let recoveryURL: URL?
    init(recoveryURL: URL? = nil) { self.recoveryURL = recoveryURL }
}

struct NativeInstallProgress: Sendable {
    enum Phase: Sendable { case downloading, extracting, verifying, installing }
    let phase: Phase
    let fraction: Double
}

enum NativeInstallError: Error, LocalizedError {
    case cancelled
    case appRunning
    case authorizationRequired
    case recoveryRequired(URL)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The update was cancelled."
        case .appRunning: return "Quit the app before installing its update."
        case .authorizationRequired: return "This app cannot be replaced with your current permissions. Open it or use the publisher's installer."
        case .recoveryRequired(let url): return "The update could not be restored automatically. The previous app is preserved at \(url.path)."
        case .invalidPayload(let reason): return reason
        }
    }
}

struct NativeAppInstaller: Sendable {
    func install(target: NativeInstallTarget, artifact: NativeUpdateArtifact,
                 progress: @escaping @Sendable (NativeInstallProgress) -> Void) async throws -> NativeInstallResult {
        guard geteuid() != 0 else {
            throw NativeInstallError.invalidPayload("Privileged native installation is not supported. Use the vendor updater.")
        }
        try NativeInstallRequest.validateFileURL(target.url)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "native-updater")-update-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var preserveWorkspace = false
        defer { if !preserveWorkspace { try? FileManager.default.removeItem(at: workspace) } }
        do {
            try Task.checkCancellation()
            let archive = workspace.appendingPathComponent("payload.\(artifact.format.rawValue)")
            progress(NativeInstallProgress(phase: .downloading, fraction: 0))
            let download = NativeArtifactDownload(destination: archive) { fraction in
                progress(NativeInstallProgress(phase: .downloading, fraction: fraction))
            }
            try await withTaskCancellationHandler(operation: { try await download.fetch(artifact.url) }, onCancel: { download.cancel() })
            try NativeArtifactDownload.verifyDigest(artifact.digest, at: archive)
            try NativeArtifactDownload.quarantine(archive)
            progress(NativeInstallProgress(phase: .extracting, fraction: 0))
            let candidate = try NativeArchiveExtractor.extract(archive, format: artifact.format, in: workspace)
            try NativeArtifactDownload.quarantine(candidate)
            progress(NativeInstallProgress(phase: .verifying, fraction: 0))
            let request = NativeInstallRequest(targetURL: target.url, candidateURL: candidate,
                bundleIdentifier: target.bundleIdentifier, installedVersion: target.version, installedBuild: target.build,
                expectedVersion: artifact.version, expectedBuild: artifact.build)
            try NativeAppValidation.validateTree(candidate)
            try NativeAppValidation.checkVersions(request, installed: NativeAppValidation.metadata(request.targetURL), candidate: NativeAppValidation.metadata(candidate))
            try NativeAppValidation.checkSignature(candidate, installed: request.targetURL)
            try Task.checkCancellation()
            progress(NativeInstallProgress(phase: .installing, fraction: 0))
            let result = try NativeAppInstallTransaction().install(request)
            progress(NativeInstallProgress(phase: .installing, fraction: 1))
            return result
        } catch NativeInstallError.recoveryRequired(let url) {
            if NativeAppValidation.isContained(url, in: workspace) { preserveWorkspace = true }
            throw NativeInstallError.recoveryRequired(url)
        } catch is CancellationError { throw NativeInstallError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw NativeInstallError.cancelled }
    }
}
