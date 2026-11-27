import Foundation
import Security

enum DeletionSafetyPolicy {
    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    static func isSystemApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return path.hasPrefix("/system/") || path == "/applications/safari.app"
    }

    static func uninstallCandidates(_ candidates: [URL], appBundle: URL, ownedFiles: Set<URL> = []) -> [URL] {
        let bundlePath = appBundle.standardizedFileURL.path
        let ownedPaths = Set(ownedFiles.map { $0.standardizedFileURL.path })
        let sorted = candidates.map(\.standardizedFileURL).sorted { $0.path < $1.path }
        var result: [URL] = []
        for url in sorted {
            let path = url.path
            guard !isInTrash(url), !bundlePath.hasPrefix(path + "/"),
                  ownedPaths.contains(path) || !ownedPaths.contains(where: { $0.hasPrefix(path + "/") }),
                  !result.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
                continue
            }
            result.append(url)
        }
        return result
    }

    /// Discovers conventional app-specific files independently of the name search.
    static func ownedLibraryFiles(
        bundleIdentifier: String,
        userLibrary: URL,
        localLibrary: URL?,
        appBundle: URL? = nil,
        onReadError: (Error, String) -> Void
    ) -> Set<URL> {
        let identifier = bundleIdentifier
        guard isValidPreferenceIdentifier(identifier) else { return [] }

        let manager = FileManager.default
        var result = Set<URL>()

        func reportReadError(_ error: Error, at url: URL) {
            if !isMissingFileError(error) { onReadError(error, url.path) }
        }

        func add(_ url: URL, directory: Bool) {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                let hasExpectedType = directory ? values.isDirectory == true : values.isRegularFile == true
                if hasExpectedType && isUnaliased(url) {
                    result.insert(url.standardizedFileURL)
                }
            } catch {
                reportReadError(error, at: url)
            }
        }

        func contents(of directory: URL) -> [URL] {
            guard isUnaliased(directory) else { return [] }
            do {
                return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            } catch {
                reportReadError(error, at: directory)
                return []
            }
        }

        let libraries = [userLibrary, localLibrary].compactMap { $0 }
        for library in libraries {
            for directory in ["Application Support", "Caches", "Logs"] {
                add(library.appendingPathComponent("\(directory)/\(identifier)"), directory: true)
            }
            add(library.appendingPathComponent("Preferences/\(identifier).plist"), directory: false)
        }
        for directory in ["Application Scripts", "HTTPStorages", "WebKit"] {
            add(userLibrary.appendingPathComponent("\(directory)/\(identifier)"), directory: true)
        }
        add(userLibrary.appendingPathComponent("Saved Application State/\(identifier).savedState"), directory: true)
        add(userLibrary.appendingPathComponent("Cookies/\(identifier).binarycookies"), directory: false)
        add(userLibrary.appendingPathComponent("HTTPStorages/\(identifier).binarycookies"), directory: false)

        var containerOwners: Set<String> = [identifier]
        var byHostOwners: Set<String> = [identifier]
        if let appBundle {
            if let bundle = Bundle(url: appBundle), bundle.bundleIdentifier == identifier {
                let sparkle = appBundle.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
                if let domain = bundle.infoDictionary?["SUDefaultsDomain"] as? String,
                   domain.hasPrefix(identifier + "."), isValidPreferenceIdentifier(domain),
                   isUnaliased(sparkle), (try? sparkle.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    add(userLibrary.appendingPathComponent("Preferences/\(domain).plist"), directory: false)
                }

                for library in libraries {
                    let reports = library.appendingPathComponent("Logs/DiagnosticReports")
                    for report in contents(of: reports) where report.pathExtension == "diag" && isUnaliased(report) {
                        do {
                            guard try report.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                                  try diagnosticReportBelongsToBundle(report, appBundle: appBundle) else { continue }
                            add(report, directory: false)
                        } catch {
                            reportReadError(error, at: report)
                        }
                    }
                }
            }

            let plugins = appBundle.appendingPathComponent("Contents/PlugIns")
            for plugin in contents(of: plugins) where plugin.pathExtension == "appex" {
                let info = plugin.appendingPathComponent("Contents/Info.plist")
                guard isUnaliased(info) else { continue }
                do {
                    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
                    if let values = plist as? [String: Any],
                       let extensionID = values["CFBundleIdentifier"] as? String,
                       extensionID.hasPrefix(identifier + "."), extensionID.count > identifier.count + 1,
                       let extensionInfo = values["NSExtension"] as? [String: Any],
                       let point = extensionInfo["NSExtensionPointIdentifier"] as? String, !point.isEmpty {
                        containerOwners.insert(extensionID)
                    }
                } catch {
                    reportReadError(error, at: info)
                }
            }

            if let rule = publishedDataDirectories[identifier],
               matchesPublisher(appBundle, identifier: identifier, team: rule.team) {
                let home = userLibrary.deletingLastPathComponent()
                for path in rule.directories {
                    add(home.appendingPathComponent(path), directory: true)
                }
                add(userLibrary.appendingPathComponent("Caches/\(identifier).ShipIt"), directory: true)
                add(userLibrary.appendingPathComponent("Preferences/\(identifier).helper.plist"), directory: false)
                if rule.hasNamespacedShipItPreferences {
                    byHostOwners.insert(identifier + ".ShipIt")
                }
            }
        }

        let byHost = userLibrary.appendingPathComponent("Preferences/ByHost")
        for file in contents(of: byHost) where file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let separator = name.lastIndex(of: ".") else { continue }
            let owner = name[..<separator]
            let host = name[name.index(after: separator)...]
            if byHostOwners.contains(String(owner)), UUID(uuidString: String(host)) != nil {
                add(file, directory: false)
            }
        }

        let containers = userLibrary.appendingPathComponent("Containers")
        for directory in contents(of: containers) {
            let name = directory.lastPathComponent
            let isUUID = UUID(uuidString: name) != nil
            guard containerOwners.contains(name) || isUUID, isUnaliased(directory) else { continue }
            let metadata = directory.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            guard isUnaliased(metadata) else { continue }
            do {
                let contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: metadata), format: nil)
                if let owner = (contents as? [String: Any])?["MCMMetadataIdentifier"] as? String,
                   containerOwners.contains(owner), isUUID || name == owner {
                    add(directory, directory: true)
                }
            } catch {
                reportReadError(error, at: metadata)
            }
        }
        return result
    }

    private static func isValidPreferenceIdentifier(_ identifier: String) -> Bool {
        let labels = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let validCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(validCharacters.contains) }
    }

    private static func diagnosticReportBelongsToBundle(_ report: URL, appBundle: URL) throws -> Bool {
        // A macOS .diag header records the executable's path and identifier before the event details.
        let file = try FileHandle(forReadingFrom: report)
        defer { try? file.close() }
        guard let prefix = try file.read(upToCount: 32 * 1024) else { return false }
        let lines = String(decoding: prefix, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.first?.hasPrefix("Date/Time:") == true,
              let eventIndex = lines.firstIndex(where: { $0.hasPrefix("Event:") }) else { return false }
        let header = lines[..<eventIndex]
        let paths = header.filter { $0.hasPrefix("Path:") }
        let identifiers = header.filter { $0.hasPrefix("Identifier:") }
        guard paths.count == 1, identifiers.count == 1 else { return false }
        let processPath = paths[0].dropFirst("Path:".count).trimmingCharacters(in: .whitespaces)
        let identifier = identifiers[0].dropFirst("Identifier:".count).trimmingCharacters(in: .whitespaces)
        let appPath = appBundle.standardizedFileURL.path
        guard processPath.hasPrefix(appPath + "/Contents/"), !identifier.isEmpty else { return false }

        let executable = URL(fileURLWithPath: processPath).standardizedFileURL
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let processBundle = contents.deletingLastPathComponent()
        guard executable.path == processPath, macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              processBundle.pathExtension == "app", isUnaliased(executable),
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let bundle = Bundle(url: processBundle), bundle.bundleIdentifier == identifier else { return false }
        return bundle.infoDictionary?["CFBundleExecutable"] as? String == executable.lastPathComponent
    }

    // Microsoft and Discord document these product-specific data directories.
    // The local extensions directory and ShipIt paths also appear in the cask manifests.
    private static let publishedDataDirectories: [String: (team: String, directories: [String], hasNamespacedShipItPreferences: Bool)] = [
        "com.microsoft.VSCode": ("UBF8T346G9", ["Library/Application Support/Code", ".vscode"], true),
        "com.microsoft.VSCodeInsiders": ("UBF8T346G9", ["Library/Application Support/Code - Insiders", ".vscode-insiders"], true),
        "com.hnc.Discord": ("53Q6R32WPB", ["Library/Application Support/discord"], false)
    ]

    private static func matchesPublisher(_ bundle: URL, identifier: String, team: String) -> Bool {
        let expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
              let code else { return false }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSDoNotValidateResources)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    static func isUnaliased(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return url.resolvingSymlinksInPath().path == url.path
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    private static let sensitiveLibraryDirectories: Set<String> = [
        "application scripts",
        "application support",
        "caches",
        "containers",
        "group containers",
        "preferences",
        "saved application state"
    ]

    static func isProtected(
        _ url: URL,
        targetBundleIdentifier: String? = nil,
        entitlementIdentifiers: [String] = []
    ) -> Bool {
        guard let identifier = libraryIdentifier(for: url) else { return false }
        let normalizedIdentifier = identifier.lowercased()

        guard isSystemIdentifier(normalizedIdentifier) else { return false }

        let allowedIdentifiers = ([targetBundleIdentifier].compactMap { $0 } + entitlementIdentifiers)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0 != "-" }

        return !allowedIdentifiers.contains {
            normalizedIdentifier == $0 ||
            normalizedIdentifier.hasPrefix($0 + ".") ||
            normalizedIdentifier.hasPrefix($0 + "-")
        }
    }

    private static func libraryIdentifier(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard let libraryIndex = components.lastIndex(where: { $0.caseInsensitiveCompare("Library") == .orderedSame }),
              components.indices.contains(libraryIndex + 2) else {
            return nil
        }

        let directory = components[libraryIndex + 1].lowercased()
        guard sensitiveLibraryDirectories.contains(directory) else { return nil }

        let item = components[libraryIndex + 2]
        if directory == "preferences" {
            return URL(fileURLWithPath: item).deletingPathExtension().lastPathComponent
        }
        return item
    }

    private static func isSystemIdentifier(_ identifier: String) -> Bool {
        identifier == "com.apple" ||
        identifier.hasPrefix("com.apple.") ||
        identifier == "group.com.apple" ||
        identifier.hasPrefix("group.com.apple.") ||
        identifier == "group.is.workflow" ||
        identifier.hasPrefix("group.is.workflow.")
    }
}
