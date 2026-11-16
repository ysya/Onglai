import Foundation

/// Compares verified version strings without treating missing or unknown values as current.
enum UpdateVersionComparator {
    private static let expression = try? NSRegularExpression(
        pattern: #"^v?([0-9]+(?:\.[0-9]+)*)(?:[-._]?(alpha|beta|preview|pre|rc|dev|a|b)([0-9]+(?:\.[0-9]+)*|(?:[.-][0-9]+)+)?)?(?:\+[0-9a-z-]+(?:\.[0-9a-z-]+)*)?$"#
    )

    static func compare(installed: String, available: String) -> ComparisonResult? {
        guard let local = parse(installed), let remote = parse(available) else { return nil }
        let coreOrder = compareNumbers(local.core, remote.core)
        guard coreOrder == .orderedSame else { return coreOrder }

        switch (local.prerelease, remote.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (left?, right?):
            if left.rank != right.rank {
                return left.rank < right.rank ? .orderedAscending : .orderedDescending
            }
            let numberOrder = compareNumbers(left.numbers, right.numbers)
            guard numberOrder == .orderedSame else { return numberOrder }
            // Core versions permit omitted trailing zeroes; prerelease fields
            // retain their count, so beta.1 precedes beta.1.0.
            if left.numbers.count != right.numbers.count {
                return left.numbers.count < right.numbers.count ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        }
    }

    /// Nil means that the version cannot establish a release channel.
    static func channel(for version: String) -> String? {
        guard let version = parse(version) else { return nil }
        return version.prerelease?.channel ?? "stable"
    }

    private struct ParsedVersion {
        let core: [String]
        let prerelease: Prerelease?
    }

    private struct Prerelease {
        let channel: String
        let rank: Int
        let numbers: [String]
    }

    private static func parse(_ value: String) -> ParsedVersion? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let expression,
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let coreRange = Range(match.range(at: 1), in: value) else { return nil }

        let core = value[coreRange].split(separator: ".").map(String.init)
        guard let channelRange = Range(match.range(at: 2), in: value) else {
            return ParsedVersion(core: core, prerelease: nil)
        }

        let channel: String
        let rank: Int
        switch value[channelRange] {
        case "dev": (channel, rank) = ("dev", 0)
        case "a", "alpha": (channel, rank) = ("alpha", 1)
        case "b", "beta": (channel, rank) = ("beta", 2)
        case "pre", "preview": (channel, rank) = ("preview", 3)
        case "rc": (channel, rank) = ("rc", 4)
        default: return nil
        }
        let numbers = Range(match.range(at: 3), in: value).map {
            value[$0].split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
        } ?? []
        return ParsedVersion(core: core, prerelease: Prerelease(channel: channel, rank: rank, numbers: numbers))
    }

    private static func compareNumbers(_ left: [String], _ right: [String]) -> ComparisonResult {
        for index in 0..<max(left.count, right.count) {
            let local = normalizedNumber(index < left.count ? left[index] : "0")
            let remote = normalizedNumber(index < right.count ? right[index] : "0")
            if local.count != remote.count {
                return local.count < remote.count ? .orderedAscending : .orderedDescending
            }
            if local != remote {
                return local.lexicographicallyPrecedes(remote) ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func normalizedNumber(_ value: String) -> Substring {
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : trimmed
    }
}
