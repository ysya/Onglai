import XCTest
@testable import Pearcleaner

final class ElectronUpdateMetadataTests: XCTestCase {
    func testParsesPublicDigitalOceanSpacesFeed() throws {
        let source = """
        provider: spaces
        name: example-releases
        region: nyc3
        path: desktop/stable
        channel: beta
        """

        let configuration = try ElectronUpdateMetadataParser.parseConfiguration(source)

        XCTAssertEqual(
            configuration.provider,
            .spaces(baseURL: try XCTUnwrap(URL(string: "https://example-releases.nyc3.digitaloceanspaces.com/desktop/stable/")))
        )
        XCTAssertEqual(
            configuration.manifestURL?.absoluteString,
            "https://example-releases.nyc3.digitaloceanspaces.com/desktop/stable/beta-mac.yml"
        )
        XCTAssertTrue(configuration.isCheckable)
    }

    func testPrivateDigitalOceanSpacesFeedRemainsUnsupported() throws {
        let configuration = try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: spaces
        name: example-releases
        region: nyc3
        acl: private
        """)

        XCTAssertEqual(configuration.provider, .unsupported(name: "spaces"))
        XCTAssertFalse(configuration.isCheckable)
    }

    func testRejectsInvalidDigitalOceanSpacesHostComponents() {
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: spaces
        name: example.releases
        region: nyc3.example.com
        """))
    }

    func testRejectsIncompleteDigitalOceanSpacesConfiguration() {
        XCTAssertThrowsError(try ElectronUpdateMetadataParser.parseConfiguration("""
        provider: spaces
        name: example-releases
        """))
    }
}
