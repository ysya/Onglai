//
//  ReleaseNotesProcessor.swift
//  Pearcleaner
//

import Foundation

/// Normalizes release notes from appcasts and external Sparkle pages.
/// Some feeds put their entire release history in the newest appcast item;
/// only the notes newer than the installed version should be displayed.
enum ReleaseNotesProcessor {
    private static let versionPattern = #"(?<!\d)(?:v(?:ersion)?\s*)?(\d+(?:\.\d+){1,5})(?!\d)"#
    private static let maximumExternalNotesSize = 1_048_576

    static func hasContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func normalize(
        _ value: String?,
        installedVersion: String,
        availableVersion: String?
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return trimHistoricalNotes(
            from: trimmed,
            installedVersion: installedVersion,
            availableVersion: availableVersion
        )
    }

    /// Extracts the meaningful portion of a standalone HTML document before
    /// applying the same version-history trimming used for inline appcasts.
    static func normalizeExternalDocument(
        _ value: String,
        installedVersion: String,
        availableVersion: String?
    ) -> String? {
        var content = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.utf8.count <= maximumExternalNotesSize else {
            return nil
        }

        if looksLikeHTMLDocument(content) {
            content = removingDocumentNoise(from: content)
            content = firstCapturedContent(
                in: content,
                patterns: [
                    #"(?is)<article\b[^>]*>(.*?)</article\s*>"#,
                    #"(?is)<main\b[^>]*>(.*?)</main\s*>"#,
                    #"(?is)<body\b[^>]*>(.*?)</body\s*>"#
                ]
            ) ?? content
        }

        return normalize(
            content,
            installedVersion: installedVersion,
            availableVersion: availableVersion
        )
    }

    static var externalNotesSizeLimit: Int {
        maximumExternalNotesSize
    }

    private static func trimHistoricalNotes(
        from content: String,
        installedVersion: String,
        availableVersion: String?
    ) -> String {
        let installed = Version(versionNumber: installedVersion, buildNumber: nil)
        guard !installed.isEmpty else { return content }

        let available = Version(versionNumber: availableVersion, buildNumber: nil)
        let installedMajor = numericMajorVersion(in: installedVersion)
        let candidates = versionHeadingCandidates(in: content)
        var foundTargetRelease = false

        for candidate in candidates {
            guard let candidateVersionString = firstVersion(in: candidate.text) else {
                continue
            }

            let candidateVersion = Version(versionNumber: candidateVersionString, buildNumber: nil)
            guard !candidateVersion.isEmpty else { continue }

            if (!available.isEmpty && candidateVersion == available) || candidateVersion > installed {
                foundTargetRelease = true
                continue
            }

            guard foundTargetRelease,
                  candidateVersion <= installed,
                  numericMajorVersion(in: candidateVersionString) == installedMajor else {
                continue
            }

            let prefix = (content as NSString).substring(to: candidate.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix.isEmpty ? content : prefix
        }

        return content
    }

    private static func versionHeadingCandidates(in content: String) -> [(location: Int, text: String)] {
        let fullRange = NSRange(location: 0, length: (content as NSString).length)

        if content.range(of: #"<h[1-6]\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let expression = try? NSRegularExpression(
               pattern: #"(?is)<h[1-6]\b[^>]*>.*?</h[1-6]\s*>"#
           ) {
            return expression.matches(in: content, range: fullRange).map { match in
                let html = (content as NSString).substring(with: match.range)
                return (match.range.location, strippingHTML(from: html))
            }
        }

        // Plain-text feeds commonly use one short version title per line.
        var candidates: [(location: Int, text: String)] = []
        content.enumerateSubstrings(
            in: content.startIndex..<content.endIndex,
            options: .byLines
        ) { line, lineRange, _, _ in
            guard let line else { return }
            if line.utf16.count <= 180, firstVersion(in: line) != nil {
                candidates.append((NSRange(lineRange, in: content).location, line))
            }
        }
        return candidates
    }

    private static func firstVersion(in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: versionPattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(location: 0, length: (value as NSString).length)
        guard let match = expression.firstMatch(in: value, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return (value as NSString).substring(with: match.range(at: 1))
    }

    private static func numericMajorVersion(in value: String) -> String? {
        firstVersion(in: value)?.split(separator: ".").first.map(String.init)
    }

    private static func looksLikeHTMLDocument(_ value: String) -> Bool {
        value.range(of: #"<(?:!doctype|html|head|body)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func removingDocumentNoise(from html: String) -> String {
        var cleaned = html
        let patterns = [
            #"(?is)<!--.*?-->"#,
            #"(?is)<script\b[^>]*>.*?</script\s*>"#,
            #"(?is)<style\b[^>]*>.*?</style\s*>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript\s*>"#,
            #"(?is)<nav\b[^>]*>.*?</nav\s*>"#,
            #"(?is)<footer\b[^>]*>.*?</footer\s*>"#
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return cleaned
    }

    private static func firstCapturedContent(in value: String, patterns: [String]) -> String? {
        let range = NSRange(location: 0, length: (value as NSString).length)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: value, range: range),
                  match.numberOfRanges > 1 else {
                continue
            }
            return (value as NSString).substring(with: match.range(at: 1))
        }
        return nil
    }

    private static func strippingHTML(from value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }
}
