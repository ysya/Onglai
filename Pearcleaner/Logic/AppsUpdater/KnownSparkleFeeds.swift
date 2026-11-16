import Foundation

/// Shared feed and channel policy for external Sparkle checks and installs.
enum KnownSparkleFeeds {
    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func feedURL(
        bundleIdentifier: String,
        information: [String: Any],
        architecture: String = currentArchitecture,
        rules: UpdaterRuleSet = UpdaterRuleStore.shared.snapshot
    ) -> URL? {
        // A publisher's explicit feed remains authoritative, including a
        // deliberately selected development channel.
        if let rawFeed = information["SUFeedURL"] as? String,
           let explicitFeed = validatedFeedURL(from: rawFeed) {
            return explicitFeed
        }

        // Runtime feeds are exact, validated mappings from one immutable rule
        // snapshot. Rollout selection and release comparisons stay with Sparkle.
        guard let feed = rules.sparkleFeed(bundleIdentifier: bundleIdentifier, architecture: architecture) else {
            return nil
        }
        return URL(string: feed.feedURL)
    }

    static func validatedFeedURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !["null", "(null)", "nil"].contains(value.lowercased()),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    static func isPrereleaseChannel(_ channel: String?) -> Bool {
        guard let channel else { return false }
        let value = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["", "release", "stable"].contains(value)
    }

    static func allowedChannels(includePreReleases: Bool) -> Set<String> {
        let stable: Set<String> = ["release", "stable"]
        return includePreReleases ? stable.union(["beta", "alpha", "nightly", "rc", "dev"]) : stable
    }

    static func hasInvalidEdDSAPublicKey(in information: [String: Any]) -> Bool {
        guard information.keys.contains("SUPublicEDKey") else { return false }
        guard let rawKey = information["SUPublicEDKey"] as? String else { return true }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains("-----BEGIN"), let decodedKey = Data(base64Encoded: key) else { return true }
        return decodedKey.count != 32
    }
}
