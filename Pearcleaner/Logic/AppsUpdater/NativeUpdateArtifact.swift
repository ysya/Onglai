import Foundation

/// A complete, validated description of a directly replaceable application archive.
/// Deliberately not Decodable: all descriptors must pass through the validating initializer.
struct NativeUpdateArtifact: Equatable, Sendable {
    enum Format: String, Codable, Sendable {
        case zip
        case dmg
    }

    struct Digest: Equatable, Sendable {
        enum Algorithm: String, Sendable {
            case sha256
            case sha512
        }

        let algorithm: Algorithm
        let value: String

        fileprivate var isValid: Bool {
            switch algorithm {
            case .sha256:
                return value.count == 64 && value.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
                }
            case .sha512:
                guard let data = Data(base64Encoded: value), data.count == 64 else { return false }
                return data.base64EncodedString() == value
            }
        }
    }

    let url: URL
    let version: String
    let build: String?
    let digest: Digest?
    let format: Format

    init?(url: URL, version: String, build: String? = nil, digest: Digest? = nil, format: Format? = nil) {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              Self.isMeaningfulVersion(version),
              build.map(Self.isMeaningfulVersion) ?? true,
              digest?.isValid ?? true,
              let resolvedFormat = format ?? Format(rawValue: url.pathExtension.lowercased()),
              !["pkg", "mpkg", "exe", "msi", "tar", "gz", "bz2", "xz", "7z"].contains(url.pathExtension.lowercased()),
              Format(rawValue: url.pathExtension.lowercased()).map({ $0 == resolvedFormat }) ?? true else { return nil }
        self.url = url
        self.version = version
        self.build = build
        self.digest = digest
        self.format = resolvedFormat
    }

    private static func isMeaningfulVersion(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
            && value.rangeOfCharacter(from: .decimalDigits) != nil
            && value.count <= 256
    }
}
