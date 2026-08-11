//
//  AppGroupDefaults.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 9/30/25.
//

import Foundation

extension UserDefaults {
    private static let appGroupIdentifierKey = "OnglaiAppGroupIdentifier"

    // The identifier is generated from the active signing team and embedded in
    // both the app and Finder extension. This keeps local Development and
    // Developer ID builds on the same suite without hard-coding either team.
    static let appGroup: UserDefaults = {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: appGroupIdentifierKey) as? String,
              !identifier.isEmpty,
              !identifier.contains("$(") else {
            assertionFailure("Missing expanded Onglai app-group identifier")
            return .standard
        }

        return UserDefaults(suiteName: identifier) ?? .standard
    }()

    struct Keys {
        static let showAppIconInMenu = "showAppIconInMenu"
    }

    // Setting for showing app icon in context menu
    static var showAppIconInMenu: Bool {
        get {
            return appGroup.bool(forKey: Keys.showAppIconInMenu)
        }
        set {
            appGroup.set(newValue, forKey: Keys.showAppIconInMenu)
        }
    }
}
