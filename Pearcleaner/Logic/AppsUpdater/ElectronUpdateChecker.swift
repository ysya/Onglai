//
//  ElectronUpdateChecker.swift
//  Pearcleaner
//

import Foundation

enum ElectronUpdateChecker {
    private static let logger = UpdaterDebugLogger.shared
    private static let metadataRelativePath = "Contents/Resources/app-update.yml"
    private static let maximumMetadataSize = 256 * 1024
    private static let maximumRemoteDocumentSize = 1024 * 1024

    static func hasUpdateMetadata(for app: AppInfo) -> Bool {
        FileManager.default.fileExists(atPath: metadataURL(for: app).path)
    }

    static func isEligible(_ app: AppInfo) -> Bool {
        !app.webApp &&
        !app.isAppStore &&
        app.cask == nil &&
        !app.hasSparkle &&
        hasUpdateMetadata(for: app) &&
        configuration(for: app)?.isCheckable == true
    }

    static func configuration(for app: AppInfo) -> ElectronUpdateConfiguration? {
        let url = metadataURL(for: app)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= maximumMetadataSize,
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return try? ElectronUpdateMetadataParser.parseConfiguration(source)
    }

    static func checkForUpdates(apps: [AppInfo]) async -> UpdateCheckResults {
        let electronApps = apps.filter(isEligible)
        guard !electronApps.isEmpty else { return UpdateCheckResults() }

        logger.log(.electron, "Starting Electron update check for \(electronApps.count) apps")
        await GlobalConsoleManager.shared.appendOutput(
            "Checking for Electron updates (\(electronApps.count) apps)...\n",
            source: CurrentPage.updater.title
        )

        var combined = UpdateCheckResults()
        let chunks = createOptimalChunks(from: electronApps, minChunkSize: 3, maxChunkSize: 10)

        for chunk in chunks {
            guard !Task.isCancelled else { break }
            let chunkResult = await withTaskGroup(of: ElectronSingleAppCheckResult.self) { group in
                for app in chunk {
                    group.addTask { await checkSingleApp(app) }
                }

                var result = UpdateCheckResults()
                for await item in group {
                    switch item {
                    case .update(let app): result.updates.append(app)
                    case .current(let path): result.currentAppPaths.insert(path)
                    case .failed(let failure): result.failures.append(failure)
                    }
                }
                return result
            }
            combined.merge(chunkResult)
        }

        logger.log(.electron, "Found \(combined.updates.count) Electron updates")
        await GlobalConsoleManager.shared.appendOutput(
            "Found \(combined.updates.count) Electron update(s)\n",
            source: CurrentPage.updater.title
        )
        return combined
    }

    private static func checkSingleApp(_ app: AppInfo) async -> ElectronSingleAppCheckResult {
        guard let configuration = configuration(for: app) else {
            return .failed(failure(for: app, message: String(localized: "Electron update metadata could not be read")))
        }

        do {
            let metadata: ElectronReleaseMetadata
            switch configuration.provider {
            case .generic, .s3:
                guard let manifestURL = configuration.manifestURL else {
                    throw ElectronCheckerError.invalidManifestURL
                }
                logger.log(.electron, "Checking \(app.appName): \(manifestURL.absoluteString)")
                let manifest = try await fetchText(from: manifestURL)
                metadata = try ElectronUpdateMetadataParser.parseManifest(
                    manifest,
                    baseURL: manifestURL.deletingLastPathComponent()
                )

            case .github(let owner, let repository):
                metadata = try await fetchGitHubRelease(
                    owner: owner,
                    repository: repository,
                    configuration: configuration
                )

            case .unsupported(let name):
                throw ElectronCheckerError.unsupportedProvider(name)
            }

            let installed = Version(versionNumber: app.appVersion, buildNumber: nil)
            let available = Version(versionNumber: metadata.version, buildNumber: nil)
            guard !installed.isEmpty, !available.isEmpty else {
                throw ElectronCheckerError.invalidVersion
            }

            guard available > installed else {
                logger.log(.electron, "Current: \(app.appName) \(app.appVersion)")
                return .current(app.path)
            }

            let externalURL = metadata.releasePageURL ?? metadata.downloadURL ?? configuration.fallbackExternalURL
            logger.log(.electron, "Update found: \(app.appName) \(app.appVersion) → \(metadata.version)")
            return .update(UpdateableApp(
                appInfo: app,
                availableVersion: metadata.version,
                availableBuildNumber: nil,
                source: .electron,
                adamID: nil,
                appStoreURL: nil,
                externalURL: externalURL?.absoluteString,
                status: .idle,
                progress: 0,
                isSelectedForUpdate: false,
                releaseTitle: nil,
                releaseDescription: metadata.releaseNotes,
                releaseNotesLink: metadata.releasePageURL?.absoluteString,
                releaseDate: metadata.releaseDate,
                isPreRelease: isPreReleaseVersion(metadata.version),
                isIOSApp: false,
                foundInRegion: nil,
                appcastItem: nil
            ))
        } catch {
            logger.log(.electron, "Failed: \(app.appName): \(error.localizedDescription)")
            return .failed(failure(for: app, message: error.localizedDescription))
        }
    }

    private static func fetchGitHubRelease(
        owner: String,
        repository: String,
        configuration: ElectronUpdateConfiguration
    ) async throws -> ElectronReleaseMetadata {
        guard let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            throw ElectronCheckerError.invalidManifestURL
        }

        let document = try await fetchText(from: endpoint, accept: "application/vnd.github+json")
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(document.utf8))
        let preferredNames = [configuration.manifestName, "latest-mac.yml"]
        guard let asset = preferredNames.compactMap({ name in
            release.assets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }).first,
              let manifestURL = URL(string: asset.browserDownloadURL),
              let releasePageURL = URL(string: release.htmlURL) else {
            throw ElectronCheckerError.missingGitHubManifest
        }

        let manifest = try await fetchText(from: manifestURL)
        return try ElectronUpdateMetadataParser.parseManifest(
            manifest,
            baseURL: manifestURL.deletingLastPathComponent(),
            releasePageURL: releasePageURL
        )
    }

    private static func fetchText(from url: URL, accept: String? = nil) async throws -> String {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw ElectronCheckerError.invalidManifestURL
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(accept ?? "text/yaml, text/plain, application/octet-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw ElectronCheckerError.requestFailed
        }
        guard response.expectedContentLength <= Int64(maximumRemoteDocumentSize) else {
            throw ElectronCheckerError.documentTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), maximumRemoteDocumentSize))
        for try await byte in bytes {
            guard data.count < maximumRemoteDocumentSize else {
                throw ElectronCheckerError.documentTooLarge
            }
            data.append(byte)
        }

        guard let source = String(data: data, encoding: .utf8) else {
            throw ElectronCheckerError.invalidEncoding
        }
        return source
    }

    private static func metadataURL(for app: AppInfo) -> URL {
        app.path.appendingPathComponent(metadataRelativePath)
    }

    private static func failure(for app: AppInfo, message: String) -> UpdateCheckFailure {
        UpdateCheckFailure(appPath: app.path, appName: app.appName, message: message)
    }
}

private enum ElectronSingleAppCheckResult: @unchecked Sendable {
    case update(UpdateableApp)
    case current(URL)
    case failed(UpdateCheckFailure)
}

private enum ElectronCheckerError: LocalizedError {
    case invalidManifestURL
    case requestFailed
    case documentTooLarge
    case invalidEncoding
    case invalidVersion
    case unsupportedProvider(String)
    case missingGitHubManifest

    var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            return String(localized: "The Electron update URL is invalid")
        case .requestFailed:
            return String(localized: "The Electron update service returned an error")
        case .documentTooLarge:
            return String(localized: "The Electron update document is too large")
        case .invalidEncoding:
            return String(localized: "The Electron update document is not valid UTF-8")
        case .invalidVersion:
            return String(localized: "The Electron update service returned an invalid version")
        case .unsupportedProvider(let provider):
            return String(localized: "Electron provider \(provider) must be checked inside the app")
        case .missingGitHubManifest:
            return String(localized: "The latest GitHub release has no macOS update manifest")
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let htmlURL: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
        case assets
    }
}
