import XCTest
@testable import Pearcleaner

final class NativeUpdateArtifactTests: XCTestCase {
    func testAcceptsHTTPSArchiveAndRetainsReleaseIdentity() {
        let artifact = NativeUpdateArtifact(url: URL(string: "https://example.com/App.zip?token=public")!, version: "2.0", build: "200")
        XCTAssertEqual(artifact?.format, .zip)
        XCTAssertEqual(artifact?.version, "2.0")
        XCTAssertEqual(artifact?.build, "200")
    }

    func testRejectsUnsafeURLsMissingVersionsAndUnsupportedFormats() {
        for address in ["http://example.com/App.zip", "https://example.com/App.pkg"] {
            XCTAssertNil(NativeUpdateArtifact(url: URL(string: address)!, version: "2.0"))
        }
        var credentialURL = URLComponents(string: "https://example.com/App.zip")!
        credentialURL.user = "fixture-user"
        credentialURL.password = "fixture-password"
        XCTAssertNil(NativeUpdateArtifact(url: credentialURL.url!, version: "2.0"))
        for version in ["", "  ", "latest", "unknown", "2.0 garbage", "2.0\nmalicious"] {
            XCTAssertNil(NativeUpdateArtifact(url: URL(string: "https://example.com/App.zip")!, version: version))
        }
    }

    func testValidatesDigestEncodingAndSupportsExplicitFormat() {
        XCTAssertNil(NativeUpdateArtifact(url: URL(string: "https://example.com/App.pkg")!, version: "2.0", format: .zip))
        XCTAssertNil(NativeUpdateArtifact(url: URL(string: "https://example.com/App.zip")!, version: "2.0", format: .dmg))
        let url = URL(string: "https://example.com/download?id=1")!
        XCTAssertNotNil(NativeUpdateArtifact(url: url, version: "2.0", digest: .init(algorithm: .sha256, value: String(repeating: "a", count: 64)), format: .dmg))
        XCTAssertNotNil(NativeUpdateArtifact(url: url, version: "2.0", digest: .init(algorithm: .sha512, value: Data(repeating: 1, count: 64).base64EncodedString()), format: .zip))
        XCTAssertNil(NativeUpdateArtifact(url: url, version: "2.0", digest: .init(algorithm: .sha256, value: "invalid"), format: .zip))
        XCTAssertNil(NativeUpdateArtifact(url: url, version: "2.0", digest: .init(algorithm: .sha512, value: "AAAA"), format: .zip))
    }
}
