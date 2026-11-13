import Foundation

enum DeletionSafetyPolicy {
    private static let sensitiveLibraryDirectories: Set<String> = [
        "application scripts",
        "application support",
        "caches",
        "containers",
        "group containers",
        "preferences",
        "saved application state"
    ]

    static func isProtected(
        _ url: URL,
        targetBundleIdentifier: String? = nil,
        entitlementIdentifiers: [String] = []
    ) -> Bool {
        guard let identifier = libraryIdentifier(for: url) else { return false }
        let normalizedIdentifier = identifier.lowercased()

        guard isSystemIdentifier(normalizedIdentifier) else { return false }

        let allowedIdentifiers = ([targetBundleIdentifier].compactMap { $0 } + entitlementIdentifiers)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0 != "-" }

        return !allowedIdentifiers.contains {
            normalizedIdentifier == $0 ||
            normalizedIdentifier.hasPrefix($0 + ".") ||
            normalizedIdentifier.hasPrefix($0 + "-")
        }
    }

    private static func libraryIdentifier(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard let libraryIndex = components.lastIndex(where: { $0.caseInsensitiveCompare("Library") == .orderedSame }),
              components.indices.contains(libraryIndex + 2) else {
            return nil
        }

        let directory = components[libraryIndex + 1].lowercased()
        guard sensitiveLibraryDirectories.contains(directory) else { return nil }

        let item = components[libraryIndex + 2]
        if directory == "preferences" {
            return URL(fileURLWithPath: item).deletingPathExtension().lastPathComponent
        }
        return item
    }

    private static func isSystemIdentifier(_ identifier: String) -> Bool {
        identifier == "com.apple" ||
        identifier.hasPrefix("com.apple.") ||
        identifier == "group.com.apple" ||
        identifier.hasPrefix("group.com.apple.") ||
        identifier == "group.is.workflow" ||
        identifier.hasPrefix("group.is.workflow.")
    }
}
