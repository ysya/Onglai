import XCTest
@testable import Pearcleaner

final class CleanupWorkflowTests: XCTestCase {
    func testUninstallFindsExactAppDataByHostAndContainers() throws {
        let manager = FileManager.default
        let library = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: library) }
        let identifier = "com.example.Example"
        let uuid = UUID().uuidString
        let support = library.appendingPathComponent("Application Support/\(identifier)")
        let scripts = library.appendingPathComponent("Application Scripts/\(identifier)")
        let preferences = library.appendingPathComponent("Preferences/ByHost/\(identifier).\(uuid).plist")
        let container = library.appendingPathComponent("Containers/\(uuid)")
        let conflictingContainer = library.appendingPathComponent("Containers/\(identifier)")
        let misleadingPaths = [
            library.appendingPathComponent("Application Support/Example"),
            library.appendingPathComponent("Application Support/\(identifier)Beta"),
            library.appendingPathComponent("Group Containers/\(identifier)"),
            library.appendingPathComponent("Receipts/\(identifier)")
        ]
        for directory in [support, scripts, preferences.deletingLastPathComponent(), container, conflictingContainer] + misleadingPaths {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: preferences)
        try Data().write(to: preferences.deletingLastPathComponent().appendingPathComponent("\(identifier).Beta.plist"))
        for (path, owner) in [(container, identifier), (conflictingContainer, "com.example.Other")] {
            let metadata = try PropertyListSerialization.data(
                fromPropertyList: ["MCMMetadataIdentifier": owner], format: .binary, options: 0
            )
            try metadata.write(to: path.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }

        let found = DeletionSafetyPolicy.ownedLibraryFiles(
            bundleIdentifier: identifier, userLibrary: library, localLibrary: nil
        ) { _, _ in XCTFail("The fixture is readable") }

        XCTAssertEqual(Set(found.map(\.path)), Set([support, scripts, preferences, container].map(\.path)))
    }

    func testUninstallDiscoversOnlyDeclaredEmbeddedExtensionContainers() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let app = root.appendingPathComponent("Example.app")
        let owner = "com.example.Example"

        func createPlist(_ values: [String: Any], at file: URL) throws {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: file)
        }

        let extensionID = owner + ".Share"
        try createPlist(
            ["CFBundleIdentifier": extensionID, "NSExtension": ["NSExtensionPointIdentifier": "com.apple.share-services"]],
            at: app.appendingPathComponent("Contents/PlugIns/Share.appex/Contents/Info.plist")
        )
        let foreignID = "com.another.App.Share"
        try createPlist(
            ["CFBundleIdentifier": foreignID, "NSExtension": ["NSExtensionPointIdentifier": "com.apple.share-services"]],
            at: app.appendingPathComponent("Contents/PlugIns/Foreign.appex/Contents/Info.plist")
        )
        let undeclaredID = owner + ".Other"
        let containers = library.appendingPathComponent("Containers")
        for identifier in [extensionID, foreignID, undeclaredID] {
            let container = containers.appendingPathComponent(identifier)
            try createPlist(["MCMMetadataIdentifier": identifier],
                            at: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }

        let found = DeletionSafetyPolicy.ownedLibraryFiles(
            bundleIdentifier: owner, userLibrary: library, localLibrary: nil, appBundle: app
        ) { _, path in XCTFail("Unexpected read error at \(path)") }

        XCTAssertEqual(found.map(\.path), [containers.appendingPathComponent(extensionID).path])
    }

    func testUninstallDoesNotClaimVendorDataForAnUnsignedBundle() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let app = root.appendingPathComponent("Visual Studio Code.app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        let paths = [info.deletingLastPathComponent(), library.appendingPathComponent("Application Support/Code"),
                     root.appendingPathComponent(".vscode"), root.appendingPathComponent(".vscode-shared")]
        for path in paths {
            try manager.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let identifier = "com.microsoft.VSCode"
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .binary, options: 0)
        try data.write(to: info)

        let found = DeletionSafetyPolicy.ownedLibraryFiles(
            bundleIdentifier: identifier, userLibrary: library, localLibrary: nil, appBundle: app
        ) { _, path in XCTFail("Unexpected read error at \(path)") }

        XCTAssertTrue(found.isEmpty)
    }

    func testUninstallFindsOnlyTheDeclaredNamespacedSparklePreferences() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let preferences = library.appendingPathComponent("Preferences")
        let identifier = "com.example.Preview"
        let domain = identifier + ".updates"
        let updaterPreferences = preferences.appendingPathComponent(domain + ".plist")
        try manager.createDirectory(at: preferences, withIntermediateDirectories: true)
        for candidate in [domain, domain + ".backup", "com.example.updates"] {
            try Data().write(to: preferences.appendingPathComponent(candidate + ".plist"))
        }
        let app = root.appendingPathComponent("Preview.app")
        try makeUninstallBundle(at: app, executable: "Preview", identifier: identifier, extraInfo: ["SUDefaultsDomain": domain])
        let sparkle = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        try manager.createDirectory(at: sparkle, withIntermediateDirectories: true)

        let found = DeletionSafetyPolicy.ownedLibraryFiles(
            bundleIdentifier: identifier, userLibrary: library, localLibrary: nil, appBundle: app
        ) { _, _ in XCTFail("The fixture is readable") }

        XCTAssertEqual(Set(found.map(\.path)), [updaterPreferences.path])

        let foreignApp = root.appendingPathComponent("Foreign.app")
        try makeUninstallBundle(at: foreignApp, executable: "Foreign", identifier: "org.example.foreign", extraInfo: ["SUDefaultsDomain": domain])
        let foreignSparkle = foreignApp.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        try manager.createDirectory(at: foreignSparkle, withIntermediateDirectories: true)
        let foreign = DeletionSafetyPolicy.ownedLibraryFiles(
            bundleIdentifier: "org.example.foreign", userLibrary: library, localLibrary: nil, appBundle: foreignApp
        ) { _, _ in XCTFail("The fixture is readable") }
        XCTAssertTrue(foreign.isEmpty)
    }

    func testUninstallMatchesAperitifReportsToTheExactEmbeddedExecutableAndIdentifier() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let app = root.appendingPathComponent("Preview.app")
        let identifier = "com.example.Preview"
        let helperID = "org.chromium.Chromium.helper"
        let name = "Chromium Helper (Aperitif)"
        let helper = app.appendingPathComponent("Contents/Frameworks/Chromium Framework.framework/Versions/158/Helpers/\(name).app")
        try makeUninstallBundle(at: app, executable: "Preview", identifier: identifier)
        try makeUninstallBundle(at: helper, executable: name, identifier: helperID)
        let executable = helper.appendingPathComponent("Contents/MacOS/\(name)").path
        let userLibrary = root.appendingPathComponent("User/Library")
        let localLibrary = root.appendingPathComponent("Library")
        let userReports = userLibrary.appendingPathComponent("Logs/DiagnosticReports")
        let localReports = localLibrary.appendingPathComponent("Logs/DiagnosticReports")
        for directory in [userReports, localReports] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func writeReport(_ name: String, in directory: URL, executable: String, identifier: String) throws -> URL {
            let file = directory.appendingPathComponent(name + ".diag")
            let report = """
            Date/Time:        2026-01-01 00:00:00.000 +0000
            Report Version:   67

            Command:          Chromium Helper (Aperitif)
            Path:             \(executable)
            Identifier:       \(identifier)

            Event:            disk writes
            """
            try report.write(to: file, atomically: true, encoding: .utf8)
            return file
        }

        let userReport = try writeReport("\(name)_user", in: userReports, executable: executable, identifier: helperID)
        let localReport = try writeReport("\(name)_local", in: localReports, executable: executable, identifier: helperID)
        _ = try writeReport("\(name)_other-app", in: localReports,
                            executable: executable.replacingOccurrences(of: "/Preview.app/", with: "/Other.app/"), identifier: helperID)
        _ = try writeReport("\(name)_other-identifier", in: localReports, executable: executable, identifier: "org.other.helper")
        _ = try writeReport("\(name)_old-version", in: localReports,
                            executable: executable.replacingOccurrences(of: "/Versions/158/", with: "/Versions/157/"), identifier: helperID)
        _ = try writeReport("\(name)_wrong-executable", in: localReports, executable: executable + "-backup", identifier: helperID)
        try manager.createSymbolicLink(at: userReports.appendingPathComponent("\(name)_link.diag"), withDestinationURL: localReport)

        let found = DeletionSafetyPolicy.ownedLibraryFiles(
            bundleIdentifier: identifier, userLibrary: userLibrary, localLibrary: localLibrary, appBundle: app
        ) { _, _ in XCTFail("The fixture is readable") }

        XCTAssertEqual(Set(found.map(\.path)), Set([userReport.path, localReport.path]))
    }

    private func makeUninstallBundle(at bundle: URL, executable: String, identifier: String, extraInfo: [String: Any] = [:]) throws {
        let executableURL = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        var info = extraInfo
        info["CFBundleExecutable"] = executable
        info["CFBundleIdentifier"] = identifier
        info["CFBundlePackageType"] = "APPL"
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    func testUninstallMovesTheAppAfterAllSelectedData() {
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        let cache = URL(fileURLWithPath: "/tmp/example-cache")
        let preferences = URL(fileURLWithPath: "/tmp/example-preferences")

        let complete = FileManagerUndo.uninstallMoveOrder([app, cache, preferences], requestedCount: 3, appBundle: app)
        XCTAssertEqual(complete.urls, [cache, preferences, app])
        XCTAssertTrue(complete.stopOnFailure)

        let missing = FileManagerUndo.uninstallMoveOrder([app, cache], requestedCount: 3, appBundle: app)
        XCTAssertEqual(missing.urls, [cache])
        XCTAssertFalse(missing.stopOnFailure)
    }

    func testUninstallKeepsVerifiedChildrenAndSkipsTrash() {
        let parent = URL(fileURLWithPath: "/Applications/Vendor")
        let app = parent.appendingPathComponent("Example.app")
        let resource = app.appendingPathComponent("Contents/Resources")
        let trashedCopy = URL(fileURLWithPath: "/Volumes/External/.Trashes/501/Example.app")
        let appData = URL(fileURLWithPath: "/tmp/data")
        let similarlyNamedData = URL(fileURLWithPath: "/tmp/data-backup")
        let nestedData = appData.appendingPathComponent("nested")

        let candidates = DeletionSafetyPolicy.uninstallCandidates(
            [parent, app, resource, app, trashedCopy, nestedData, similarlyNamedData, appData],
            appBundle: app,
            ownedFiles: [nestedData]
        )

        XCTAssertEqual(Set(candidates), [app, similarlyNamedData, nestedData])
        XCTAssertEqual(candidates.count, 3)
    }

    func testUninstallDoesNotFollowASymlinkToSharedData() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let caches = root.appendingPathComponent("Library/Caches")
        let shared = root.appendingPathComponent("Shared")
        try manager.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: shared, withIntermediateDirectories: true)
        let symlink = caches.appendingPathComponent("com.example.Example")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: shared)

        let found = DeletionSafetyPolicy.ownedLibraryFiles(
            bundleIdentifier: "com.example.Example", userLibrary: caches.deletingLastPathComponent(), localLibrary: nil
        ) { _, _ in XCTFail("The fixture is readable") }

        XCTAssertTrue(found.isEmpty)
    }

    func testAutomaticCaskCleanupRequiresAnExactSingleAppReceipt() {
        let receipt: [String: Any] = [
            "uninstall_flight_blocks": false,
            "uninstall_artifacts": [["app": ["Example.app"]], ["zap": ["trash": ["~/Library/Shared"]]]]
        ]
        let config = ["default": ["appdir": "/Applications"], "explicit": ["appdir": "/Install.Apps"]]
        let app = URL(fileURLWithPath: "/Install.Apps/Example.app")

        XCTAssertTrue(HomebrewUninstaller.simpleReceiptMatches(receipt, config: config, appBundle: app))
        XCTAssertFalse(HomebrewUninstaller.simpleReceiptMatches(
            receipt, config: config, appBundle: URL(fileURLWithPath: "/Applications/Example.app")
        ))
        var complexReceipt = receipt
        complexReceipt["uninstall_artifacts"] = [["app": ["Example.app"]], ["app": ["Other.app"]]]
        XCTAssertFalse(HomebrewUninstaller.simpleReceiptMatches(complexReceipt, config: config, appBundle: app))
        complexReceipt["uninstall_artifacts"] = [["app": ["Example.app"]], ["uninstall": ["script": "cleanup"]]]
        XCTAssertFalse(HomebrewUninstaller.simpleReceiptMatches(complexReceipt, config: config, appBundle: app))
    }

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
