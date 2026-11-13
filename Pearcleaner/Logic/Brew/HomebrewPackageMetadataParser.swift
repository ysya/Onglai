import Foundation

struct HomebrewPackageMetadata: Equatable {
    let name: String
    let displayName: String?
    let description: String?
    let version: String?
    let bundleVersion: String?
    let homepage: String?
    let autoUpdates: Bool?
    let artifacts: [String]?
    let isDeprecated: Bool
    let isDisabled: Bool

    init(
        name: String,
        displayName: String? = nil,
        description: String? = nil,
        version: String? = nil,
        bundleVersion: String? = nil,
        homepage: String? = nil,
        autoUpdates: Bool? = nil,
        artifacts: [String]? = nil,
        isDeprecated: Bool = false,
        isDisabled: Bool = false
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.version = version
        self.bundleVersion = bundleVersion
        self.homepage = homepage
        self.autoUpdates = autoUpdates
        self.artifacts = artifacts
        self.isDeprecated = isDeprecated
        self.isDisabled = isDisabled
    }
}

enum HomebrewPackageKind {
    case formula
    case cask
}

enum HomebrewPackageMetadataParserError: Error {
    case invalidEnvelope
    case invalidPayload
}

enum HomebrewPackageMetadataParser {
    static func parseJWS(
        _ data: Data,
        kind: HomebrewPackageKind,
        osCodename: String = currentOSCodename,
        isArm: Bool = currentArchitectureIsArm
    ) throws -> [HomebrewPackageMetadata] {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = envelope["payload"] as? String,
              let payloadData = payload.data(using: .utf8) else {
            throw HomebrewPackageMetadataParserError.invalidEnvelope
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payloadData)
        } catch {
            throw HomebrewPackageMetadataParserError.invalidPayload
        }

        if let packages = object as? [[String: Any]] {
            return packages.compactMap {
                parseLegacyPackage(
                    $0,
                    kind: kind,
                    osCodename: osCodename,
                    isArm: isArm
                )
            }
        }

        guard let archive = object as? [String: Any] else {
            throw HomebrewPackageMetadataParserError.invalidPayload
        }

        let sectionName = kind == .cask ? "casks" : "formulae"
        guard let section = archive[sectionName] else { return [] }
        guard let packages = section as? [String: [String: Any]] else {
            throw HomebrewPackageMetadataParserError.invalidPayload
        }

        return packages.compactMap { name, package in
            parseInternalPackage(name: name, package: package, kind: kind)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func parseLegacyPackage(
        _ package: [String: Any],
        kind: HomebrewPackageKind,
        osCodename: String,
        isArm: Bool
    ) -> HomebrewPackageMetadata? {
        switch kind {
        case .formula:
            guard let name = package["name"] as? String else { return nil }
            return HomebrewPackageMetadata(
                name: name,
                description: package["desc"] as? String,
                version: (package["versions"] as? [String: Any])?["stable"] as? String,
                homepage: package["homepage"] as? String,
                isDeprecated: package["deprecated"] as? Bool ?? false,
                isDisabled: package["disabled"] as? Bool ?? false
            )
        case .cask:
            guard let name = package["token"] as? String else { return nil }
            let names = package["name"] as? [String]
            return HomebrewPackageMetadata(
                name: name,
                displayName: names?.first,
                description: package["desc"] as? String,
                version: caskVersion(
                    package,
                    osCodename: osCodename,
                    isArm: isArm
                ),
                bundleVersion: package["bundle_version"] as? String,
                homepage: package["homepage"] as? String,
                autoUpdates: package["auto_updates"] as? Bool,
                artifacts: legacyArtifacts(package["artifacts"]),
                isDeprecated: package["deprecated"] as? Bool ?? false,
                isDisabled: package["disabled"] as? Bool ?? false
            )
        }
    }

    private static func parseInternalPackage(
        name: String,
        package: [String: Any],
        kind: HomebrewPackageKind
    ) -> HomebrewPackageMetadata {
        switch kind {
        case .formula:
            return HomebrewPackageMetadata(
                name: name,
                description: package["desc"] as? String,
                version: package["stable_version"] as? String,
                homepage: package["homepage"] as? String,
                isDeprecated: package["deprecated"] as? Bool ?? false,
                isDisabled: package["disabled"] as? Bool ?? false
            )
        case .cask:
            let names = package["names"] as? [String]
            return HomebrewPackageMetadata(
                name: name,
                displayName: names?.first,
                description: package["desc"] as? String,
                version: package["version"] as? String,
                bundleVersion: package["bundle_version"] as? String,
                homepage: package["homepage"] as? String,
                autoUpdates: package["auto_updates"] as? Bool,
                artifacts: internalArtifacts(package["raw_artifacts"]),
                isDeprecated: package["deprecated"] as? Bool ?? false,
                isDisabled: package["disabled"] as? Bool ?? false
            )
        }
    }

    private static func legacyArtifacts(_ value: Any?) -> [String]? {
        guard let entries = value as? [[String: Any]] else { return nil }
        let apps = entries.flatMap { $0["app"] as? [String] ?? [] }
        return apps.isEmpty ? nil : apps
    }

    private static func internalArtifacts(_ value: Any?) -> [String]? {
        guard let entries = value as? [[Any]] else { return nil }
        let apps = entries.flatMap { entry -> [String] in
            guard entry.count >= 2,
                  entry[0] as? String == ":app",
                  let paths = entry[1] as? [String] else { return [] }
            return paths
        }
        return apps.isEmpty ? nil : apps
    }

    private static func caskVersion(
        _ package: [String: Any],
        osCodename: String,
        isArm: Bool
    ) -> String? {
        let baseVersion = package["version"] as? String
        guard let variations = package["variations"] as? [String: Any] else {
            return baseVersion
        }

        if isArm,
           let variation = variations["arm64_\(osCodename)"] as? [String: Any],
           let version = variation["version"] as? String {
            return version
        }

        if let variation = variations[osCodename] as? [String: Any],
           let version = variation["version"] as? String {
            return version
        }

        return baseVersion
    }

    private static var currentOSCodename: String {
        switch ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
        case 13: return "ventura"
        case 14: return "sonoma"
        case 15: return "sequoia"
        case 26...: return "tahoe"
        default: return "ventura"
        }
    }

    private static var currentArchitectureIsArm: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
