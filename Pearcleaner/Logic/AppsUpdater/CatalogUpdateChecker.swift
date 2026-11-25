import Foundation

struct CatalogCask: Sendable {
    let token: String
    let names: [String]
    let version: String?
    let homepage: String?
    let bundleVersion: String?
    let bundleShortVersion: String?
    let appNames: [String]
    let bundleIdentifiers: Set<String>
    let isDeprecated: Bool
    let isDisabled: Bool
    let minimumMacOSVersion: String?
    let architectures: [String]?
    let macOSVersions: [String]?
    let archiveURL: URL?
    let archiveSHA256: String?
    let isDirectAppRecipe: Bool

    func nativeArtifact(version: String, build: String?) -> NativeUpdateArtifact? {
        guard isDirectAppRecipe, let archiveURL, let archiveSHA256 else { return nil }
        let digest: NativeUpdateArtifact.Digest? = archiveSHA256 == "no_check" ? nil
            : .init(algorithm: .sha256, value: archiveSHA256)
        return NativeUpdateArtifact(url: archiveURL, version: version, build: build, digest: digest)
    }

    init(token: String, names: [String], version: String?, homepage: String? = nil, bundleVersion: String? = nil,
         bundleShortVersion: String? = nil, appNames: [String] = [], bundleIdentifiers: Set<String> = [],
         isDeprecated: Bool = false, isDisabled: Bool = false,
         minimumMacOSVersion: String? = nil, architectures: [String]? = nil, macOSVersions: [String]? = nil,
         archiveURL: URL? = nil, archiveSHA256: String? = nil, isDirectAppRecipe: Bool = false) {
        self.token = token
        self.names = names
        self.version = version
        self.homepage = homepage
        self.bundleVersion = bundleVersion
        self.bundleShortVersion = bundleShortVersion
        self.appNames = appNames
        self.bundleIdentifiers = bundleIdentifiers
        self.isDeprecated = isDeprecated
        self.isDisabled = isDisabled
        self.minimumMacOSVersion = minimumMacOSVersion
        self.architectures = architectures
        self.macOSVersions = macOSVersions
        self.archiveURL = archiveURL
        self.archiveSHA256 = archiveSHA256
        self.isDirectAppRecipe = isDirectAppRecipe
    }
}

/// Shares an in-flight request and caches only fully parsed, successful catalogues.
actor CatalogCache {
    private let loader: @Sendable () async throws -> [CatalogCask]
    private let maxAge: TimeInterval
    private var cached: [CatalogCask]?
    private var loadedAt: Date?
    private var inFlight: Task<[CatalogCask], Error>?

    init(maxAge: TimeInterval = 600, loader: @escaping @Sendable () async throws -> [CatalogCask]) {
        self.maxAge = maxAge
        self.loader = loader
    }

    func load() async throws -> [CatalogCask] {
        try Task.checkCancellation()
        if let cached, let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge {
            return cached
        }
        if let inFlight { return try await inFlight.value }

        let task = Task { try await loader() }
        inFlight = task
        do {
            let entries = try await task.value
            cached = entries
            loadedAt = Date()
            inFlight = nil
            try Task.checkCancellation()
            return entries
        } catch {
            inFlight = nil
            throw error
        }
    }
}

enum CatalogUpdateChecker {
    typealias ArchiveHeaderLoader = (URLRequest) async throws -> HTTPURLResponse

    private static let cache = CatalogCache {
        let url = URL(string: "https://formulae.brew.sh/api/cask.json")!
        let data = try await UpdateHTTPClient.data(from: url, maximumBytes: 32 * 1024 * 1024)
        return try parseCatalog(data)
    }

    static func isEligible(_ app: AppInfo) -> Bool {
        let path = app.path.standardizedFileURL.path
        return !app.webApp && !app.wrapped && !app.isAppStore && app.cask == nil &&
            path != "/System" && !path.hasPrefix("/System/")
    }

    static func checkForUpdates(
        apps: [AppInfo],
        rules: UpdaterRuleSet = UpdaterRuleStore.shared.snapshot,
        archiveHeaders: ArchiveHeaderLoader = { try await UpdateHTTPClient.response(for: $0, maximumBytes: 0).1 },
        loader: () async throws -> [CatalogCask] = { try await cache.load() }
    ) async -> UpdateCheckResults {
        let apps = apps.filter(isEligible)
        guard !apps.isEmpty, !Task.isCancelled else { return UpdateCheckResults() }
        let entries: [CatalogCask]
        do {
            entries = try await loader()
            try Task.checkCancellation()
        } catch is CancellationError {
            return UpdateCheckResults()
        } catch {
            return UpdateCheckResults(failures: apps.map {
                failure(for: $0, message: "The Homebrew application catalogue could not be verified", kind: .failed)
            })
        }

        var results = UpdateCheckResults()
        for app in apps {
            guard !Task.isCancelled else { return UpdateCheckResults() }
            let candidates = matchingCandidates(for: app, in: entries)
            guard candidates.count == 1, let cask = candidates.first else {
                if candidates.count > 1 {
                    results.failures.append(failure(for: app, message: "The application matches multiple catalogue entries"))
                }
                continue
            }
            guard supportsPlatform(cask) else {
                results.failures.append(failure(for: app, message: "The catalogue version cannot be compared safely"))
                continue
            }
            var projection = versionProjection(for: app, cask: cask, rules: rules)
            var verifiedArtifact: NativeUpdateArtifact?
            if cask.token == "istat-menus", cask.version == "7.50.3", app.bundleIdentifier == "com.bjango.istatmenus" {
                let artifact = await verifiedIStatMenusArchive(cask, archiveHeaders: archiveHeaders)
                guard !Task.isCancelled else { return UpdateCheckResults() }
                guard let artifact else {
                    results.failures.append(failure(for: app, message: "The catalogue version cannot be compared safely"))
                    continue
                }
                projection = VersionProjection(version: artifact.version, build: artifact.build)
                verifiedArtifact = artifact
            }
            guard let remote = projection.version ?? marketingVersion(cask.version),
                  let comparison = UpdateVersionComparator.compare(installed: app.appVersion, available: remote) else {
                results.failures.append(failure(for: app, message: "The catalogue version cannot be compared safely"))
                continue
            }

            // Some apps expose a shortened marketing version while the full
            // release token is stored verbatim in CFBundleVersion.
            if comparison == .orderedAscending, app.appBuildNumber == cask.version {
                results.currentAppPaths.insert(app.path)
                continue
            }

            // Public bundle metadata can lag behind the cask's advertised version.
            let verifiedBuild = projection.build ?? cask.bundleShortVersion.flatMap { shortVersion -> String? in
                guard UpdateVersionComparator.compare(installed: shortVersion, available: remote) == .orderedSame else { return nil }
                return cask.bundleVersion
            }
            let buildComparison = (projection.installedBuild ?? app.appBuildNumber).flatMap { localBuild in
                verifiedBuild.flatMap { UpdateVersionComparator.compare(installed: localBuild, available: $0) }
            }
            if comparison == .orderedSame, verifiedBuild != nil, buildComparison == nil {
                results.failures.append(failure(for: app, message: "The installed build could not be compared with the catalogue"))
                continue
            }
            if comparison == .orderedAscending || (comparison == .orderedSame && buildComparison == .orderedAscending) {
                results.updates.append(UpdateableApp(
                    appInfo: app, availableVersion: projection.displayVersion ?? remote, availableBuildNumber: verifiedBuild,
                    source: .catalog, adamID: nil, appStoreURL: nil,
                    externalURL: cask.homepage,
                    nativeArtifact: verifiedArtifact ?? cask.nativeArtifact(version: projection.displayVersion ?? remote, build: verifiedBuild),
                    isSelectedForUpdate: false, releaseTitle: nil, releaseDescription: nil,
                    releaseNotesLink: nil, releaseDate: nil,
                    isPreRelease: UpdateVersionComparator.channel(for: remote) != "stable",
                    isIOSApp: false, foundInRegion: nil, appcastItem: nil
                ))
            } else {
                // Comma fields can be builds, hashes, or other opaque tokens.
                // Equal marketing versions do not prove those fields are current.
                let suffixes = cask.version?.split(separator: ",", omittingEmptySubsequences: false).dropFirst() ?? []
                if comparison == .orderedSame, !projection.suffixesVerified, !suffixes.allSatisfy({
                    !$0.isEmpty && (String($0) == app.appBuildNumber || String($0) == app.appVersion)
                }) {
                    results.failures.append(failure(for: app, message: "The catalogue version cannot be compared safely"))
                    continue
                }
                results.currentAppPaths.insert(app.path)
            }
        }
        return results
    }

    private static func verifiedIStatMenusArchive(_ cask: CatalogCask, archiveHeaders: ArchiveHeaderLoader) async -> NativeUpdateArtifact? {
        // The publisher's 7.50.3 download contains a signed 7.50 (2395) bundle.
        // The CDN can replace this ZIP in place. Check its observed headers before
        // using the mapping and require the verified byte digest during installation.
        let url = URL(string: "https://cdn.istatmenus.app/files/istatmenus7/versions/iStatMenus7.50.3.zip")!
        let sha256 = "e477dc76606a6181697652ead6f3ce977e716b878165ac1aa945cc470b9ce25d"
        guard cask.isDirectAppRecipe, cask.archiveURL == url,
              cask.archiveSHA256 == "no_check" || cask.archiveSHA256?.lowercased() == sha256 else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        guard let response = try? await archiveHeaders(request), response.statusCode == 200, response.url == url,
              response.value(forHTTPHeaderField: "Last-Modified") == "Mon, 09 Nov 2026 23:27:25 GMT",
              response.value(forHTTPHeaderField: "Content-Length") == "25439637" else { return nil }
        return NativeUpdateArtifact(url: url, version: "7.50", build: "2395", digest: .init(algorithm: .sha256, value: sha256))
    }

    static func match(for app: AppInfo, in entries: [CatalogCask]) -> CatalogCask? {
        guard isEligible(app) else { return nil }
        let candidates = matchingCandidates(for: app, in: entries)
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func matchingCandidates(for app: AppInfo, in entries: [CatalogCask]) -> [CatalogCask] {
        let bundleID = app.bundleIdentifier.lowercased()
        guard !bundleID.isEmpty else { return [] }
        let filename = normalizedName(app.path.lastPathComponent)
        let appName = normalizedName(app.appName)
        let versionChannel = UpdateVersionComparator.channel(for: app.appVersion)
        let nameChannels = Set((app.appName + " " + app.path.deletingPathExtension().lastPathComponent)
            .lowercased().split(whereSeparator: { !$0.isLetter }).compactMap { channelName(String($0)) })

        return entries.filter { cask in
            guard !cask.isDeprecated, !cask.isDisabled,
                  cask.bundleIdentifiers.contains(where: { $0.lowercased() == bundleID }),
                  cask.appNames.contains(where: { normalizedName($0) == filename }) ||
                    cask.names.contains(where: { normalizedName($0) == appName }) else { return false }

            let channel: String
            if let suffix = cask.token.split(separator: "@").dropFirst().first {
                guard let knownChannel = channelName(String(suffix)) else { return false }
                channel = knownChannel
            } else {
                channel = "stable"
            }
            if let remoteVersion = marketingVersion(cask.version),
               let remoteChannel = UpdateVersionComparator.channel(for: remoteVersion),
               remoteChannel != "stable", remoteChannel != channel {
                return false
            }
            if let versionChannel, versionChannel != "stable", !nameChannels.isEmpty,
               !nameChannels.contains(versionChannel) { return false }
            if !nameChannels.isEmpty { return nameChannels.count == 1 && nameChannels.contains(channel) }
            // An invalid local version cannot prove a prerelease channel.
            return channel == (versionChannel ?? "stable")
        }
    }

    static func parseCatalog(_ data: Data, osCodename: String = currentOSCodename,
                             isArm: Bool = currentArchitecture == "arm64") throws -> [CatalogCask] {
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !objects.isEmpty else {
            throw CatalogError.invalidCatalogue
        }
        return try objects.map { object in
            var object = object
            if let variations = object["variations"] as? [String: [String: Any]] {
                let variation = (isArm ? variations["arm64_\(osCodename)"] : nil) ?? variations[osCodename]
                if let variation { object.merge(variation) { _, replacement in replacement } }
            }
            guard let token = object["token"] as? String,
                  token.range(of: #"^[a-z0-9][a-z0-9+._-]*(?:@[a-z0-9][a-z0-9+._-]*)?$"#, options: .regularExpression) != nil else {
                throw CatalogError.invalidCatalogue
            }
            let artifacts = object["artifacts"] as? [[String: Any]] ?? []
            var bundleIDs = Set<String>()
            for artifact in artifacts {
                for kind in ["uninstall", "zap"] {
                    for directives in artifact[kind] as? [[String: Any]] ?? [] {
                        for value in strings(directives["quit"]) where isExactBundleID(value) {
                            bundleIDs.insert(value.lowercased())
                        }
                        for value in signalBundleIDs(directives["signal"]) where isExactBundleID(value) {
                            bundleIDs.insert(value.lowercased())
                        }
                        for path in strings(directives["trash"]) {
                            if let bundleID = bundleIDFromPath(path) { bundleIDs.insert(bundleID.lowercased()) }
                        }
                    }
                }
            }
            let dependencies = object["depends_on"] as? [String: Any]
            let macOS = dependencies?["macos"] as? [String: Any]
            let minimum = strings(macOS?[">="]).first
            let arches = (dependencies?["arch"] as? [[String: Any]])?.compactMap { requirement -> String? in
                switch requirement["type"] as? String {
                case "arm": return "arm64"
                case "intel": return "x86_64"
                default: return nil
                }
            }
            return CatalogCask(
                token: token, names: object["name"] as? [String] ?? [], version: object["version"] as? String,
                homepage: object["homepage"] as? String,
                bundleVersion: object["bundle_version"] as? String, bundleShortVersion: object["bundle_short_version"] as? String,
                appNames: artifacts.flatMap(appNames),
                bundleIdentifiers: bundleIDs, isDeprecated: object["deprecated"] as? Bool ?? false,
                isDisabled: object["disabled"] as? Bool ?? false, minimumMacOSVersion: minimum, architectures: arches,
                macOSVersions: macOS?["=="].map(strings),
                archiveURL: (object["url"] as? String).flatMap(URL.init(string:)),
                archiveSHA256: object["sha256"] as? String,
                isDirectAppRecipe: isSingleDirectAppRecipe(artifacts) && (object["container"] == nil || object["container"] is NSNull) &&
                    (object["url_specs"] as? [String: Any] ?? [:]).isEmpty
            )
        }
    }

    static func supportsPlatform(_ cask: CatalogCask,
                                 osVersion: String = currentOSVersion,
                                 architecture: String = currentArchitecture) -> Bool {
        if let minimum = cask.minimumMacOSVersion {
            guard let comparison = UpdateVersionComparator.compare(installed: osVersion, available: minimum),
                  comparison != .orderedAscending else { return false }
        }
        if let architectures = cask.architectures, !architectures.isEmpty, !architectures.contains(architecture) {
            return false
        }
        if let versions = cask.macOSVersions, !versions.contains(where: { osVersion == $0 || osVersion.hasPrefix($0 + ".") }) {
            return false
        }
        return true
    }

    private static func isSingleDirectAppRecipe(_ artifacts: [[String: Any]]) -> Bool {
        let appArtifacts = artifacts.filter { $0["app"] != nil }
        guard appArtifacts.count == 1,
              let app = appArtifacts.first?["app"] as? [Any],
              app.count == 1, let source = app.first as? String,
              !source.hasPrefix("/"), !source.split(separator: "/").contains(".."),
              source.lowercased().hasSuffix(".app"),
              artifacts.allSatisfy({ Set($0.keys).isSubset(of: ["app", "target", "uninstall", "zap"]) }) else { return false }
        return true
    }

    private static func appNames(in artifact: [String: Any]) -> [String] {
        guard let app = artifact["app"] else { return [] }
        var paths = strings(app)
        if let target = artifact["target"] as? String { paths.append(target) }
        for option in (app as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let target = option["target"] as? String { paths.append(target) }
        }
        return paths.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func strings(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func signalBundleIDs(_ value: Any?) -> [String] {
        if let pair = value as? [String], pair.count == 2 { return [pair[1]] }
        return (value as? [[String]] ?? []).compactMap { $0.count == 2 ? $0[1] : nil }
    }

    private static func bundleIDFromPath(_ path: String) -> String? {
        for (prefix, suffix) in [("~/Library/Preferences/", ".plist"), ("~/Library/Saved Application State/", ".savedState")] {
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { continue }
            let identifier = String(path.dropFirst(prefix.count).dropLast(suffix.count))
            if isExactBundleID(identifier) { return identifier }
        }
        return nil
    }

    private static func isExactBundleID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func marketingVersion(_ value: String?) -> String? {
        value?.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init)
    }

    private static func channelName(_ value: String) -> String? {
        switch value {
        case "alpha": return "alpha"
        case "beta": return "beta"
        case "preview", "pre": return "preview"
        case "rc": return "rc"
        case "dev", "nightly", "canary", "insiders", "eap": return value
        default: return nil
        }
    }

    private static func failure(for app: AppInfo, message: String, kind: UpdateCheckIssueKind = .unavailable) -> UpdateCheckFailure {
        UpdateCheckFailure(appPath: app.path, appName: app.appName,
                           message: String(localized: String.LocalizationValue(message)), kind: kind)
    }

    private struct VersionProjection {
        var version: String?
        var build: String?
        var installedBuild: String?
        var displayVersion: String?
        var suffixesVerified = false
    }

    /// The document identifies a compiled format; it cannot provide executable parsing code.
    private static func versionProjection(for app: AppInfo, cask: CatalogCask, rules: UpdaterRuleSet) -> VersionProjection {
        guard let rule = rules.catalogVersion(token: cask.token, bundleIdentifier: app.bundleIdentifier) else {
            return VersionProjection()
        }
        let fields = cask.version?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
        guard let version = fields.first else { return VersionProjection() }
        switch rule.format {
        case .downloadHash, .downloadUUID, .postgresVariants:
            guard fields.count == 2 else { return VersionProjection() }
            let pattern: String
            switch rule.format {
            case .downloadHash: pattern = #"^(?:[0-9a-f]{40}|[0-9a-f]{64})$"#
            case .downloadUUID: pattern = #"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#
            default: pattern = #"^[0-9]+(?:-[0-9]+)*$"#
            }
            guard fields[1].lowercased().range(of: pattern, options: .regularExpression) != nil else { return VersionProjection() }
            return VersionProjection(suffixesVerified: true)
        case .plusBuild:
            guard fields.count == 2,
                  fields[1].range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else { return VersionProjection() }
            let installed = app.appVersion.split(separator: "+", omittingEmptySubsequences: false)
            guard installed.count == 2 else { return VersionProjection() }
            return VersionProjection(build: fields[1], installedBuild: String(installed[1]),
                                     displayVersion: version + "+" + fields[1], suffixesVerified: true)
        case .prefixedBuild:
            guard fields.count == 2, let local = app.appBuildNumber, let prefix = rule.buildPrefix,
                  fields[1].range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil,
                  local.hasPrefix(prefix) else { return VersionProjection() }
            return VersionProjection(build: fields[1], installedBuild: String(local.dropFirst(prefix.count)), suffixesVerified: true)
        case .hyphenBuild:
            let parts = version.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[1].allSatisfy(\.isNumber), !parts[1].isEmpty else { return VersionProjection() }
            return VersionProjection(version: String(parts[0]), build: String(parts[1]))
        }
    }

    private enum CatalogError: Error {
        case invalidCatalogue
    }

    private static var currentOSCodename: String {
        switch ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
        case 11: return "big_sur"
        case 12: return "monterey"
        case 13: return "ventura"
        case 14: return "sonoma"
        case 15: return "sequoia"
        case 26: return "tahoe"
        default: return ""
        }
    }

    private static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
