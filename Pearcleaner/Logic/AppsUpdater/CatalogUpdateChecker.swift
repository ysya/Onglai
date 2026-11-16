import Foundation

struct CatalogCask: Sendable {
    let token: String
    let names: [String]
    let version: String?
    let bundleVersion: String?
    let bundleShortVersion: String?
    let appNames: [String]
    let bundleIdentifiers: Set<String>
    let isDeprecated: Bool
    let isDisabled: Bool
    let minimumMacOSVersion: String?
    let architectures: [String]?
    let macOSVersions: [String]?

    init(token: String, names: [String], version: String?, bundleVersion: String? = nil,
         bundleShortVersion: String? = nil, appNames: [String] = [], bundleIdentifiers: Set<String> = [],
         isDeprecated: Bool = false, isDisabled: Bool = false,
         minimumMacOSVersion: String? = nil, architectures: [String]? = nil, macOSVersions: [String]? = nil) {
        self.token = token
        self.names = names
        self.version = version
        self.bundleVersion = bundleVersion
        self.bundleShortVersion = bundleShortVersion
        self.appNames = appNames
        self.bundleIdentifiers = bundleIdentifiers
        self.isDeprecated = isDeprecated
        self.isDisabled = isDisabled
        self.minimumMacOSVersion = minimumMacOSVersion
        self.architectures = architectures
        self.macOSVersions = macOSVersions
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
                failure(for: $0, message: "The Homebrew application catalogue could not be verified")
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
            guard supportsPlatform(cask), let remote = marketingVersion(cask.version),
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
            let verifiedBuild = cask.bundleShortVersion.flatMap { shortVersion -> String? in
                guard UpdateVersionComparator.compare(installed: shortVersion, available: remote) == .orderedSame else { return nil }
                return cask.bundleVersion
            }
            let buildComparison = app.appBuildNumber.flatMap { localBuild in
                verifiedBuild.flatMap { UpdateVersionComparator.compare(installed: localBuild, available: $0) }
            }
            if comparison == .orderedSame, verifiedBuild != nil, buildComparison == nil {
                results.failures.append(failure(for: app, message: "The installed build could not be compared with the catalogue"))
                continue
            }
            if comparison == .orderedAscending || (comparison == .orderedSame && buildComparison == .orderedAscending) {
                results.updates.append(UpdateableApp(
                    appInfo: app, availableVersion: remote, availableBuildNumber: verifiedBuild,
                    source: .catalog, adamID: nil, appStoreURL: nil,
                    externalURL: "https://formulae.brew.sh/cask/\(cask.token)",
                    isSelectedForUpdate: false, releaseTitle: nil, releaseDescription: nil,
                    releaseNotesLink: nil, releaseDate: nil,
                    isPreRelease: UpdateVersionComparator.channel(for: remote) != "stable",
                    isIOSApp: false, foundInRegion: nil, appcastItem: nil
                ))
            } else {
                // Comma fields can be builds, hashes, or other opaque tokens.
                // Equal marketing versions do not prove those fields are current.
                let suffixes = cask.version?.split(separator: ",", omittingEmptySubsequences: false).dropFirst() ?? []
                if comparison == .orderedSame, !suffixes.allSatisfy({
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
                bundleVersion: object["bundle_version"] as? String, bundleShortVersion: object["bundle_short_version"] as? String,
                appNames: artifacts.flatMap(appNames),
                bundleIdentifiers: bundleIDs, isDeprecated: object["deprecated"] as? Bool ?? false,
                isDisabled: object["disabled"] as? Bool ?? false, minimumMacOSVersion: minimum, architectures: arches,
                macOSVersions: macOS?["=="].map(strings)
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

    private static func failure(for app: AppInfo, message: String) -> UpdateCheckFailure {
        UpdateCheckFailure(appPath: app.path, appName: app.appName, message: String(localized: String.LocalizationValue(message)))
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
