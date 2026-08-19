//
//  ManagedUpdateDetector.swift
//  Pearcleaner
//

import Foundation

struct ManagedUpdateMechanism {
    let title: String
    let description: String
}

enum ManagedUpdateDetector {
    static func mechanism(for app: AppInfo) -> ManagedUpdateMechanism? {
        guard !app.webApp, !app.isAppStore, app.cask == nil else { return nil }

        if ElectronUpdateChecker.hasUpdateMetadata(for: app) {
            if ElectronUpdateChecker.configuration(for: app)?.isCheckable == true {
                return nil
            }
            return ManagedUpdateMechanism(
                title: String(localized: "Electron self-updater"),
                description: String(localized: "This app uses a custom Electron update provider. Open the app to check for and install updates.")
            )
        }

        let bundle = Bundle(url: app.path)
        let information = bundle?.infoDictionary ?? [:]
        let frameworks = app.path.appendingPathComponent("Contents/Frameworks")
        let bundleIdentifier = app.bundleIdentifier.lowercased()

        if FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Squirrel.framework").path) {
            return ManagedUpdateMechanism(
                title: String(localized: "Built-in Electron updater"),
                description: String(localized: "This app uses Squirrel to update itself. Open the app to check for and install updates.")
            )
        }

        if information["KSUpdateURL"] != nil || information["KSProductID"] != nil {
            return ManagedUpdateMechanism(
                title: String(localized: "Google Software Update"),
                description: String(localized: "This app is maintained by Google Software Update and normally updates in the background.")
            )
        }

        if bundleIdentifier.hasSuffix("-setapp") {
            return ManagedUpdateMechanism(
                title: "Setapp",
                description: String(localized: "This app is managed by Setapp. Install its updates from Setapp.")
            )
        }

        if bundleIdentifier.hasPrefix("com.jetbrains.") {
            return ManagedUpdateMechanism(
                title: String(localized: "JetBrains updater"),
                description: String(localized: "This app is updated by JetBrains Toolbox or its built-in updater.")
            )
        }

        if bundleIdentifier.hasPrefix("com.adobe.") {
            return ManagedUpdateMechanism(
                title: String(localized: "Adobe updater"),
                description: String(localized: "This app is updated by Adobe Creative Cloud or its built-in updater.")
            )
        }

        if bundleIdentifier.hasPrefix("com.microsoft.") {
            return ManagedUpdateMechanism(
                title: String(localized: "Microsoft updater"),
                description: String(localized: "This app uses Microsoft AutoUpdate or a built-in Microsoft update service.")
            )
        }

        if bundleIdentifier.hasPrefix("com.valvesoftware.") ||
           bundleIdentifier.hasPrefix("com.riotgames.") {
            return ManagedUpdateMechanism(
                title: String(localized: "Vendor-managed updater"),
                description: String(localized: "This app is updated by its launcher or built-in update service.")
            )
        }

        let sparkleFramework = frameworks.appendingPathComponent("Sparkle.framework")
        if FileManager.default.fileExists(atPath: sparkleFramework.path),
           bundle.flatMap(SparkleUpdateChecker.feedURL(from:)) == nil {
            return ManagedUpdateMechanism(
                title: String(localized: "Built-in Sparkle updater"),
                description: String(localized: "This app configures Sparkle at runtime, so its update feed can only be checked from inside the app.")
            )
        }

        return nil
    }
}
