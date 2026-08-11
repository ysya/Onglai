//
//  AppGroupDefaults.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 9/30/25.
//

import Foundation

extension UserDefaults {
    // Personal fork: the upstream group ID is registered to alienator88's
    // developer team, so provisioning rejects it for other teams. Team-prefixed
    // groups need no registration on macOS. Keep in sync with both
    // .entitlements files if the signing team ever changes.
    static let appGroup = UserDefaults(suiteName: "VNGFZ627N6.group.pearcleaner")!

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
