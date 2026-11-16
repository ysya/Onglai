import XCTest
@testable import Pearcleaner

final class UpdateVersionComparatorTests: XCTestCase {
    func testComparesEveryNumericComponent() {
        XCTAssertEqual(compare("1.2", "1.2.0.1"), .orderedAscending)
        XCTAssertEqual(compare("1.2.0.1", "1.2"), .orderedDescending)
        XCTAssertEqual(compare("1.2", "1.2.0.0"), .orderedSame)
        XCTAssertEqual(compare("1.10", "1.9"), .orderedDescending)
    }

    func testDoesNotOverflowLargeNumericComponents() {
        XCTAssertEqual(compare("1.999999999999999999999999999999", "1.1000000000000000000000000000000"), .orderedAscending)
        XCTAssertEqual(compare("0001.002", "1.2"), .orderedSame)
    }

    func testOrdersCommonPrereleasesBeforeStableRelease() {
        for version in ["1.2a1", "1.2-beta.3", "1.2b4", "1.2rc2", "1.2-preview.8"] {
            XCTAssertEqual(compare(version, "1.2"), .orderedAscending, version)
        }
        XCTAssertEqual(compare("1.2-beta.9", "1.2-beta.10"), .orderedAscending)
        XCTAssertEqual(compare("1.2-beta.10", "1.2rc1"), .orderedAscending)
        XCTAssertEqual(compare("1.2rc2", "1.3-beta.1"), .orderedAscending)
    }

    func testAcceptsVersionPrefixAndIgnoresSemverBuildMetadata() {
        XCTAssertEqual(compare("v1.2.3+build.42", "1.2.3+build.43"), .orderedSame)
    }

    func testLongerPrereleaseIdentifierSequenceIsNewerEvenWhenSuffixIsZero() {
        for (shorter, longer) in [
            ("1.0.0-beta", "1.0.0-beta.0"),
            ("1.0.0-beta.1", "1.0.0-beta.1.0"),
            ("1.0.0-rc.0", "1.0.0-rc.0.0")
        ] {
            XCTAssertEqual(compare(shorter, longer), .orderedAscending, "\(shorter) -> \(longer)")
            XCTAssertEqual(compare(longer, shorter), .orderedDescending, "\(longer) -> \(shorter)")
        }
        XCTAssertEqual(compare("1.0.0-beta.2", "1.0.0-beta.1.0"), .orderedDescending)
        XCTAssertEqual(compare("1.0.0-beta.1.0", "1.0.0-beta.1.0"), .orderedSame)
        XCTAssertEqual(compare("1.2", "1.2.0.0"), .orderedSame)
    }

    func testRejectsUnknownOrMalformedVersions() {
        for version in ["", "latest", "unknown", "1..2", "1.2.", "release-1.2", "1.2banana", "1.2,45", "1.2+", "1.2-", "1.2--beta"] {
            XCTAssertNil(compare(version, "2.0"), version)
            XCTAssertNil(compare("2.0", version), version)
        }
    }

    private func compare(_ installed: String, _ available: String) -> ComparisonResult? {
        UpdateVersionComparator.compare(installed: installed, available: available)
    }
}
