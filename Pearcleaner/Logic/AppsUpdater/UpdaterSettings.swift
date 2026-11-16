//
//  UpdaterSettings.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/21/25.
//

import Foundation

// MARK: - AppStorage Codable Helper Protocol

/// Protocol for types that can be stored in AppStorage as Data
protocol AppStorageCodable: Codable {
    init()
    static func decode(from data: Data) -> Self
    func encode() -> Data
    static func defaultEncoded() -> Data
}

/// Default implementation for all AppStorageCodable types
extension AppStorageCodable {
    /// Decode from Data with fallback to default
    static func decode(from data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    /// Encode to Data with fallback to empty
    func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Default encoded value for AppStorage initialization
    static func defaultEncoded() -> Data {
        Self().encode()
    }
}

// MARK: - Sources Settings
struct UpdaterSourcesSettings: AppStorageCodable {
    var homebrew: HomebrewSettings = HomebrewSettings()
    var sparkle: SparkleSettings = SparkleSettings()
    var appStore: AppStoreSettings = AppStoreSettings()
    var electron: ElectronSettings = ElectronSettings()
    var official = AdditionalSourceSettings()
    var catalog = AdditionalSourceSettings()

    var enabledSources: Set<UpdateSource> {
        var enabled: Set<UpdateSource> = []
        if homebrew.enabled { enabled.insert(.homebrew) }
        if sparkle.enabled { enabled.insert(.sparkle) }
        if appStore.enabled { enabled.insert(.appStore) }
        if electron.enabled { enabled.insert(.electron) }
        if official.enabled { enabled.insert(.official) }
        if catalog.enabled { enabled.insert(.catalog) }
        return enabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homebrew = try container.decodeIfPresent(HomebrewSettings.self, forKey: .homebrew) ?? HomebrewSettings()
        sparkle = try container.decodeIfPresent(SparkleSettings.self, forKey: .sparkle) ?? SparkleSettings()
        appStore = try container.decodeIfPresent(AppStoreSettings.self, forKey: .appStore) ?? AppStoreSettings()
        electron = try container.decodeIfPresent(ElectronSettings.self, forKey: .electron) ?? ElectronSettings()
        official = try container.decodeIfPresent(AdditionalSourceSettings.self, forKey: .official) ?? AdditionalSourceSettings()
        catalog = try container.decodeIfPresent(AdditionalSourceSettings.self, forKey: .catalog) ?? AdditionalSourceSettings()
    }

    struct HomebrewSettings: Codable {
        var enabled: Bool = true
        var showAutoUpdates: Bool = true
    }

    struct SparkleSettings: Codable {
        var enabled: Bool = true
        var includePreReleases: Bool = false
    }

    struct AppStoreSettings: Codable {
        var enabled: Bool = true
    }

    struct ElectronSettings: Codable {
        var enabled: Bool = true
    }

    struct AdditionalSourceSettings: Codable {
        var enabled: Bool = true
    }
}

// MARK: - Display Settings
struct UpdaterDisplaySettings: AppStorageCodable {
    var showUnsupported: Bool = true
    var showCurrent: Bool = true
    var showManaged: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showUnsupported = try container.decodeIfPresent(Bool.self, forKey: .showUnsupported) ?? true
        showCurrent = try container.decodeIfPresent(Bool.self, forKey: .showCurrent) ?? true
        showManaged = try container.decodeIfPresent(Bool.self, forKey: .showManaged) ?? true
    }
}
