import XCTest
@testable import Pearcleaner

final class AppLoadCoordinatorTests: XCTestCase {
    func testClearsStateBeforeBackgroundLoadStarts() async {
        let recorder = EventRecorder()
        let loadStarted = expectation(description: "background load started")

        await MainActor.run {
            AppLoadCoordinator.start(
                clear: { recorder.append("clear") },
                load: {
                    recorder.append("load")
                    loadStarted.fulfill()
                }
            )
        }

        await fulfillment(of: [loadStarted], timeout: 1)
        XCTAssertEqual(recorder.events, ["clear", "load"])
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}
