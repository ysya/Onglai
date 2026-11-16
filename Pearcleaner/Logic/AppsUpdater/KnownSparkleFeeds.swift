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
        architecture: String = currentArchitecture
    ) -> URL? {
        // A publisher's explicit feed remains authoritative, including a
        // deliberately selected development channel.
        if let rawFeed = information["SUFeedURL"] as? String,
           let explicitFeed = validatedFeedURL(from: rawFeed) {
            return explicitFeed
        }

        // These apps configure their feed at runtime. Keep this list exact:
        // similar bundle IDs can identify another edition or signing identity.
        let feed: String
        switch bundleIdentifier {
        case "com.openai.codex":
            feed = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
        case "com.mitchellh.ghostty":
            // Ghostty selects tip through its own runtime configuration. Do
            // not infer that choice from a commit hash or version string.
            feed = "https://release.files.ghostty.org/appcast.xml"
        case "io.tailscale.ipn.macsys":
            feed = "https://pkgs.tailscale.com/stable/appcast.xml"
        case "dev.kdrag0n.MacVirt":
            guard architecture == "arm64" else { return nil }
            // Leave rollout selection and comparison with a newer installed
            // build to Sparkle. Do not invent a rollout bucket or select an item.
            feed = "https://api-updates.orbstack.dev/arm64/appcast.xml?bucket="
        case "company.thebrowser.dia":
            feed = "https://releases.diabrowser.com/BoostBrowser-updates.xml"
        case "com.cloudflare.1dot1dot1dot1.macos":
            feed = "https://downloads.cloudflareclient.com/v1/update/sparkle/macos/ga"
        default:
            return nil
        }
        return URL(string: feed)
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
