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

    func comparisonVersion(for version: String) -> String? {
        if UpdateVersionComparator.compare(installed: version, available: version) != nil { return version }
        // Some stable publishers append their configured channel to a numeric
        // release counter. Do not apply this outside that exact stable channel.
        guard ["latest", "stable", "release"].contains(channel),
              version.hasSuffix("-" + channel) else { return nil }
        let core = String(version.dropLast(channel.count + 1))
        guard core.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return core
    }

    func acceptsReleaseVersion(_ version: String) -> Bool {
        guard let comparable = comparisonVersion(for: version),
              let versionChannel = UpdateVersionComparator.channel(for: comparable) else { return false }
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
    var nativeArtifact: NativeUpdateArtifact? = nil
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
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return String(localized: "Electron update metadata does not name a provider")
        case .invalidProviderConfiguration(let provider):
            return String(localized: "Electron update metadata for \(provider) is incomplete")
        case .invalidManifest:
            return String(localized: "The Electron update manifest does not contain a valid version")
        case .unsupportedVersion:
            return String(localized: "The Electron update version format cannot be compared automatically")
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
        releasePageURL: URL? = nil,
        configuration: ElectronUpdateConfiguration? = nil
    ) throws -> ElectronReleaseMetadata {
        let values = topLevelValues(in: source)
        guard let rawVersion = nonEmpty(values["version"]) else {
            throw ElectronUpdateMetadataError.invalidManifest
        }

        let version = normalizeVersion(rawVersion)
        let comparable = configuration?.comparisonVersion(for: version) ?? version
        guard UpdateVersionComparator.compare(installed: comparable, available: comparable) != nil else {
            throw ElectronUpdateMetadataError.unsupportedVersion
        }

        let selected = preferredFile(in: source, fallbackValues: values)
        let downloadURL = selected.flatMap { resolvedHTTPSURL($0.url, relativeTo: baseURL) }
        let artifact = downloadURL.flatMap { url -> NativeUpdateArtifact? in
            let digest = selected?.sha512.map { NativeUpdateArtifact.Digest(algorithm: .sha512, value: $0) }
            return NativeUpdateArtifact(url: url, version: version, digest: digest)
        }
        let releaseNotes = yamlBlockValue(for: "releaseNotes", in: source)
            ?? nonEmpty(values["releaseNotes"])

        return ElectronReleaseMetadata(
            version: version,
            releaseDate: nonEmpty(values["releaseDate"]),
            releaseNotes: releaseNotes,
            downloadURL: downloadURL,
            releasePageURL: releasePageURL,
            nativeArtifact: artifact
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

    private struct ManifestFile {
        let url: String
        let sha512: String?
    }

    /// Select an exact file record, retaining its own hash. Never borrow the
    /// legacy top-level hash for a different file from the files array.
    private static func preferredFile(in source: String, fallbackValues: [String: String]) -> ManifestFile? {
        var insideFiles = false
        var sawFiles = false
        var records: [[String: String]] = []
        var current: [String: String]?
        var digestBlockIndentation: Int?
        var malformed = false
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indentation = line.prefix(while: \.isWhitespace).count
            if let digestIndentation = digestBlockIndentation {
                if indentation > digestIndentation {
                    // SHA512 block scalars may wrap base64 across lines. Only
                    // base64 characters can continue this exact record's hash.
                    guard trimmed.unicodeScalars.allSatisfy({
                        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=").contains($0)
                    }) else { malformed = true; continue }
                    current?["sha512", default: ""] += trimmed
                    continue
                }
                digestBlockIndentation = nil
            }
            if indentation == 0 {
                if insideFiles, let current { records.append(current) }
                current = nil
                insideFiles = trimmed == "files:"
                if insideFiles {
                    if sawFiles { malformed = true }
                    sawFiles = true
                }
                continue
            }
            guard insideFiles else { continue }
            let startsRecord = trimmed.hasPrefix("- ")
            if startsRecord {
                if let current { records.append(current) }
                current = [:]
            }
            let field = startsRecord ? String(trimmed.dropFirst(2)) : trimmed
            guard let separator = field.firstIndex(of: ":"), current != nil else {
                malformed = true
                continue
            }
            let key = String(field[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = unquoted(String(field[field.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
            guard current?[key] == nil else { malformed = true; continue }
            if key == "sha512", [">", ">-", ">+", "|", "|-", "|+"].contains(value) {
                current?[key] = ""
                digestBlockIndentation = indentation
            } else {
                current?[key] = value
            }
        }
        if insideFiles, let current { records.append(current) }
        guard !malformed else { return nil }
        let files: [ManifestFile]
        if sawFiles {
            guard !records.isEmpty, records.allSatisfy({ nonEmpty($0["url"]) != nil }) else { return nil }
            files = records.compactMap { record in
                guard let url = nonEmpty(record["url"]) else { return nil }
                return ManifestFile(url: url, sha512: record["sha512"])
            }
        } else if let url = nonEmpty(fallbackValues["path"]) {
            files = [ManifestFile(url: url, sha512: legacySHA512(in: source))]
        } else { return nil }

        let ranked: [(file: ManifestFile, rank: Int)] = files.compactMap { file in
            guard let url = URL(string: file.url),
                  ["zip", "dmg"].contains(url.pathExtension.lowercased()) else { return nil }
            // Only complete architecture tokens in the filename establish a
            // preference. Directory and hostname text cannot select an asset.
            let filename = url.lastPathComponent.lowercased()
            let arm = filename.range(of: #"(?:^|[^a-z0-9])(?:arm64|aarch64)(?:$|[^a-z0-9])"#,
                                     options: .regularExpression) != nil
            let intel = filename.range(of: #"(?:^|[^a-z0-9])(?:x64|x86_64)(?:$|[^a-z0-9])"#,
                                       options: .regularExpression) != nil
            let unsupported = filename.range(of: #"(?:^|[^a-z0-9])ia32(?:$|[^a-z0-9])"#,
                                             options: .regularExpression) != nil
            guard !unsupported else { return nil }
            #if arch(arm64)
            guard !intel else { return nil }
            return (file, arm ? 0 : 1)
            #else
            guard !arm else { return nil }
            return (file, intel ? 0 : 1)
            #endif
        }
        guard let bestRank = ranked.map(\.rank).min() else { return nil }
        let preferred = ranked.filter { $0.rank == bestRank }.map(\.file)
        // Prefer a unique ZIP within the best architecture rank. Multiple files
        // of that format remain ambiguous; do not escape the tie via a DMG.
        for format in ["zip", "dmg"] {
            let candidates = preferred.filter { URL(string: $0.url)?.pathExtension.lowercased() == format }
            if candidates.count > 1 { return nil }
            if let selected = candidates.first { return selected }
        }
        return nil
    }

    /// Legacy manifests bind a top-level hash to their top-level path. An
    /// advertised but invalid/empty hash stays invalid instead of becoming nil.
    private static func legacySHA512(in source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        var result: String?
        var found = false
        for (index, line) in lines.enumerated() {
            guard line.first?.isWhitespace != true,
                  let separator = line.firstIndex(of: ":"),
                  line[..<separator].trimmingCharacters(in: .whitespaces) == "sha512" else { continue }
            guard !found else { return "" }
            found = true
            let value = unquoted(String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
            guard [">", ">-", ">+", "|", "|-", "|+"].contains(value) else {
                result = value
                continue
            }
            var digest = ""
            for continuation in lines.dropFirst(index + 1) {
                let content = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty { continue }
                guard continuation.first?.isWhitespace == true else { break }
                guard content.unicodeScalars.allSatisfy({
                    CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=").contains($0)
                }) else { return "" }
                digest += content
            }
            result = digest
        }
        return result
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
