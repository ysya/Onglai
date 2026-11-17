//
//  Models.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 10/13/25.
//

import Foundation
import Darwin
import SwiftUI
import Sparkle

enum UpdateSource: String, CaseIterable {
    case homebrew = "Homebrew"
    case appStore = "App Store"
    case sparkle = "Sparkle"
    case electron = "Electron"
    case official = "Official Updates"
    case catalog = "Homebrew Catalog"
    case managed = "Self-Updating"
    case unsupported = "Unsupported"
    case current = "Current"

    var icon: String {
        switch self {
        case .homebrew:
            return "🍺"
        case .appStore:
            return "􀎶"
        case .sparkle:
            return "✨"
        case .electron:
            return "⚡️"
        case .official:
            return "🌐"
        case .catalog:
            return "📚"
        case .managed:
            return "↗️"
        case .unsupported:
            return "❓"
        case .current:
            return "✓"
        }
    }

    var title: String { String(localized: String.LocalizationValue(rawValue)) }

    var isExternalUpdate: Bool {
        self == .electron || self == .official || self == .catalog
    }
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case downloading
    case extracting
    case installing
    case verifying
    case completed
    case failed(String)

    static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.checking, .checking),
             (.downloading, .downloading),
             (.extracting, .extracting),
             (.installing, .installing),
             (.verifying, .verifying),
             (.completed, .completed):
            return true
        case (.failed(let lhsMsg), .failed(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// A source check must distinguish a confirmed current app from one that could
/// not be checked. Treating both as "no update" makes network and feed errors
/// look like a successful, up-to-date result.
enum UpdateCheckIssueKind: Sendable, Hashable {
    case failed
    case unavailable
}

struct UpdateCheckFailure: Sendable {
    let appPath: URL
    let appName: String
    let message: String
    var kind: UpdateCheckIssueKind = .failed
}

struct UpdateCheckResults {
    var updates: [UpdateableApp] = []
    var currentAppPaths: Set<URL> = []
    var failures: [UpdateCheckFailure] = []

    mutating func merge(_ other: UpdateCheckResults) {
        updates.append(contentsOf: other.updates)
        currentAppPaths.formUnion(other.currentAppPaths)
        failures.append(contentsOf: other.failures)
    }
}

struct UpdateableApp: Identifiable, Hashable {
    let id = UUID()
    let appInfo: AppInfo
    var availableVersion: String?
    var availableBuildNumber: String?  // Remote build number (CFBundleVersion) for smart version display
    let source: UpdateSource
    let adamID: UInt64?
    let appStoreURL: String?  // Store URL from iTunes API for "Open in App Store" button
    var externalURL: String? = nil  // Official website offered separately from opening the installed app
    var nativeArtifact: NativeUpdateArtifact? = nil
    var status: UpdateStatus = .idle
    var progress: Double = 0.0
    var isSelectedForUpdate: Bool = true  // Default to selected for "Update All" queue

    // Sparkle/App Store metadata (optional)
    let releaseTitle: String?
    let releaseDescription: String?
    let releaseNotesLink: String?  // URL to external release notes page
    let releaseDate: String?
    let isPreRelease: Bool  // True for Sparkle pre-release updates (has channel tag or SemVer pre-release identifier)
    let isIOSApp: Bool  // True for wrapped iPad/iOS apps that must be updated via App Store app
    let foundInRegion: String?  // App Store region code where update was found (e.g., "US", "CN")
    var fetchedReleaseNotes: String?  // Fetched content from external releaseNotesLink URL

    // Cached Sparkle appcast item (for consistent version selection between check and install)
    let appcastItem: SUAppcastItem?

    var canUpdate: Bool {
        source == .homebrew || source == .sparkle || canInstallNatively
    }

    /// Source ownership and target shape are checked again by the installer before replacement.
    var canInstallNatively: Bool {
        guard geteuid() != 0 else { return false }
        let target = appInfo.path.standardizedFileURL.resolvingSymlinksInPath()
        let path = target.path
        guard source.isExternalUpdate, nativeArtifact != nil, target.isFileURL,
              target.pathExtension.lowercased() == "app", !appInfo.bundleIdentifier.isEmpty,
              !appInfo.webApp, !appInfo.wrapped, !appInfo.isAppStore, !isIOSApp,
              appInfo.cask == nil, !appInfo.steam,
              appInfo.bundleIdentifier != Bundle.main.bundleIdentifier,
              target != Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath(),
              !["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/opt", "/Volumes"].contains(where: {
                  path == $0 || path.hasPrefix($0 + "/")
              }),
              !path.hasPrefix("/Applications/Utilities/"),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              !FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/_MASReceipt/receipt").path) else { return false }
        // An app nested inside another bundle is not a standalone replaceable target.
        var parent = target.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension.lowercased() == "app" { return false }
            parent.deleteLastPathComponent()
        }
        return true
    }

    var officialUpdateURL: URL? {
        guard source.isExternalUpdate, let externalURL,
              let url = URL(string: externalURL),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              host.lowercased() != "formulae.brew.sh" else { return nil }
        return url
    }

    /// Unique identifier for tracking hidden apps
    var uniqueIdentifier: String {
        appInfo.bundleIdentifier
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: UpdateableApp, rhs: UpdateableApp) -> Bool {
        lhs.id == rhs.id
    }
}

enum UpdaterItemSection: String {
    case available
    case external
    case attention
    case unverified
    case current
    case managed
    case unsupported
}

struct UpdaterSourceIssue: Hashable {
    let source: UpdateSource
    let message: String
    var kind: UpdateCheckIssueKind = .failed
}

/// A single app-centric row in the updater. An app may be reported by more
/// than one source, but should only occupy one place in the interface.
struct UpdaterListItem: Identifiable, Hashable {
    let id: String
    let section: UpdaterItemSection
    let appInfo: AppInfo?
    let primaryApp: UpdateableApp?
    let alternateApps: [UpdateableApp]
    let issues: [UpdaterSourceIssue]

    var appName: String {
        appInfo?.appName ?? primaryApp?.appInfo.appName ?? String(localized: "Apps")
    }

    var sources: [UpdateSource] {
        if !issues.isEmpty {
            return issues.map(\.source)
        }

        let allSources = [primaryApp?.source].compactMap { $0 } + alternateApps.map(\.source)
        return Array(Set(allSources)).sorted { $0.rawValue < $1.rawValue }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: UpdaterListItem, rhs: UpdaterListItem) -> Bool {
        lhs.id == rhs.id
    }
}

// Conform to FuzzySearchable for automatic fuzzy search support in GenericSidebarListView
extension UpdateableApp: FuzzySearchable {
    var searchableString: String {
        return appInfo.appName
    }
}

extension UpdaterListItem: FuzzySearchable {
    var searchableString: String {
        appName
    }
}
