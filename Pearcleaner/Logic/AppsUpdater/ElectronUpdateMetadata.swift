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
        case gitlab(baseURL: URL, projectID: String)
        case bitbucket(owner: String, slug: String)
        case r2(baseURL: URL)
        case keygen(baseURL: URL, account: String, product: String)
        case unsupported(name: String)
    }

    let provider: Provider
    let channel: String

    var manifestName: String {
        "\(channel)-mac.yml"
    }

    var manifestURL: URL? {
        switch provider {
        case .generic(let baseURL), .s3(let baseURL), .spaces(let baseURL), .r2(let baseURL):
            return baseURL.appendingPathComponent(manifestName)
        case .bitbucket(let owner, let slug):
            return URL(string: "https://api.bitbucket.org/2.0/repositories/\(owner)/\(slug)/downloads/\(manifestName)")
        case .keygen(let baseURL, let account, let product):
            let url = baseURL.appendingPathComponent("v1/accounts/\(account)/artifacts/\(manifestName)")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "product", value: product)]
            return components?.url
        case .github, .gitlab, .unsupported:
            return nil
        }
    }

    var fallbackExternalURL: URL? {
        switch provider {
        case .generic(let baseURL), .s3(let baseURL), .spaces(let baseURL), .r2(let baseURL):
            return baseURL
        case .github(let owner, let repository):
            return URL(string: "https://github.com/\(owner)/\(repository)/releases")
        case .bitbucket(let owner, let slug):
            return URL(string: "https://bitbucket.org/\(owner)/\(slug)/downloads/")
        case .gitlab(let baseURL, let projectID):
            guard projectID.contains("/") else { return nil }
            return baseURL.appendingPathComponent(projectID).appendingPathComponent("-/releases")
        case .keygen, .unsupported:
            return nil
        }
    }

    var releaseAPIURL: URL? {
        guard case .gitlab(let baseURL, let projectID) = provider,
              let encodedID = projectID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return nil }
        return URL(string: "api/v4/projects/\(encodedID)/releases/permalink/latest", relativeTo: baseURL)?.absoluteURL
    }

    var manifestRequest: URLRequest? {
        guard let manifestURL else { return nil }
        var request = URLRequest(url: manifestURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        if case .keygen = provider {
            request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
            request.setValue("1.1", forHTTPHeaderField: "Keygen-Version")
        } else {
            request.setValue("text/yaml, text/plain, application/octet-stream", forHTTPHeaderField: "Accept")
        }
        return request
    }

    func acceptsReleaseVersion(_ version: String) -> Bool {
        guard let versionChannel = UpdateVersionComparator.channel(for: version) else { return false }
        switch channel {
        case "latest", "stable", "release": return versionChannel == "stable"
        case "alpha", "beta", "preview", "rc", "dev": return versionChannel == "stable" || versionChannel == channel
        default: return true // Publishers may use a custom channel name.
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

struct ElectronGitLabReleaseMetadata {
    let manifestURL: URL
    let releasePageURL: URL?
    let releaseNotes: String?
    let releaseDate: String?
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
    static func parseGitLabRelease(_ data: Data, configuration: ElectronUpdateConfiguration) throws -> ElectronGitLabReleaseMetadata {
        guard case .gitlab(let baseURL, _) = configuration.provider else {
            throw ElectronUpdateMetadataError.invalidProviderConfiguration("gitlab")
        }
        let release = try JSONDecoder().decode(GitLabRelease.self, from: data)
        let isStableChannel = ["latest", "stable", "release"].contains(configuration.channel)
        guard release.upcomingRelease != true, release.draft != true,
              !(isStableChannel && release.prerelease == true),
              configuration.acceptsReleaseVersion(release.tagName) else {
            throw ElectronUpdateMetadataError.invalidManifest
        }

        let preferredNames = [configuration.manifestName, "latest-mac.yml"]
        guard let asset = preferredNames.compactMap({ name in
            release.assets.links.first { $0.name == name }
        }).first,
              let manifestURL = validatedHTTPSURL(asset.directAssetURL),
              hasSameOrigin(manifestURL, as: baseURL) else {
            throw ElectronUpdateMetadataError.invalidManifest
        }

        var releasePageURL = configuration.fallbackExternalURL
        if let rawPage = release.links?["self"] {
            guard let page = validatedHTTPSURL(rawPage), hasSameOrigin(page, as: baseURL) else {
                throw ElectronUpdateMetadataError.invalidManifest
            }
            releasePageURL = page
        }
        return ElectronGitLabReleaseMetadata(
            manifestURL: manifestURL,
            releasePageURL: releasePageURL,
            releaseNotes: nonEmpty(release.description),
            releaseDate: nonEmpty(release.releasedAt)
        )
    }

    static func parseConfiguration(_ source: String) throws -> ElectronUpdateConfiguration {
        let values = topLevelValues(in: source)
        guard let providerName = values["provider"]?.lowercased(), !providerName.isEmpty else {
            throw ElectronUpdateMetadataError.missingProvider
        }

        let channel = normalizedChannel(values["channel"], defaultValue: providerName == "keygen" ? "stable" : "latest")
        if requiresCredentials(in: source, values: values) {
            return ElectronUpdateConfiguration(provider: .unsupported(name: providerName), channel: channel)
        }
        let provider: ElectronUpdateConfiguration.Provider

        switch providerName {
        case "generic":
            guard let baseURL = validatedHTTPSURL(values["url"]) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .generic(baseURL: directoryURL(baseURL))

        case "github":
            guard let owner = nonEmpty(values["owner"]),
                  let repository = nonEmpty(values["repo"]),
                  isValidPathIdentifier(owner), isValidPathIdentifier(repository) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .github(owner: owner, repository: repository)

        case "gitlab":
            guard let projectID = nonEmpty(values["projectId"]), isValidGitLabProjectID(projectID),
                  let baseURL = validatedHost(values["host"] ?? "gitlab.com") else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .gitlab(baseURL: baseURL, projectID: projectID)

        case "bitbucket":
            guard let owner = nonEmpty(values["owner"]), let slug = nonEmpty(values["slug"]),
                  isValidPathIdentifier(owner), isValidPathIdentifier(slug) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .bitbucket(owner: owner, slug: slug)

        case "r2":
            guard nonEmpty(values["publicUrl"]) != nil else {
                provider = .unsupported(name: providerName)
                break
            }
            guard let publicURL = validatedHTTPSURL(values["publicUrl"]),
                  publicURL.query == nil, publicURL.fragment == nil else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            guard !isR2APIEndpoint(publicURL) else {
                provider = .unsupported(name: providerName)
                break
            }
            provider = .r2(baseURL: directoryURL(appendingPathComponents([values["path"]], to: publicURL)))

        case "keygen":
            guard let account = nonEmpty(values["account"]), let product = nonEmpty(values["product"]),
                  isValidPathIdentifier(account), isValidPathIdentifier(product),
                  let baseURL = validatedHost(values["host"] ?? "api.keygen.sh") else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }
            provider = .keygen(baseURL: baseURL, account: account, product: product)

        case "s3":
            guard let bucket = nonEmpty(values["bucket"]) else {
                throw ElectronUpdateMetadataError.invalidProviderConfiguration(providerName)
            }

            let endpoint = validatedHTTPSURL(values["endpoint"])
            let requiresInAppCredentials = values["acl"]?.lowercased() == "private" ||
                endpoint.map(isR2APIEndpoint) == true
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
        guard UpdateVersionComparator.compare(installed: version, available: version) != nil else {
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

    private static func normalizedChannel(_ rawValue: String?, defaultValue: String) -> String {
        let value = nonEmpty(rawValue)?.lowercased() ?? defaultValue
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
        let channel = String(String.UnicodeScalarView(allowed))
        return channel.isEmpty ? defaultValue : channel
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
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path += "/"
        return components?.url ?? url
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
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
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
        guard var url = URL(string: value, relativeTo: directoryURL(baseURL))?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        if hasSameOrigin(url, as: baseURL),
           let query = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           url.query == nil {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.percentEncodedQuery = query
            if let scopedURL = components?.url { url = scopedURL }
        }
        return url
    }

    private static func validatedHost(_ host: String) -> URL? {
        guard !host.contains("/"), !host.contains("?"), !host.contains("#"),
              let url = validatedHTTPSURL("https://" + host),
              url.path.isEmpty, url.query == nil, url.fragment == nil else { return nil }
        return directoryURL(url)
    }

    private static func isValidPathIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func isValidGitLabProjectID(_ value: String) -> Bool {
        if value.allSatisfy(\.isNumber) { return !value.isEmpty }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { isValidPathIdentifier(String($0)) }
    }

    private static func isR2APIEndpoint(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "r2.cloudflarestorage.com" || host.hasSuffix(".r2.cloudflarestorage.com")
    }

    private static func hasSameOrigin(_ url: URL, as baseURL: URL) -> Bool {
        url.scheme?.lowercased() == baseURL.scheme?.lowercased() &&
            url.host?.lowercased() == baseURL.host?.lowercased() &&
            (url.port ?? 443) == (baseURL.port ?? 443)
    }

    private static func requiresCredentials(in source: String, values: [String: String]) -> Bool {
        if ["true", "yes", "1"].contains(values["private"]?.lowercased() ?? "") ||
            values["acl"]?.lowercased() == "private" { return true }
        if let strategy = nonEmpty(values["distributionStrategy"])?.lowercased(), strategy != "open" { return true }
        let credentialKeys: Set<String> = ["token", "license", "licensekey", "apikey", "apitoken", "accesstoken", "authorization", "password", "username"]
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<separator].lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if ["requestheaders", "awscredentials"].contains(key) {
                if rawValue.isEmpty || nonEmpty(unquoted(rawValue)) != nil { return true }
            }
            if credentialKeys.contains(key), let value = nonEmpty(unquoted(String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces))), value.lowercased() != "false" {
                return true
            }
        }
        return false
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
        return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
    }
}

private struct GitLabRelease: Decodable {
    struct Assets: Decodable {
        struct Link: Decodable {
            let name: String
            let directAssetURL: String?

            enum CodingKeys: String, CodingKey {
                case name
                case directAssetURL = "direct_asset_url"
            }
        }
        let links: [Link]
    }

    let tagName: String
    let description: String?
    let releasedAt: String?
    let upcomingRelease: Bool?
    let draft: Bool?
    let prerelease: Bool?
    let assets: Assets
    let links: [String: String]?

    enum CodingKeys: String, CodingKey {
        case description, draft, prerelease, assets
        case tagName = "tag_name"
        case releasedAt = "released_at"
        case upcomingRelease = "upcoming_release"
        case links = "_links"
    }
}
