import Foundation
import Darwin

/// Read-only checks of explicitly verified vendor endpoints. These results only
/// open official landing pages; they never download installers or adopt feeds.
enum OfficialUpdateChecker {
    typealias DocumentLoader = (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    private static let maximumBytes = 2 * 1024 * 1024

    private enum Kind {
        case json(String), termius, linear, proton, jetbrains(String), studio, chrome, brave
        case github(String, String)
    }

    private struct Profile {
        let kind: Kind
        let page: String
        var usesBuild: Bool {
            switch kind {
            case .studio, .brave, .jetbrains("TBA"): return true
            default: return false
            }
        }
    }

    // Bundle IDs are exact. Unverified channels and publisher-prefix matches are
    // intentionally excluded. The URLs below are public vendor metadata feeds.
    private static let profiles: [String: Profile] = [
        "com.microsoft.VSCode": Profile(kind: .json("productVersion"), page: "https://code.visualstudio.com/download"),
        "com.todesktop.230313mzl4w4u92": Profile(kind: .json("name"), page: "https://cursor.com/download"),
        "com.hnc.Discord": Profile(kind: .json("name"), page: "https://discord.com/download"),
        "com.anthropic.claudefordesktop": Profile(kind: .json("version"), page: "https://claude.com/download"),
        "com.postmanlabs.mac": Profile(kind: .json("version"), page: "https://www.postman.com/downloads/"),
        "com.termius-dmg.mac": Profile(kind: .termius, page: "https://termius.com/download/macos"),
        "com.linear": Profile(kind: .linear, page: "https://linear.app/download"),
        "me.proton.pass.electron": Profile(kind: .proton, page: "https://proton.me/pass/download"),
        "com.jetbrains.rider": Profile(kind: .jetbrains("RD"), page: "https://www.jetbrains.com/rider/download/"),
        "com.jetbrains.toolbox": Profile(kind: .jetbrains("TBA"), page: "https://www.jetbrains.com/toolbox-app/"),
        "com.google.android.studio": Profile(kind: .studio, page: "https://developer.android.com/studio"),
        "com.google.Chrome": Profile(kind: .chrome, page: "https://www.google.com/chrome/"),
        "com.brave.Browser": Profile(kind: .brave, page: "https://brave.com/download/"),
        "md.obsidian": Profile(kind: .github("obsidianmd", "obsidian-releases"), page: "https://obsidian.md/download"),
        "app.freelens.Freelens": Profile(kind: .github("freelensapp", "freelens"), page: "https://github.com/freelensapp/freelens/releases"),
        "com.carriez.rustdesk": Profile(kind: .github("rustdesk", "rustdesk"), page: "https://github.com/rustdesk/rustdesk/releases"),
        "com.utmapp.UTM": Profile(kind: .github("utmapp", "UTM"), page: "https://github.com/utmapp/UTM/releases"),
        "info.marcel-dierkes.KeepingYouAwake": Profile(kind: .github("newmarcel", "KeepingYouAwake"), page: "https://github.com/newmarcel/KeepingYouAwake/releases")
    ]

    static func isEligible(_ app: AppInfo) -> Bool {
        !app.isAppStore && !app.webApp && !app.wrapped && profiles[app.bundleIdentifier] != nil
    }

    static func checkForUpdates(apps: [AppInfo]) async -> UpdateCheckResults {
        await checkForUpdates(apps: apps, documentLoader: { request, limit in
            try await UpdateHTTPClient.response(for: request, maximumBytes: limit)
        })
    }

    private enum SingleResult: @unchecked Sendable {
        case update(UpdateableApp)
        case current(URL)
        case failure(UpdateCheckFailure)
    }

    // These update-service/Squirrel contracts explicitly use 204 for no update.
    // A missing body from other document endpoints is not evidence of currency.
    private static let conditionalNoUpdateBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.hnc.Discord"
    ]

    static func checkForUpdates(apps: [AppInfo], documentLoader: @escaping DocumentLoader) async -> UpdateCheckResults {
        var results = UpdateCheckResults()
        let eligible = apps.filter(isEligible)
        // Limit simultaneous vendor requests and preserve input order even when
        // one endpoint responds more slowly than its neighbours.
        for start in stride(from: 0, to: eligible.count, by: 4) {
            if Task.isCancelled { break }
            let end = min(start + 4, eligible.count)
            let batch = await withTaskGroup(of: (Int, SingleResult).self) { group in
                for index in start..<end {
                    let app = eligible[index]
                    group.addTask {
                        (index, await check(app: app, documentLoader: documentLoader))
                    }
                }
                var outcomes: [(Int, SingleResult)] = []
                for await outcome in group { outcomes.append(outcome) }
                return outcomes.sorted { $0.0 < $1.0 }
            }
            for (_, outcome) in batch {
                switch outcome {
                case .update(let app): results.updates.append(app)
                case .current(let path): results.currentAppPaths.insert(path)
                case .failure(let failure): results.failures.append(failure)
                }
            }
        }
        return results
    }

    private static func check(app: AppInfo, documentLoader: DocumentLoader) async -> SingleResult {
        guard let profile = profiles[app.bundleIdentifier] else {
            return .failure(UpdateCheckFailure(appPath: app.path, appName: app.appName,
                                              message: CheckError.invalidProduct.localizedDescription))
        }
        do {
            try validateInstalledChannel(app)
            let request = try request(for: app, profile: profile)
            let (data, response) = try await documentLoader(request, maximumBytes)
            guard data.count <= maximumBytes,
                  response.url?.scheme == "https",
                  response.url?.host?.lowercased() == request.url?.host?.lowercased() else {
                throw CheckError.invalidResponse
            }
            if response.statusCode == 204, conditionalNoUpdateBundleIDs.contains(app.bundleIdentifier) {
                return .current(app.path)
            }
            guard response.statusCode == 200 else { throw CheckError.http(response.statusCode) }
            let release = try parse(data, response: response, profile: profile, installedApp: app)
            let installed = profile.usesBuild ? normalizedBuild(app.appBuildNumber) : app.appVersion
            guard let comparison = UpdateVersionComparator.compare(installed: installed, available: release.comparisonVersion) else {
                throw CheckError.invalidVersion
            }
            if comparison == .orderedAscending {
                return .update(UpdateableApp(
                    appInfo: app, availableVersion: release.version, availableBuildNumber: release.build,
                    source: .official, adamID: nil, appStoreURL: nil, externalURL: profile.page, isSelectedForUpdate: false,
                    releaseTitle: nil, releaseDescription: nil, releaseNotesLink: nil, releaseDate: nil,
                    isPreRelease: false, isIOSApp: false, foundInRegion: nil,
                    fetchedReleaseNotes: nil, appcastItem: nil
                ))
            } else {
                return .current(app.path)
            }
        } catch {
            return .failure(UpdateCheckFailure(appPath: app.path, appName: app.appName,
                                              message: error.localizedDescription))
        }
    }

    private static func request(for app: AppInfo, profile: Profile) throws -> URLRequest {
        let arm: Bool
        switch app.arch {
        case .arm: arm = true
        case .intel: arm = false
        case .universal, .empty:
            #if arch(arm64)
            arm = true
            #else
            arm = false
            #endif
        }
        let asset = arm ? "darwin-arm64" : "darwin"
        let endpoint: String
        switch profile.kind {
        case .json:
            switch app.bundleIdentifier {
            case "com.microsoft.VSCode": endpoint = "https://update.code.visualstudio.com/api/update/\(asset)/stable/latest"
            case "com.todesktop.230313mzl4w4u92": endpoint = "https://api2.cursor.sh/updates/api/update/\(asset)/cursor/0.0.1/stable"
            case "com.hnc.Discord": endpoint = "https://discord.com/api/updates/stable?platform=osx"
            case "com.anthropic.claudefordesktop": endpoint = "https://api.anthropic.com/api/desktop/darwin/universal/dmg/latest"
            case "com.postmanlabs.mac": endpoint = "https://dl.pstmn.io/api/version/latest"
            default: throw CheckError.invalidResponse
            }
        case .termius:
            endpoint = "https://autoupdate.termius.com/\(arm ? "mac-arm64" : "mac")/latest-mac.yml"
        case .linear: endpoint = "https://releases.linear.app/mac"
        case .proton: endpoint = "https://proton.me/download/PassDesktop/darwin/universal/version.json"
        case .jetbrains(let code):
            if code == "RD" {
                let metadata = try localJSON(app.path.appendingPathComponent("Contents/Resources/product-info.json"))
                guard metadata["productCode"] as? String == "RD" else { throw CheckError.invalidProduct }
            }
            // Toolbox does not expose a local channel marker. Its full build
            // must occur in the stable release history before we use that feed.
            endpoint = code == "TBA"
                ? "https://data.services.jetbrains.com/products/releases?code=TBA&type=release"
                : "https://data.services.jetbrains.com/products/releases?code=\(code)&latest=true&type=release"
        case .studio: endpoint = "https://dl.google.com/android/studio/patches/updates.xml"
        case .chrome:
            endpoint = "https://versionhistory.googleapis.com/v1/chrome/platforms/\(arm ? "mac_arm64" : "mac")/channels/stable/versions/all/releases?filter=endtime%3Dnone%2Cfraction%3E0&order_by=version%20desc&page_size=1"
        case .brave:
            endpoint = "https://updates.bravesoftware.com/sparkle/Brave-Browser/\(arm ? "stable-arm64" : "stable")/appcast.xml"
        case .github(let owner, let repo):
            endpoint = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        }
        guard let url = URL(string: endpoint) else { throw CheckError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        if case .linear = profile.kind { request.httpMethod = "HEAD" }
        request.setValue("Onglai-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/xml, text/yaml, */*", forHTTPHeaderField: "Accept")
        return request
    }

    private struct Release {
        let version: String
        let build: String?
        let comparisonVersion: String

        init(_ version: String, build: String? = nil, compareBuild: Bool = false) throws {
            guard isNumeric(version), build.map(isNumeric) ?? true else { throw CheckError.invalidVersion }
            self.version = version
            self.build = build
            self.comparisonVersion = compareBuild ? (build ?? "") : version
            guard isNumeric(comparisonVersion) else { throw CheckError.invalidVersion }
        }
    }

    private static func parse(_ data: Data, response: HTTPURLResponse, profile: Profile, installedApp: AppInfo) throws -> Release {
        switch profile.kind {
        case .linear:
            guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
                  let version = capture(#"(?:^|[;\s])filename="?Linear-([0-9]+(?:\.[0-9]+)+)-universal\.dmg"?(?:;|$)"#, disposition) else {
                throw CheckError.invalidResponse
            }
            return try Release(version)
        case .termius:
            guard let text = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
            let values = try yamlScalars(text)
            try checkMinimum(values["minimumSystemVersion"], current: kernelVersion())
            guard let version = values["version"] else { throw CheckError.invalidVersion }
            return try Release(version)
        case .studio, .brave:
            let reader = OfficialXMLReader()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = reader
            guard parser.parse() else { throw CheckError.invalidResponse }
            let candidates: [Release]
            if case .studio = profile.kind {
                candidates = try reader.studioBuilds.map { try Release($0.version, build: $0.build, compareBuild: true) }
            } else {
                candidates = try reader.braveItems.filter { item in
                    guard !item.isPrerelease else { return false }
                    guard let minimum = item.minimumOS else { return true }
                    return isCompatible(minimum, current: macOSVersion())
                }.map { try Release($0.version, build: $0.build, compareBuild: true) }
            }
            return try newest(candidates)
        default: break
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError.invalidResponse
        }
        switch profile.kind {
        case .json(let key):
            guard let version = object[key] as? String else { throw CheckError.invalidVersion }
            try checkMinimum(object["minimumSystemVersion"] as? String, current: macOSVersion())
            return try Release(version)
        case .proton:
            guard let releases = object["Releases"] as? [[String: Any]], !releases.isEmpty else { throw CheckError.invalidResponse }
            // Without the app's cohort ID we can only assert fully released updates.
            let stable = releases.filter { ($0["CategoryName"] as? String) == "Stable" }
            guard !stable.isEmpty else { throw CheckError.invalidResponse }
            let complete = stable.filter { ($0["RolloutPercentage"] as? NSNumber)?.doubleValue == 1 }
            let candidates = try complete.map { entry -> Release in
                guard let version = entry["Version"] as? String else { throw CheckError.invalidVersion }
                return try Release(version)
            }
            return try newest(candidates)
        case .jetbrains(let code):
            guard let releases = object[code] as? [[String: Any]] else { throw CheckError.invalidResponse }
            let candidates = try releases.filter { $0["type"] as? String == "release" }.map { entry -> Release in
                guard let version = entry["version"] as? String, let build = entry["build"] as? String else { throw CheckError.invalidVersion }
                return try Release(version, build: build, compareBuild: code == "TBA")
            }
            if code == "TBA" {
                guard let installedBuild = installedApp.appBuildNumber,
                      candidates.contains(where: { $0.build == installedBuild }) else {
                    throw CheckError.invalidChannel
                }
            }
            return try newest(candidates)
        case .chrome:
            guard let releases = object["releases"] as? [[String: Any]] else { throw CheckError.invalidResponse }
            let active = releases.filter { entry in
                guard let fraction = (entry["fraction"] as? NSNumber)?.doubleValue,
                      fraction > 0, fraction <= 1, let serving = entry["serving"] as? [String: Any],
                      serving["endTime"] == nil, serving["startTime"] as? String != nil else { return false }
                return true
            }
            return try newest(active.map { entry in
                guard let version = entry["version"] as? String else { throw CheckError.invalidVersion }
                return try Release(version)
            })
        case .github(let owner, let repo):
            guard object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
                  let tag = object["tag_name"] as? String,
                  let rawURL = object["html_url"] as? String, let url = URL(string: rawURL),
                  url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil,
                  url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path == "/\(owner)/\(repo)/releases/tag/\(tag)" else { throw CheckError.invalidResponse }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return try Release(version)
        default: throw CheckError.invalidResponse
        }
    }

    private static func validateInstalledChannel(_ app: AppInfo) throws {
        // A valid build alone cannot establish the installed release channel.
        // This also runs before a conditional 204 can confirm the app is current.
        guard UpdateVersionComparator.channel(for: app.appVersion) == "stable" else {
            throw CheckError.invalidChannel
        }
        if app.bundleIdentifier == "com.google.android.studio" {
            let metadata = try localJSON(app.path.appendingPathComponent("Contents/Resources/product-info.json"))
            guard metadata["productCode"] as? String == "AI",
                  metadata["versionSuffix"] as? String == "",
                  let selector = metadata["dataDirectoryName"] as? String,
                  selector.range(of: #"^AndroidStudio[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil,
                  let build = metadata["buildNumber"] as? String,
                  isNumeric(build), build == normalizedBuild(app.appBuildNumber) else {
                throw CheckError.invalidChannel
            }
        }
        guard ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"].contains(app.bundleIdentifier) else { return }
        let url = app.path.appendingPathComponent("Contents/Resources/app/product.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let metadata = try localJSON(url)
        guard metadata["quality"] as? String == "stable" else { throw CheckError.invalidChannel }
    }

    private static func localJSON(_ url: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 512 * 1024,
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CheckError.invalidProduct
        }
        return result
    }

    private static func newest(_ candidates: [Release]) throws -> Release {
        guard var result = candidates.first else { throw CheckError.noCompatibleRelease }
        for candidate in candidates.dropFirst() {
            guard let comparison = UpdateVersionComparator.compare(installed: result.comparisonVersion, available: candidate.comparisonVersion) else {
                throw CheckError.invalidVersion
            }
            if comparison == .orderedAscending { result = candidate }
        }
        return result
    }

    private static func normalizedBuild(_ value: String?) -> String {
        guard let value else { return "" }
        return value.hasPrefix("AI-") ? String(value.dropFirst(3)) : value
    }

    private static func isNumeric(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func capture(_ pattern: String, _ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func yamlScalars(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            guard ["version", "minimumSystemVersion"].contains(key) else { continue }
            guard values[key] == nil else { throw CheckError.invalidResponse }
            values[key] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return values
    }

    private static func checkMinimum(_ minimum: String?, current: String) throws {
        guard let minimum else { return }
        guard isCompatible(minimum, current: current) else { throw CheckError.noCompatibleRelease }
    }

    private static func isCompatible(_ minimum: String, current: String) -> Bool {
        guard isNumeric(minimum),
              let comparison = UpdateVersionComparator.compare(installed: current, available: minimum) else { return false }
        return comparison != .orderedAscending
    }

    private static func macOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func kernelVersion() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        let capacity = MemoryLayout.size(ofValue: info.release)
        return withUnsafePointer(to: &info.release) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private enum CheckError: LocalizedError {
        case invalidResponse, invalidVersion, invalidProduct, invalidChannel, noCompatibleRelease, http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return String(localized: "The official update service returned invalid metadata")
            case .invalidVersion: return String(localized: "The official update version could not be compared")
            case .invalidProduct: return String(localized: "The installed application product metadata could not be verified")
            case .invalidChannel: return String(localized: "This application release channel is not supported")
            case .noCompatibleRelease: return String(localized: "No fully released compatible official update could be verified")
            case .http(let status): return String(localized: "The official update service returned HTTP \(status)")
            }
        }
    }
}

private final class OfficialXMLReader: NSObject, XMLParserDelegate {
    struct StudioBuild { let version: String; let build: String }
    struct BraveItem {
        var version: String = ""
        var build: String = ""
        var minimumOS: String?
        var isPrerelease = false
    }
    var studioBuilds: [StudioBuild] = []
    var braveItems: [BraveItem] = []
    private var stableStudioChannel = false
    private var braveItem: BraveItem?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "channel" { stableStudioChannel = attributeDict["status"] == "release" }
        if elementName == "build", stableStudioChannel,
           let number = attributeDict["number"], number.hasPrefix("AI-"),
           let label = attributeDict["version"],
           let range = label.range(of: #"[0-9]{4}\.[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
            studioBuilds.append(StudioBuild(version: String(label[range]), build: String(number.dropFirst(3))))
        }
        if elementName == "item" { braveItem = BraveItem() }
        if elementName == "enclosure", braveItem != nil {
            braveItem?.version = attributeDict["sparkle:shortVersionString"] ?? ""
            braveItem?.build = attributeDict["sparkle:version"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "channel" { stableStudioChannel = false }
        if elementName == "sparkle:minimumSystemVersion" { braveItem?.minimumOS = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "sparkle:channel" {
            let channel = text.trimmingCharacters(in: .whitespacesAndNewlines)
            braveItem?.isPrerelease = !channel.isEmpty && channel != "stable"
        }
        if elementName == "item", let item = braveItem { braveItems.append(item); braveItem = nil }
        text = ""
    }
}
