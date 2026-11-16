import Foundation

/// Debug builds must never claim the installed release's privacy identity.
enum OnglaiIdentity {
    #if DEBUG
    static let bundleIdentifier = "me.ysya.Onglai.Debug"
    static let urlScheme = "onglai-debug"
    static let isDebug = true
    static let watcherNotificationPrefix = bundleIdentifier
    static let supportDirectoryName = "Pearcleaner-Debug"
    static let cliName = "ong-debug"
    static let temporaryDirectoryPrefix = "onglai-debug"
    #else
    static let bundleIdentifier = "me.ysya.Onglai"
    static let urlScheme = "onglai"
    static let isDebug = false
    // Retain the existing release notification and storage names.
    static let watcherNotificationPrefix = "Pearcleaner"
    static let supportDirectoryName = "Pearcleaner"
    static let cliName = "ong"
    static let temporaryDirectoryPrefix = "pearcleaner"
    #endif

    static let helperIdentifier = bundleIdentifier + ".Helper"
    static let sentinelIdentifier = bundleIdentifier + ".Sentinel"
    static let finderIdentifier = bundleIdentifier + ".FinderOpen"
    static let passwordRequest = bundleIdentifier + ".passwordRequest"
    static let passwordResponse = bundleIdentifier + ".passwordResponse"
    static let watcherStart = watcherNotificationPrefix + ".StartFileWatcher"
    static let watcherStop = watcherNotificationPrefix + ".StopFileWatcher"
}
