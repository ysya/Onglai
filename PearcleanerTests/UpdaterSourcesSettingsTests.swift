import XCTest
@testable import Pearcleaner

final class UpdaterSourcesSettingsTests: XCTestCase {
    func testOlderSettingsEnableNewSourcesWithoutResettingExistingChoices() {
        let settings = UpdaterSourcesSettings.decode(from: Data(#"{"homebrew":{"enabled":false,"showAutoUpdates":false},"electron":{"enabled":false}}"#.utf8))
        XCTAssertFalse(settings.homebrew.enabled)
        XCTAssertFalse(settings.electron.enabled)
        XCTAssertTrue(settings.official.enabled)
        XCTAssertTrue(settings.catalog.enabled)
        XCTAssertTrue(settings.enabledSources.contains(.official))
        XCTAssertFalse(settings.enabledSources.contains(.homebrew))
    }

    func testNewSourceChoicesSurviveEncoding() {
        var settings = UpdaterSourcesSettings()
        settings.official.enabled = false
        settings.catalog.enabled = false
        let restored = UpdaterSourcesSettings.decode(from: settings.encode())
        XCTAssertFalse(restored.official.enabled)
        XCTAssertFalse(restored.catalog.enabled)
        XCTAssertFalse(restored.enabledSources.contains(.official))
        XCTAssertFalse(restored.enabledSources.contains(.catalog))
        XCTAssertTrue(restored.enabledSources.contains(.sparkle))
    }
}
