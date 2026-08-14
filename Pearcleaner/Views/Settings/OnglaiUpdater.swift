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

struct OnglaiRelease: Codable, Identifiable, Equatable {
    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

@MainActor
final class OnglaiUpdater: ObservableObject {
    static let shared = OnglaiUpdater()

    @Published private(set) var state: OnglaiUpdateState = .idle
    @Published private(set) var latestRelease: OnglaiRelease?
    @Published private(set) var lastChecked: Date?
    @Published var frequency: OnglaiUpdateFrequency {
        didSet {
            defaults.set(frequency.rawValue, forKey: Keys.frequency)
            if didStartSparkle {
                applySparkleSchedule()
            }
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var latestVersion: String? {
        latestRelease.map { Self.normalizedVersion($0.tagName) }
    }

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.isNewer(latestVersion, than: currentVersion)
    }

    private enum Keys {
        static let frequency = "onglai.updater.frequency"
        static let lastSuccessfulCheck = "onglai.updater.lastSuccessfulCheck"
        static let cachedRelease = "onglai.updater.cachedRelease"
        static let legacyFrequency = "alinfoundation.updater.updateFrequency"
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case noPublishedRelease
        case rateLimited
        case invalidVersion

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "GitHub returned an invalid response."
            case .noPublishedRelease:
                return "No published Onglai release was found."
            case .rateLimited:
                return "GitHub temporarily limited update checks. Please try again later."
            case .invalidVersion:
                return "The latest release has an invalid version number."
            }
        }
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let sparkleController: SPUStandardUpdaterController
    private var lastSuccessfulCheck: Date?
    private var didStartSparkle = false

    private init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.sparkleController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
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

        let storedCheck = defaults.double(forKey: Keys.lastSuccessfulCheck)
        if storedCheck > 0 {
            let date = Date(timeIntervalSinceReferenceDate: storedCheck)
            self.lastSuccessfulCheck = date
            self.lastChecked = date
        }

        if let cachedData = defaults.data(forKey: Keys.cachedRelease),
           let cachedRelease = try? JSONDecoder.onglai.decode(OnglaiRelease.self, from: cachedData) {
            self.latestRelease = cachedRelease
            self.state = Self.isNewer(
                Self.normalizedVersion(cachedRelease.tagName),
                than: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            ) ? .available : .current
        }
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
        startSparkleIfNeeded()
        guard state != .checking else { return }
        state = .checking
        lastChecked = Date()

        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/ysya/Onglai/releases/latest")!,
                timeoutInterval: 15
            )
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Onglai/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
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

            let release = try JSONDecoder.onglai.decode(OnglaiRelease.self, from: data)
            let releaseVersion = Self.normalizedVersion(release.tagName)
            let parsedReleaseVersion = Version(versionNumber: releaseVersion, buildNumber: nil)
            guard !parsedReleaseVersion.isEmpty else {
                throw UpdateError.invalidVersion
            }

            latestRelease = release
            lastSuccessfulCheck = lastChecked
            state = Self.isNewer(releaseVersion, than: currentVersion) ? .available : .current

            if let lastChecked {
                defaults.set(lastChecked.timeIntervalSinceReferenceDate, forKey: Keys.lastSuccessfulCheck)
            }
            if let encodedRelease = try? JSONEncoder().encode(release) {
                defaults.set(encodedRelease, forKey: Keys.cachedRelease)
            }

            if updateAvailable,
               frequency != .never,
               sparkleController.updater.canCheckForUpdates {
                sparkleController.updater.checkForUpdatesInBackground()
            }
        } catch is CancellationError {
            state = latestRelease == nil ? .idle : (updateAvailable ? .available : .current)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func installLatestRelease() {
        startSparkleIfNeeded()
        sparkleController.checkForUpdates(nil)
    }

    static func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "v" || trimmed.first == "V" else { return trimmed }
        return String(trimmed.dropFirst())
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let candidateVersion = Version(
            versionNumber: normalizedVersion(candidate),
            buildNumber: nil
        )
        let installedVersion = Version(
            versionNumber: normalizedVersion(installed),
            buildNumber: nil
        )
        return !candidateVersion.isEmpty && !installedVersion.isEmpty && candidateVersion > installedVersion
    }

    private func startSparkleIfNeeded() {
        guard !didStartSparkle else { return }
        didStartSparkle = true
        sparkleController.startUpdater()
        applySparkleSchedule()
    }

    private func applySparkleSchedule() {
        let sparkleUpdater = sparkleController.updater
        if let interval = frequency.interval {
            sparkleUpdater.automaticallyChecksForUpdates = true
            sparkleUpdater.updateCheckInterval = interval
        } else {
            sparkleUpdater.automaticallyChecksForUpdates = false
        }
    }
}

private extension JSONDecoder {
    static var onglai: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
