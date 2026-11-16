import XCTest
@testable import Pearcleaner

final class CleanupWorkflowTests: XCTestCase {
    func testUnreadableOriginalLocationCannotBeConfirmedAsRemoved() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let protected = root.appendingPathComponent("protected")
        try manager.createDirectory(at: protected, withIntermediateDirectories: true)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path)
            try? manager.removeItem(at: root)
        }
        let original = protected.appendingPathComponent("original")
        let trashed = root.appendingPathComponent("old-trash-entry")
        try Data().write(to: original)
        try Data().write(to: trashed)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: protected.path)

        XCTAssertTrue(fileSystemItemMayExist(at: original))

        let result = TrashResult.confirmed(requested: [original], filePairs: [(trashed, original)])

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failed, [original])
    }

    func testLegacyRetryWithNoRemainingSourcesCompletesWithoutAnotherMove() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManagerUndo.shared.deleteFiles(at: [missing]))
    }

    func testMovedRelativeSymbolicLinkIsRecordedEvenWhenItsTargetIsNowMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original-link")
        let trashed = root.appendingPathComponent("trashed-link")
        try FileManager.default.createSymbolicLink(atPath: trashed.path, withDestinationPath: "missing-relative-target")

        let result = TrashResult.confirmed(requested: [original], filePairs: [(trashed, original)])

        XCTAssertEqual(result.moved, [original])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.succeeded)
    }

    func testOnlyConfirmsFilesThatReachedTrashAndLeftTheirOriginalLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = root.appendingPathComponent("moved")
        let failed = root.appendingPathComponent("failed")
        let duplicate = root.appendingPathComponent("duplicate")
        let movedTrash = root.appendingPathComponent("moved-trash")
        let failedTrash = root.appendingPathComponent("failed-trash")
        let duplicateTrash = root.appendingPathComponent("duplicate-trash")
        for url in [movedTrash, failed, duplicate, duplicateTrash] {
            try Data().write(to: url)
        }

        let result = TrashResult.confirmed(
            requested: [moved, failed, duplicate],
            filePairs: [(movedTrash, moved), (failedTrash, failed), (duplicateTrash, duplicate)]
        )

        XCTAssertEqual(result.moved, [moved])
        XCTAssertEqual(result.failed, [failed, duplicate])
        XCTAssertFalse(result.succeeded)
    }

    @MainActor
    func testFailedDeletionRetainsAppFilesAndSelectionForRetry() {
        let state = AppState()
        var app = AppInfo.empty
        let file = URL(fileURLWithPath: "/tmp/example-cache")
        app.fileSize = [file: 128]
        state.appInfo = app
        state.sortedApps = [app]
        state.selectedItems = [file]

        let removed = state.applyTrashResult(TrashResult(moved: [], failed: [file]))

        XCTAssertFalse(removed)
        XCTAssertEqual(state.sortedApps.count, 1)
        XCTAssertEqual(state.appInfo.fileSize, [file: 128])
        XCTAssertEqual(state.selectedItems, [file])
    }

    @MainActor
    func testPartialDeletionRetainsOnlyFailedFiles() {
        let state = AppState()
        var app = AppInfo.empty
        let moved = URL(fileURLWithPath: "/tmp/example-cache")
        let failed = URL(fileURLWithPath: "/tmp/example-preferences")
        app.fileSize = [moved: 128, failed: 256]
        state.appInfo = app
        state.selectedItems = [moved, failed]

        XCTAssertFalse(state.applyTrashResult(TrashResult(moved: [moved], failed: [failed])))
        XCTAssertEqual(state.appInfo.fileSize, [failed: 256])
        XCTAssertEqual(state.selectedItems, [failed])
    }

    func testFilteringReportsHiddenSelection() {
        let cache = URL(fileURLWithPath: "/tmp/cache")
        let preferences = URL(fileURLWithPath: "/tmp/preferences")
        let summary = FileSelectionSummary(selected: [cache, preferences], visible: [cache])

        XCTAssertEqual(summary.visibleSelectedCount, 1)
        XCTAssertEqual(summary.hiddenSelectedCount, 1)
        XCTAssertTrue(summary.allVisibleSelected)
        XCTAssertEqual(summary.togglingVisibleSelection(), [preferences])
    }

    func testSelectingVisibleItemsPreservesHiddenSelection() {
        let cache = URL(fileURLWithPath: "/tmp/cache")
        let preferences = URL(fileURLWithPath: "/tmp/preferences")
        let summary = FileSelectionSummary(selected: [preferences], visible: [cache])

        XCTAssertFalse(summary.allVisibleSelected)
        XCTAssertEqual(summary.togglingVisibleSelection(), [cache, preferences])
        XCTAssertEqual(summary.selectingOnlyVisible(), [cache])
    }

    func testEmptySearchResultsCannotToggleHiddenSelection() {
        let cache = URL(fileURLWithPath: "/tmp/cache")
        let summary = FileSelectionSummary(selected: [cache], visible: [])

        XCTAssertFalse(summary.allVisibleSelected)
        XCTAssertEqual(summary.togglingVisibleSelection(), [cache])
        XCTAssertEqual(summary.hiddenSelectedCount, 1)
    }

    func testReplacingScanRejectsOldCompletionAndCancellationRejectsCurrentCompletion() {
        let coordinator = AppScanCoordinator()
        let first = coordinator.start()
        let second = coordinator.start()

        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertTrue(coordinator.isCurrent(second))
        XCTAssertFalse(coordinator.finish(first))
        coordinator.cancel()
        XCTAssertFalse(coordinator.isCurrent(second))
        XCTAssertFalse(coordinator.finish(second))
    }

    func testCompletedScanCannotPublishAgain() {
        let coordinator = AppScanCoordinator()
        let scan = coordinator.start()

        XCTAssertTrue(coordinator.finish(scan))
        XCTAssertFalse(coordinator.finish(scan))
        XCTAssertFalse(coordinator.isCurrent(scan))
    }
}
