import Foundation

struct SparkleFeedRule: Codable, Sendable {
    let bundleIdentifier: String
    let feedURL: String
    let architectures: [String]?
}

struct OfficialSourceRule: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case json, termius, linear, proton, jetbrains, studio, chrome, brave, github
    }

    enum ChannelPolicy: String, Codable, Sendable {
        case numericStable, vscodeStable, androidStudioStable
    }

    let bundleIdentifier: String
    let kind: Kind
    let endpointTemplate: String
    let page: String
    let versionKey: String?
    let productCode: String?
    let localProductCode: String?
    let githubOwner: String?
    let githubRepository: String?
    let usesBuild: Bool
    let channelPolicy: ChannelPolicy
    let allowsNoUpdate204: Bool
    let nativeDownloadURLKey: String?
    let nativeSHA256Key: String?
    let nativeFormat: NativeUpdateArtifact.Format?

    init(bundleIdentifier: String, kind: Kind, endpointTemplate: String, page: String,
         versionKey: String? = nil, productCode: String? = nil, localProductCode: String? = nil,
         githubOwner: String? = nil, githubRepository: String? = nil,
         usesBuild: Bool = false, channelPolicy: ChannelPolicy = .numericStable,
         allowsNoUpdate204: Bool = false, nativeDownloadURLKey: String? = nil,
         nativeSHA256Key: String? = nil, nativeFormat: NativeUpdateArtifact.Format? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.kind = kind
        self.endpointTemplate = endpointTemplate
        self.page = page
        self.versionKey = versionKey
        self.productCode = productCode
        self.localProductCode = localProductCode
        self.githubOwner = githubOwner
        self.githubRepository = githubRepository
        self.usesBuild = usesBuild
        self.channelPolicy = channelPolicy
        self.allowsNoUpdate204 = allowsNoUpdate204
        self.nativeDownloadURLKey = nativeDownloadURLKey
        self.nativeSHA256Key = nativeSHA256Key
        self.nativeFormat = nativeFormat
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, kind, endpointTemplate, page, versionKey, productCode, localProductCode
        case githubOwner, githubRepository, usesBuild, channelPolicy, allowsNoUpdate204
        case nativeDownloadURLKey, nativeSHA256Key, nativeFormat
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try fields.decode(String.self, forKey: .bundleIdentifier)
        kind = try fields.decode(Kind.self, forKey: .kind)
        endpointTemplate = try fields.decode(String.self, forKey: .endpointTemplate)
        page = try fields.decode(String.self, forKey: .page)
        versionKey = try fields.decodeIfPresent(String.self, forKey: .versionKey)
        productCode = try fields.decodeIfPresent(String.self, forKey: .productCode)
        localProductCode = try fields.decodeIfPresent(String.self, forKey: .localProductCode)
        githubOwner = try fields.decodeIfPresent(String.self, forKey: .githubOwner)
        githubRepository = try fields.decodeIfPresent(String.self, forKey: .githubRepository)
        usesBuild = try fields.decodeIfPresent(Bool.self, forKey: .usesBuild) ?? false
        channelPolicy = try fields.decodeIfPresent(ChannelPolicy.self, forKey: .channelPolicy) ?? .numericStable
        allowsNoUpdate204 = try fields.decodeIfPresent(Bool.self, forKey: .allowsNoUpdate204) ?? false
        nativeDownloadURLKey = try fields.decodeIfPresent(String.self, forKey: .nativeDownloadURLKey)
        nativeSHA256Key = try fields.decodeIfPresent(String.self, forKey: .nativeSHA256Key)
        nativeFormat = try fields.decodeIfPresent(NativeUpdateArtifact.Format.self, forKey: .nativeFormat)
    }
}

struct CatalogVersionRule: Codable, Sendable {
    enum Format: String, Codable, Sendable {
        case downloadHash, downloadUUID, postgresVariants, plusBuild, prefixedBuild, hyphenBuild
    }

    let token: String
    let bundleIdentifier: String
    let format: Format
    let buildPrefix: String?
}

/// Data for adapters already compiled into the app. Rule documents cannot add
/// parsers, execute code, or bypass an installed application's signing checks.
struct UpdaterRuleSet: Codable, Sendable {
    static let maximumBytes = 256 * 1024

    let schemaVersion: Int
    let revision: Int
    let sparkleFeeds: [SparkleFeedRule]
    let officialSources: [OfficialSourceRule]
    let catalogVersions: [CatalogVersionRule]

    init(schemaVersion: Int = 1, revision: Int, sparkleFeeds: [SparkleFeedRule] = [],
         officialSources: [OfficialSourceRule] = [], catalogVersions: [CatalogVersionRule] = []) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.sparkleFeeds = sparkleFeeds
        self.officialSources = officialSources
        self.catalogVersions = catalogVersions
    }

    static func decodeValidated(_ data: Data) throws -> UpdaterRuleSet {
        guard data.count <= maximumBytes else { throw ValidationError.invalidDocument }
        let rules = try JSONDecoder().decode(Self.self, from: data)
        try rules.validate()
        return rules
    }

    static func bundled() -> UpdaterRuleSet {
        guard let url = Bundle.main.url(forResource: "updater-rules", withExtension: "json") else {
            return UpdaterRuleSet(revision: 1)
        }
        do {
            return try decodeValidated(Data(contentsOf: url))
        } catch {
            preconditionFailure("The bundled updater rule document is invalid")
        }
    }

    func sparkleFeed(bundleIdentifier: String, architecture: String? = nil) -> SparkleFeedRule? {
        sparkleFeeds.first { rule in
            guard rule.bundleIdentifier == bundleIdentifier else { return false }
            guard let architectures = rule.architectures else { return true }
            guard let architecture else { return false }
            return architectures.contains(architecture)
        }
    }

    func officialSource(bundleIdentifier: String) -> OfficialSourceRule? {
        officialSources.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func catalogVersion(token: String, bundleIdentifier: String) -> CatalogVersionRule? {
        catalogVersions.first { $0.token == token && $0.bundleIdentifier == bundleIdentifier }
    }

    private enum ValidationError: Error { case invalidDocument }

    private func validate() throws {
        guard schemaVersion == 1, revision > 0,
              Set(sparkleFeeds.map(\.bundleIdentifier)).count == sparkleFeeds.count,
              Set(officialSources.map(\.bundleIdentifier)).count == officialSources.count,
              Set(catalogVersions.map { $0.token + "\u{0}" + $0.bundleIdentifier }).count == catalogVersions.count else {
            throw ValidationError.invalidDocument
        }
        for rule in sparkleFeeds {
            guard Self.isBundleIdentifier(rule.bundleIdentifier) else { throw ValidationError.invalidDocument }
            try Self.validateURL(rule.feedURL)
            if let architectures = rule.architectures {
                guard !architectures.isEmpty, Set(architectures).count == architectures.count,
                      architectures.allSatisfy({ ["arm64", "x86_64"].contains($0) }) else {
                    throw ValidationError.invalidDocument
                }
            }
        }
        for rule in officialSources { try Self.validate(rule) }
        for rule in catalogVersions {
            guard Self.isBundleIdentifier(rule.bundleIdentifier), rule.token.count <= 100,
                  Self.matches(rule.token, #"^[a-z0-9][a-z0-9+_.@-]*$"#) else { throw ValidationError.invalidDocument }
            if rule.format == .prefixedBuild {
                guard let prefix = rule.buildPrefix, prefix.count <= 32,
                      Self.matches(prefix, #"^[A-Za-z0-9]+-$"#) else { throw ValidationError.invalidDocument }
            } else if rule.buildPrefix != nil {
                throw ValidationError.invalidDocument
            }
        }
    }

    private static func validate(_ rule: OfficialSourceRule) throws {
        guard isBundleIdentifier(rule.bundleIdentifier) else { throw ValidationError.invalidDocument }
        try validateURL(rule.endpointTemplate, allowsPlaceholders: true)
        try validateURL(rule.page)
        guard (rule.kind == .json) == (rule.versionKey != nil),
              (rule.kind == .jetbrains) == (rule.productCode != nil),
              (rule.kind == .github) == (rule.githubOwner != nil && rule.githubRepository != nil),
              rule.kind == .github || (rule.githubOwner == nil && rule.githubRepository == nil),
              !rule.allowsNoUpdate204 || rule.kind == .json,
              !rule.usesBuild || [.studio, .brave, .jetbrains].contains(rule.kind) else {
            throw ValidationError.invalidDocument
        }
        if rule.nativeDownloadURLKey != nil || rule.nativeSHA256Key != nil || rule.nativeFormat != nil {
            guard rule.kind == .json,
                  let urlKey = rule.nativeDownloadURLKey, let hashKey = rule.nativeSHA256Key,
                  matches(urlKey, #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#),
                  matches(hashKey, #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#),
                  urlKey != hashKey, urlKey != rule.versionKey, hashKey != rule.versionKey else {
                throw ValidationError.invalidDocument
            }
        }
        switch rule.channelPolicy {
        case .numericStable: guard rule.kind != .studio else { throw ValidationError.invalidDocument }
        case .vscodeStable: guard rule.kind == .json else { throw ValidationError.invalidDocument }
        case .androidStudioStable: guard rule.kind == .studio else { throw ValidationError.invalidDocument }
        }
        if let key = rule.versionKey, !matches(key, #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#) {
            throw ValidationError.invalidDocument
        }
        if let code = rule.productCode, !matches(code, #"^[A-Z][A-Z0-9]{0,15}$"#) {
            throw ValidationError.invalidDocument
        }
        if let localCode = rule.localProductCode {
            guard rule.kind == .jetbrains, rule.productCode != "TBA",
                  matches(localCode, #"^[A-Z][A-Z0-9]{0,15}$"#) else { throw ValidationError.invalidDocument }
        }
        if [.studio, .brave].contains(rule.kind) || rule.productCode == "TBA" {
            guard rule.usesBuild else { throw ValidationError.invalidDocument }
        }
        if rule.kind == .github {
            guard let owner = rule.githubOwner, let repository = rule.githubRepository,
                  matches(owner, #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#),
                  repository != ".", repository != "..", repository.count <= 100,
                  matches(repository, #"^[A-Za-z0-9_.-]+$"#),
                  rule.endpointTemplate == "https://api.github.com/repos/\(owner)/\(repository)/releases/latest" else {
                throw ValidationError.invalidDocument
            }
        }
    }

    private static func isBundleIdentifier(_ value: String) -> Bool {
        value.count <= 255 && matches(value, #"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func validateURL(_ value: String, allowsPlaceholders: Bool = false) throws {
        guard value.count <= 4096,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains("\\"),
              let original = URLComponents(string: value),
              original.scheme?.lowercased() == "https", original.user == nil, original.password == nil,
              original.fragment == nil, let host = original.host?.lowercased(), isPublicHostname(host),
              original.port == nil || original.port == 443 else { throw ValidationError.invalidDocument }
        var resolved = value
        if allowsPlaceholders {
            for (name, replacement) in [("darwinPlatform", "darwin-arm64"), ("macPlatform", "mac-arm64"),
                                        ("chromePlatform", "mac_arm64"), ("braveChannel", "stable-arm64")] {
                resolved = resolved.replacingOccurrences(of: "{\(name)}", with: replacement)
            }
        }
        guard !resolved.contains("{"), !resolved.contains("}"),
              let url = URL(string: resolved), url.host?.lowercased() == host else {
            throw ValidationError.invalidDocument
        }
    }

    /// Rules address named public services, so IP literals and single-label or
    /// local-network names are excluded rather than interpreted as endpoints.
    private static func isPublicHostname(_ host: String) -> Bool {
        guard host.count <= 253, host.contains("."),
              !["localhost", "localdomain", "local", "internal", "lan", "home", "home.arpa", "test", "invalid"].contains(where: {
                  host == $0 || host.hasSuffix("." + $0)
              }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ matches(String($0), #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#) }),
              let topLevel = labels.last, matches(String(topLevel), #"^(?:[a-z]{2,63}|xn--[a-z0-9-]{1,59})$"#) else { return false }
        return true
    }
}
