import XCTest
@testable import Pearcleaner

final class UpdateQueueTests: XCTestCase {
    func testCancellingANativeOperationBeforeStartCompletesExactlyOnce() {
        let completion = expectation(description: "Cancelled queued operation completes")
        completion.assertForOverFulfill = true
        let operation = NativeAppUpdateOperation(bundleIdentifier: "test.native", appURL: URL(fileURLWithPath: "/fixture/Native.app"), work: {
            XCTFail("Cancelled work must not start")
            return NativeInstallResult()
        }, completion: { result in
            if case .success = result { XCTFail("Cancellation must not succeed") }
            completion.fulfill()
        })
        operation.cancel()
        operation.cancel()
        OperationQueue().addOperation(operation)
        wait(for: [completion], timeout: 2)
    }

    func testCancelledPendingOperationCompletesItsAwaitingCaller() {
        let completion = expectation(description: "Pending cancellation callback")
        completion.assertForOverFulfill = true
        let queue = UpdateQueue(maxConcurrentOperations: 1)
        queue.isSuspended = true
        let operation = BlockOperation { XCTFail("Cancelled pending work must not run") }
        queue.addOperation(operation, completionWhenCancelled: { completion.fulfill() })
        queue.cancelAll()
        queue.isSuspended = false
        wait(for: [completion], timeout: 2)
    }

    func testQueueRecognizesNativeOperationsByBundleOrPath() {
        let queue = UpdateQueue(maxConcurrentOperations: 1)
        queue.isSuspended = true
        let path = URL(fileURLWithPath: "/fixture/Native.app")
        let operation = NativeAppUpdateOperation(bundleIdentifier: "test.native", appURL: path,
                                                work: { NativeInstallResult() }, completion: { _ in })
        queue.addOperation(operation)
        XCTAssertTrue(queue.containsOperation(for: "test.native", appURL: nil))
        XCTAssertTrue(queue.containsOperation(for: "another.source", appURL: path))
        queue.cancelAll()
        queue.isSuspended = false
    }
}
