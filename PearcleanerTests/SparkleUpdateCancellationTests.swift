import XCTest
@testable import Pearcleaner

final class SparkleUpdateCancellationTests: XCTestCase {
    func testCancellingActiveCheckInvokesFrameworkAbortAndCompletesOnceAfterCleanup() async {
        let started = expectation(description: "Checking started")
        let aborted = expectation(description: "Framework cancellation requested")
        let completed = expectation(description: "Operation completed")
        completed.assertForOverFulfill = true
        let session = InjectedSparkleSession(onStart: { started.fulfill() }, onCancel: { aborted.fulfill() })
        let operation = SparkleUpdateOperation(app: fixture(), includePreReleases: false,
            progressCallback: { _, _ in }, completionCallback: { success, error in
                XCTAssertFalse(success)
                XCTAssertTrue(error is CancellationError)
                completed.fulfill()
            }, makeDriver: { completion in session.completion = completion; return session })
        let queue = OperationQueue()
        queue.addOperation(operation)
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        await fulfillment(of: [aborted], timeout: 2)
        XCTAssertFalse(operation.isFinished, "Cancellation must wait for framework cleanup")
        await MainActor.run {
            session.completion?(false, CancellationError())
            session.completion?(false, CancellationError())
        }
        await fulfillment(of: [completed], timeout: 2)
    }

    func testCancellationDuringNonCancellableInstallationKeepsQueueOccupiedUntilRealCompletion() async {
        let started = expectation(description: "Installing started")
        let cancellation = expectation(description: "Cancellation forwarded")
        let completed = expectation(description: "Real installation completed")
        let secondStarted = expectation(description: "Next operation starts after installation")
        let state = InstallationState()
        let session = InjectedSparkleSession(onStart: { started.fulfill() }, onCancel: { cancellation.fulfill() })
        let operation = SparkleUpdateOperation(app: fixture(), includePreReleases: false,
            progressCallback: { _, _ in }, completionCallback: { success, error in
                XCTAssertTrue(success)
                XCTAssertNil(error)
                state.finish()
                completed.fulfill()
            }, makeDriver: { completion in session.completion = completion; return session })
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.addOperation(operation)
        queue.addOperation {
            XCTAssertTrue(state.finished)
            secondStarted.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        await fulfillment(of: [cancellation], timeout: 2)
        XCTAssertFalse(operation.isFinished)
        await MainActor.run { session.completion?(true, nil) }
        await fulfillment(of: [completed, secondStarted], timeout: 2)
    }

    @MainActor
    func testDriverCancelsCheckingAndDownloadingThroughOnlyTheCurrentFrameworkClosure() {
        for downloading in [false, true] {
            var requested = 0
            var outcomes: [Bool] = []
            let driver = SparkleUpdateDriver(appInfo: fixture(path: Bundle.main.bundleURL).appInfo,
                includePreReleases: false, cachedAppcastItem: nil, progressCallback: { _, _ in },
                completionCallback: { success, error in
                    outcomes.append(success)
                    XCTAssertTrue(error is CancellationError)
                })
            if downloading { driver.showDownloadInitiated { requested += 1 } }
            else { driver.showUserInitiatedUpdateCheck { requested += 1 } }
            driver.cancelUpdate()
            driver.cancelUpdate()
            XCTAssertEqual(requested, 1)
            XCTAssertTrue(outcomes.isEmpty, "Abort must finish before queue release")
            driver.updateCycleDidFinish(error: nil)
            driver.updateCycleDidFinish(error: nil)
            XCTAssertEqual(outcomes, [false])
        }
    }

    @MainActor
    func testDriverDoesNotUseExpiredDownloadCancellationDuringInstallation() {
        var outcomes: [Bool] = []
        let driver = SparkleUpdateDriver(appInfo: fixture(path: Bundle.main.bundleURL).appInfo,
            includePreReleases: false, cachedAppcastItem: nil, progressCallback: { _, _ in },
            completionCallback: { success, error in outcomes.append(success); XCTAssertNil(error) })
        driver.showDownloadInitiated { XCTFail("Download cancellation expires at extraction") }
        driver.showDownloadDidStartExtractingUpdate()
        driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: {})
        driver.cancelUpdate()
        XCTAssertTrue(outcomes.isEmpty)
        driver.showUpdateInstalledAndRelaunched(false, acknowledgement: {})
        XCTAssertTrue(outcomes.isEmpty, "Wait for final Sparkle cleanup")
        driver.updateCycleDidFinish(error: nil)
        XCTAssertEqual(outcomes, [true])
    }

    private func fixture(path: URL = URL(fileURLWithPath: "/fixture/Native.app")) -> UpdateableApp {
        let info = AppInfo(id: UUID(), path: path,
            bundleIdentifier: "test.sparkle.cancel", appName: "Fixture", appVersion: "1.0", appBuildNumber: nil,
            appIcon: nil, webApp: false, wrapped: false, system: false, arch: .empty, cask: nil, steam: false,
            hasSparkle: true, isAppStore: false, adamID: nil, autoUpdates: nil, bundleSize: 0,
            lipoSavings: nil, fileSize: [:], fileIcon: [:], creationDate: nil, contentChangeDate: nil,
            lastUsedDate: nil, dateAdded: nil, entitlements: nil, teamIdentifier: nil)
        return UpdateableApp(appInfo: info, availableVersion: "2.0", availableBuildNumber: nil, source: .sparkle,
            adamID: nil, appStoreURL: nil, releaseTitle: nil, releaseDescription: nil, releaseNotesLink: nil,
            releaseDate: nil, isPreRelease: false, isIOSApp: false, foundInRegion: nil, appcastItem: nil)
    }
}

private final class InjectedSparkleSession: SparkleUpdateSession, @unchecked Sendable {
    var completion: ((Bool, Error?) -> Void)?
    let onStart: () -> Void
    let onCancel: () -> Void
    init(onStart: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onStart = onStart
        self.onCancel = onCancel
    }
    func startUpdate() { onStart() }
    func cancelUpdate() { onCancel() }
}

private final class InstallationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func finish() { lock.lock(); value = true; lock.unlock() }
}
