//
//  ElectronUpdateMetadata.swift
//  Pearcleaner
//

import Foundation

struct ElectronUpdateConfiguration: Equatable {
    enum Provider: Equatable {
        case generic(baseURL: URL)
        case github(owner: String, repository: String)
        case s3(baseURL: URL)
        case spaces(baseURL: URL)
        case unsupported(name: String)
    }

    let provider: Provider
    let channel: String

    var manifestName: String {
        "\(channel)-mac.yml"
    }

    var manifestURL: URL? {
        switch provider {
        case .generic(let baseURL), .s3(let baseURL), .spaces(let baseURL):
            return baseURL.appendingPathComponent(manifestName)
        case .github, .unsupported:
            return nil
        }
    }

    var fallbackExternalURL: URL? {
        switch provider {
        case .generic(let baseURL), .s3(let baseURL), .spaces(let baseURL):
            return baseURL
        case .github(let owner, let repository):
            return URL(string: "https://github.com/\(owner)/\(repository)/releases")
        case .unsupported:
            return nil
        }
    }

    var isCheckable: Bool {
        if case .unsupported = provider { return false }
        return true
    }
}

struct ElectronReleaseMetadata: Equatable {
    let version: String
    let releaseDate: String?
    let releaseNotes: String?
    let downloadURL: URL?
    let releasePageURL: URL?
}

enum ElectronUpdateMetadataError: LocalizedError, Equatable {
    case missingProvider
    case invalidProviderConfiguration(String)
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return String(localized: "Electron update metadata does not name a provider")
        case .invalidProviderConfiguration(let provider):
            return String(localized: "Electron update metadata for \(provider) is incomplete")
        case .invalidManifest:
            return String(localized: "The Electron update manifest does not contain a valid version")
        }
    }
}

enum ElectronUpdateMetadataParser {
    static func parseConfiguration(_ source: String) throws -> ElectronUpdateConfiguration {
        let values = topLevelValues(in: source)
        guard let providerName = values["provider"]?.lowercased(), !providerName.isEmpty else {
            throw ElectronUpdateMetadataError.missingProvider
        }

        let channel = normalizedChannel(values["channel"])
        let provider: ElectronUpdateConfiguration.Provider

        switch providerName {
        case "generic":
            guard let baseURL = validatedHTTPSURL(values["url"]) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .generic(baseURL: directoryURL(baseURL))

        case "github":
            guard let owner = nonEmpty(values["owner"]),
                  let repository = nonEmpty(values["repo"]) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .github(owner: owner, repository: repository)

        case "s3":
            guard let bucket = nonEmpty(values["bucket"]) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }

            let endpoint = validatedHTTPSURL(values["endpoint"])
            let requiresInAppCredentials = values["acl"]?.lowercased() == "private" ||
                endpoint?.host?.lowercased().hasSuffix(".r2.cloudflarestorage.com") == true
            if requiresInAppCredentials {
                provider = .unsupported(name: providerName)
                break
            }

            let baseURL: URL?
            if let endpoint {
                baseURL = appendingPathComponents([bucket, values["path"]], to: endpoint)
            } else {
                let region = nonEmpty(values["region"]) ?? "us-east-1"
                baseURL = URL(string: "https://\(bucket).s3.\(region).amazonaws.com")
                    .flatMap { appendingPathComponents([values["path"]], to: $0) }
            }

            guard let baseURL else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .s3(baseURL: directoryURL(baseURL))

        case "spaces":
            guard let name = nonEmpty(values["name"]),
                  let region = nonEmpty(values["region"]),
                  isValidSpacesName(name),
                  isValidSpacesRegion(region) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }

            if values["acl"]?.lowercased() == "private" {
                provider = .unsupported(name: providerName)
                break
            }

            guard let endpoint = URL(
                string: "https://\(name.lowercased()).\(region.lowercased()).digitaloceanspaces.com"
            ) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            let baseURL = appendingPathComponents([values["path"]], to: endpoint)
            provider = .spaces(baseURL: directoryURL(baseURL))

        default:
            provider = .unsupported(name: providerName)
        }

        return ElectronUpdateConfiguration(provider: provider, channel: channel)
    }

    static func parseManifest(
        _ source: String,
        baseURL: URL,
        releasePageURL: URL? = nil
    ) throws -> ElectronReleaseMetadata {
        let values = topLevelValues(in: source)
        guard let rawVersion = nonEmpty(values["version"]) else {
            throw ElectronUpdateMetadataError.invalidManifest
        }

        let version = normalizeVersion(rawVersion)
        guard !Version(versionNumber: version, buildNumber: nil).isEmpty else {
            throw ElectronUpdateMetadataError.invalidManifest
        }

        let filePath = preferredFileURL(in: source) ?? values["path"]
        let downloadURL = filePath.flatMap { resolvedHTTPSURL($0, relativeTo: baseURL) }
        let releaseNotes = yamlBlockValue(for: "releaseNotes", in: source)
            ?? nonEmpty(values["releaseNotes"])

        return ElectronReleaseMetadata(
            version: version,
            releaseDate: nonEmpty(values["releaseDate"]),
            releaseNotes: releaseNotes,
            downloadURL: downloadURL,
            releasePageURL: releasePageURL
        )
    }

    private static func topLevelValues(in source: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.first?.isWhitespace != true else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let valueStart = trimmed.index(after: separator)
            let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, !["|", "|-", ">", ">-"].contains(value) else {
                continue
            }
            result[key] = unquoted(value)
        }

        return result
    }

    private static func preferredFileURL(in source: String) -> String? {
        var insideFiles = false
        var candidates: [String] = []

        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = line.prefix(while: \.isWhitespace).count

            if indentation == 0 {
                insideFiles = trimmed == "files:"
                continue
            }

            guard insideFiles else { continue }
            let candidate = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            guard candidate.hasPrefix("url:"),
                  let separator = candidate.firstIndex(of: ":") else { continue }

            let value = candidate[candidate.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if let value = nonEmpty(unquoted(value)) {
                candidates.append(value)
            }
        }

        guard !candidates.isEmpty else { return nil }

        #if arch(arm64)
        let native = candidates.filter {
            let value = $0.lowercased()
            return value.contains("arm64") || value.contains("aarch64")
        }
        #else
        let native = candidates.filter {
            let value = $0.lowercased()
            return value.contains("x64") || value.contains("x86_64") ||
                   (!value.contains("arm64") && !value.contains("aarch64"))
        }
        #endif

        let neutral = candidates.filter {
            let value = $0.lowercased()
            return !value.contains("arm64") && !value.contains("aarch64") &&
                   !value.contains("x64") && !value.contains("x86_64")
        }

        for group in [native, neutral, candidates] {
            if let diskImage = group.first(where: { $0.lowercased().hasSuffix(".dmg") }) {
                return diskImage
            }
            if let archive = group.first(where: { $0.lowercased().hasSuffix(".zip") }) {
                return archive
            }
        }

        return candidates.first
    }

    private static func yamlBlockValue(for key: String, in source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        guard let keyIndex = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "\(key): |" || trimmed == "\(key): |-" ||
                   trimmed == "\(key): >" || trimmed == "\(key): >-"
        }) else { return nil }

        let baseIndentation = lines[keyIndex].prefix(while: \.isWhitespace).count
        var blockLines: [String] = []

        for line in lines.dropFirst(keyIndex + 1) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockLines.append("")
                continue
            }

            let indentation = line.prefix(while: \.isWhitespace).count
            guard indentation > baseIndentation else { break }
            blockLines.append(String(line.dropFirst(min(indentation, baseIndentation + 2))))
        }

        let value = blockLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return nonEmpty(value)
    }

    private static func normalizedChannel(_ rawValue: String?) -> String {
        let value = nonEmpty(rawValue)?.lowercased() ?? "latest"
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
        let channel = String(String.UnicodeScalarView(allowed))
        return channel.isEmpty ? "latest" : channel
    }

    private static func normalizeVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1,
              trimmed.first?.lowercased() == "v",
              trimmed.dropFirst().first?.isNumber == true else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    private static func directoryURL(_ url: URL) -> URL {
        guard !url.hasDirectoryPath else { return url }
        return URL(string: url.absoluteString + "/") ?? url
    }

    private static func appendingPathComponents(_ components: [String?], to baseURL: URL) -> URL {
        components.compactMap(nonEmpty).reduce(directoryURL(baseURL)) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private static func validatedHTTPSURL(_ value: String?) -> URL? {
        guard let value = nonEmpty(value),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func isValidSpacesName(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9-]{2,62}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isValidSpacesRegion(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z]{3}[0-9]{1,2}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func resolvedHTTPSURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard let url = URL(string: value, relativeTo: directoryURL(baseURL))?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") ||
           (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
    }
}
