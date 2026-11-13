import XCTest
@testable import Pearcleaner

final class DeletionSafetyPolicyTests: XCTestCase {
    func testProtectsUnrelatedApplePreferencesForApplePrefixedTarget() {
        XCTAssertTrue(isProtected(
            "/Users/example/Library/Preferences/com.apple.dock.plist",
            target: "com.apple.pixelmator"
        ))
        XCTAssertTrue(isProtected(
            "/Users/example/Library/Preferences/com.apple.printingprefs.plist",
            target: "com.apple.pixelmator"
        ))
    }

    func testProtectsUnrelatedAppleContainers() {
        XCTAssertTrue(isProtected(
            "/Users/example/Library/Containers/com.apple.finder",
            target: "com.apple.pixelmator"
        ))
        XCTAssertTrue(isProtected(
            "/Users/example/Library/Caches/com.apple.quicklook.ThumbnailsAgent-1/com.apple.QuickLook.thumbnailcache",
            target: "com.apple.pixelmator"
        ))
    }

    func testProtectsWorkflowGroupContainers() {
        XCTAssertTrue(isProtected(
            "/Users/example/Library/Group Containers/group.is.workflow.shortcuts",
            target: "com.example.editor"
        ))
    }

    func testAllowsExactTargetOwnedAppleNamespace() {
        XCTAssertFalse(isProtected(
            "/Users/example/Library/Containers/com.apple.pixelmator",
            target: "com.apple.pixelmator"
        ))
        XCTAssertFalse(isProtected(
            "/Users/example/Library/Preferences/com.apple.pixelmator.plist",
            target: "com.apple.pixelmator"
        ))
    }

    func testAllowsEntitlementOwnedGroupContainer() {
        XCTAssertFalse(DeletionSafetyPolicy.isProtected(
            URL(fileURLWithPath: "/Users/example/Library/Group Containers/group.com.apple.pixelmator"),
            targetBundleIdentifier: "com.apple.pixelmator",
            entitlementIdentifiers: ["group.com.apple.pixelmator"]
        ))
    }

    func testOrphanScanProtectsAllAppleNamespaces() {
        XCTAssertTrue(DeletionSafetyPolicy.isProtected(
            URL(fileURLWithPath: "/Users/example/Library/Containers/com.apple.pixelmator")
        ))
    }

    func testDoesNotProtectUnrelatedThirdPartyData() {
        XCTAssertFalse(isProtected(
            "/Users/example/Library/Containers/com.example.editor",
            target: "com.example.other"
        ))
    }

    private func isProtected(_ path: String, target: String) -> Bool {
        DeletionSafetyPolicy.isProtected(
            URL(fileURLWithPath: path),
            targetBundleIdentifier: target,
            entitlementIdentifiers: []
        )
    }
}
