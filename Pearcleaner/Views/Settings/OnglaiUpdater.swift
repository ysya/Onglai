//
//  OnglaiUpdater.swift
//  Pearcleaner
//
//  Secure self-updater for Onglai releases.
//

import Foundation
import Sparkle
import SwiftUI

enum OnglaiUpdateFrequency: String, CaseIterable, Codable, Identifiable {
    case daily
    case weekly
    case monthly
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .never: return "Never"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        case .never: return nil
        }
    }

    init(legacyValue: String?) {
        switch legacyValue?.lowercased() {
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "never", "none": self = .never
        default: self = .daily
        }
    }
}

enum OnglaiUpdateState: Equatable {
    case idle
    case checking
    case current
    case available
    case failed(String)
}

enum OnglaiUpdateChannel: String {
    case stable
    case beta

    var releasesURL: URL {
        let base = URL(string: "https://api.github.com/repos/ysya/Onglai/releases")!
        switch self {
        case .stable: return base.appendingPathComponent("latest")
        case .beta: return base.appending(queryItems: [URLQueryItem(name: "per_page", value: "50")])
        }
    }

    var sparkleChannels: Set<String> { self == .beta ? ["beta"] : [] }

    func preferredRelease(in releases: [OnglaiRelease]) -> OnglaiRelease? {
        releases.filter { release in
            guard let releaseChannel = release.channel else { return false }
            return releaseChannel == .stable || self == .beta
        }.max {
            UpdateVersionComparator.compare(installed: $0.version, available: $1.version) == .orderedAscending
        }
    }

    static func installedVersion(marketingVersion: String, releaseTag: String?) -> String {
        guard let releaseTag, releaseTag.hasPrefix(marketingVersion + "-beta."),
              tagChannel(releaseTag) == .beta else { return marketingVersion }
        return releaseTag
    }

    fileprivate static func tagChannel(_ tag: String) -> Self? {
        guard tag.range(of: #"^[vV]?[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[0-9]+)?\z"#, options: .regularExpression) != nil else {
            return nil
        }
        return tag.contains("-beta.") ? .beta : .stable
    }
}

struct OnglaiRelease: Codable, Identifiable, Equatable {
    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Codable, Equatable {
        let name: String
        let state: String
    }

    var version: String {
        tagName.first == "v" || tagName.first == "V" ? String(tagName.dropFirst()) : tagName
    }

    var channel: OnglaiUpdateChannel? {
        guard !draft, publishedAt != nil,
              assets.contains(where: { $0.name == "appcast.xml" && $0.state == "uploaded" }),
              let tagChannel = OnglaiUpdateChannel.tagChannel(tagName),
              prerelease == (tagChannel == .beta) else { return nil }
        return tagChannel
    }

    var appcastURL: URL? {
        guard channel != nil else { return nil }
        return URL(string: "https://github.com/ysya/Onglai/releases/download/\(tagName)/appcast.xml")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }
}

@MainActor
final class OnglaiSparkleDelegate: NSObject, SPUUpdaterDelegate {
    var channel: OnglaiUpdateChannel = .stable
    var betaFeed: URL?

    func feedURLString(for updater: SPUUpdater) -> String? {
        if channel == .beta, let betaFeed { return betaFeed.absoluteString }
        return updater.hostBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.sparkleChannels
    }
}

@MainActor
final class OnglaiUpdater: ObservableObject {
    static let shared = OnglaiUpdater()

    @Published private(set) var state: OnglaiUpdateState = .idle
    @Published private(set) var latestRelease: OnglaiRelease?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var channel: OnglaiUpdateChannel
    @Published var frequency: OnglaiUpdateFrequency {
        didSet {
            defaults.set(frequency.rawValue, forKey: Keys.frequency)
            if didStartSparkle { applyUpdateSchedule() }
        }
    }

    let currentVersion: String
    var latestVersion: String? { latestRelease?.version }

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return UpdateVersionComparator.compare(installed: currentVersion, available: latestVersion) == .orderedAscending
    }

    private enum Keys {
        static let frequency = "onglai.updater.frequency"
        static let channel = "onglai.updater.channel"
        static let legacyFrequency = "alinfoundation.updater.updateFrequency"
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case noPublishedRelease
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "GitHub returned an invalid response."
            case .noPublishedRelease:
                return "No published Onglai release with an update feed was found."
            case .rateLimited:
                return "GitHub temporarily limited update checks. Please try again later."
            }
        }
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let sparkleController: SPUStandardUpdaterController
    private let sparkleDelegate: OnglaiSparkleDelegate
    private var lastSuccessfulCheck: Date?
    private var activeCheckID: UUID?
    private var betaCheckTimer: Timer?
    private var didStartSparkle = false

    private var cachedReleaseKey: String { "onglai.updater.cachedRelease.\(channel.rawValue)" }
    private var lastSuccessfulCheckKey: String { "onglai.updater.lastSuccessfulCheck.\(channel.rawValue)" }

    private init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        let version = OnglaiUpdateChannel.installedVersion(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            releaseTag: Bundle.main.object(forInfoDictionaryKey: "OnglaiReleaseVersion") as? String
        )
        self.currentVersion = version
        self.channel = defaults.string(forKey: Keys.channel).flatMap(OnglaiUpdateChannel.init(rawValue:))
            ?? OnglaiUpdateChannel.tagChannel(version) ?? .stable
        let delegate = OnglaiSparkleDelegate()
        self.sparkleDelegate = delegate
        self.sparkleController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        if let storedFrequency = defaults.string(forKey: Keys.frequency),
           let frequency = OnglaiUpdateFrequency(rawValue: storedFrequency) {
            self.frequency = frequency
        } else {
            self.frequency = OnglaiUpdateFrequency(
                legacyValue: defaults.string(forKey: Keys.legacyFrequency)
            )
        }

        restoreCachedRelease()
    }

    func selectChannel(_ channel: OnglaiUpdateChannel) {
        guard channel != self.channel, !sparkleController.updater.sessionInProgress else { return }
        self.channel = channel
        defaults.set(channel.rawValue, forKey: Keys.channel)
        activeCheckID = nil
        restoreCachedRelease()
        if didStartSparkle { applyUpdateSchedule() }
        Task { await checkForUpdates() }
    }

    private func restoreCachedRelease() {
        let cachedRelease = defaults.data(forKey: cachedReleaseKey).flatMap {
            try? JSONDecoder.onglai.decode(OnglaiRelease.self, from: $0)
        }
        latestRelease = cachedRelease.flatMap { channel.preferredRelease(in: [$0]) }
        let storedCheck = defaults.double(forKey: lastSuccessfulCheckKey)
        lastSuccessfulCheck = latestRelease != nil && storedCheck > 0
            ? Date(timeIntervalSinceReferenceDate: storedCheck) : nil
        lastChecked = lastSuccessfulCheck
        sparkleDelegate.channel = channel
        sparkleDelegate.betaFeed = channel == .beta ? latestRelease?.appcastURL : nil
        state = latestRelease == nil ? .idle : (updateAvailable ? .available : .current)
    }

    func checkIfNeeded() async {
        startSparkleIfNeeded()
        guard let interval = frequency.interval else { return }

        if let lastSuccessfulCheck,
           Date().timeIntervalSince(lastSuccessfulCheck) < interval {
            return
        }

        await checkForUpdates()
    }

    func checkForUpdates() async {
        // A development host must never install the production app over itself.
        guard !OnglaiIdentity.isDebug else { return }
        startSparkleIfNeeded()
        guard activeCheckID == nil else { return }
        let checkID = UUID()
        let checkingChannel = channel
        activeCheckID = checkID
        defer {
            if activeCheckID == checkID { activeCheckID = nil }
        }

        state = .checking
        lastChecked = Date()

        do {
            var request = URLRequest(url: checkingChannel.releasesURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Onglai/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard activeCheckID == checkID else { return }
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                break
            case 403, 429:
                throw UpdateError.rateLimited
            case 404:
                throw UpdateError.noPublishedRelease
            default:
                throw UpdateError.invalidResponse
            }

            let decoder = JSONDecoder.onglai
            let releases = checkingChannel == .beta
                ? try decoder.decode([OnglaiRelease].self, from: data)
                : [try decoder.decode(OnglaiRelease.self, from: data)]
            guard let release = checkingChannel.preferredRelease(in: releases) else { throw UpdateError.noPublishedRelease }

            latestRelease = release
            sparkleDelegate.betaFeed = checkingChannel == .beta ? release.appcastURL : nil
            lastSuccessfulCheck = lastChecked
            state = updateAvailable ? .available : .current

            if let lastChecked {
                defaults.set(lastChecked.timeIntervalSinceReferenceDate, forKey: lastSuccessfulCheckKey)
            }
            if let encodedRelease = try? JSONEncoder().encode(release) {
                defaults.set(encodedRelease, forKey: cachedReleaseKey)
            }

            if checkingChannel == .stable, updateAvailable,
               frequency != .never, sparkleController.updater.canCheckForUpdates {
                sparkleController.updater.checkForUpdatesInBackground()
            }
        } catch is CancellationError {
            guard activeCheckID == checkID else { return }
            state = latestRelease == nil ? .idle : (updateAvailable ? .available : .current)
        } catch {
            guard activeCheckID == checkID else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func installLatestRelease() {
        guard !OnglaiIdentity.isDebug, updateAvailable else { return }
        startSparkleIfNeeded()
        sparkleController.checkForUpdates(nil)
    }

    private func startSparkleIfNeeded() {
        guard !OnglaiIdentity.isDebug, !didStartSparkle else { return }
        didStartSparkle = true
        sparkleController.startUpdater()
        applyUpdateSchedule()
    }

    private func applyUpdateSchedule() {
        betaCheckTimer?.invalidate()
        betaCheckTimer = nil
        let sparkleUpdater = sparkleController.updater
        let interval = frequency.interval
        sparkleUpdater.automaticallyChecksForUpdates = channel == .stable && interval != nil
        guard let interval else { return }
        if channel == .stable {
            sparkleUpdater.updateCheckInterval = interval
            return
        }

        // Refresh the release list before offering a tag-specific appcast to Sparkle.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.channel == .beta, self.frequency != .never else { return }
                await self.checkIfNeeded()
            }
        }
        if let lastSuccessfulCheck {
            timer.fireDate = max(Date(), lastSuccessfulCheck.addingTimeInterval(interval))
        }
        timer.tolerance = min(interval * 0.1, 60)
        RunLoop.main.add(timer, forMode: .common)
        betaCheckTimer = timer
    }
}

private extension JSONDecoder {
    static var onglai: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
