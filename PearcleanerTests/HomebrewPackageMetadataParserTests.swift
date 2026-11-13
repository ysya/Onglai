import XCTest
@testable import Pearcleaner

final class HomebrewPackageMetadataParserTests: XCTestCase {
    func testParsesLegacyCaskArray() throws {
        let data = try envelope([
            [
                "token": "example-app",
                "name": ["Example App"],
                "desc": "A useful app",
                "version": "2.4.1",
                "bundle_version": "241",
                "auto_updates": true,
                "artifacts": [["app": ["Example App.app"]]]
            ]
        ])

        let result = try HomebrewPackageMetadataParser.parseJWS(data, kind: .cask)

        XCTAssertEqual(result, [
            HomebrewPackageMetadata(
                name: "example-app",
                displayName: "Example App",
                description: "A useful app",
                version: "2.4.1",
                bundleVersion: "241",
                autoUpdates: true,
                artifacts: ["Example App.app"]
            )
        ])
    }

    func testParsesLegacyFormulaArray() throws {
        let data = try envelope([
            [
                "name": "example-tool",
                "desc": "A useful tool",
                "versions": ["stable": "1.8.0"]
            ]
        ])

        let result = try HomebrewPackageMetadataParser.parseJWS(data, kind: .formula)

        XCTAssertEqual(result.map(\.name), ["example-tool"])
        XCTAssertEqual(result.first?.version, "1.8.0")
    }

    func testSelectsPlatformSpecificLegacyCaskVersion() throws {
        let data = try envelope([
            [
                "token": "example-app",
                "name": ["Example App"],
                "version": "1.0.0",
                "variations": [
                    "tahoe": ["version": "2.0.0"],
                    "arm64_tahoe": ["version": "3.0.0"]
                ]
            ]
        ])

        let result = try HomebrewPackageMetadataParser.parseJWS(
            data,
            kind: .cask,
            osCodename: "tahoe",
            isArm: true
        )

        XCTAssertEqual(result.first?.version, "3.0.0")
    }

    func testParsesHomebrewSevenDictionaryPayload() throws {
        let payload: [String: Any] = [
            "formulae": [
                "example-tool": [
                    "desc": "A useful tool",
                    "stable_version": "3.2.0"
                ]
            ],
            "casks": [
                "example-app": [
                    "desc": "A useful app",
                    "names": ["Example App"],
                    "version": "4.5.0",
                    "raw_artifacts": [[":app", ["Example App.app"]]]
                ]
            ]
        ]
        let data = try envelope(payload)

        let formulae = try HomebrewPackageMetadataParser.parseJWS(data, kind: .formula)
        let casks = try HomebrewPackageMetadataParser.parseJWS(data, kind: .cask)

        XCTAssertEqual(formulae.first?.name, "example-tool")
        XCTAssertEqual(formulae.first?.version, "3.2.0")
        XCTAssertEqual(casks.first?.name, "example-app")
        XCTAssertEqual(casks.first?.displayName, "Example App")
        XCTAssertEqual(casks.first?.version, "4.5.0")
        XCTAssertEqual(casks.first?.artifacts, ["Example App.app"])
    }

    func testMissingSectionReturnsEmptyCatalogue() throws {
        let data = try envelope(["formulae": [:]])

        XCTAssertEqual(
            try HomebrewPackageMetadataParser.parseJWS(data, kind: .cask),
            []
        )
    }

    func testMalformedEnvelopeThrows() {
        XCTAssertThrowsError(
            try HomebrewPackageMetadataParser.parseJWS(Data("not-json".utf8), kind: .formula)
        )
    }

    private func envelope(_ payload: Any) throws -> Data {
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadString = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
        return try JSONSerialization.data(
            withJSONObject: ["payload": payloadString, "signatures": []],
            options: [.sortedKeys]
        )
    }
}
