import Foundation

/// Shared bounded queue for Sparkle and native external app updates.
class UpdateQueue {
    static let shared = UpdateQueue()
    private let queue: OperationQueue

    init(maxConcurrentOperations: Int = 3) {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrentOperations
        queue.qualityOfService = .userInitiated
    }

    var isSuspended: Bool {
        get { queue.isSuspended }
        set { queue.isSuspended = newValue }
    }

    func addOperation(_ operation: Operation, completionWhenCancelled: (() -> Void)? = nil) {
        if let completionWhenCancelled {
            let previous = operation.completionBlock
            operation.completionBlock = { [weak operation] in
                previous?()
                if operation?.isCancelled == true { completionWhenCancelled() }
            }
        }
        queue.addOperation(operation)
    }

    func cancelAll() { queue.cancelAllOperations() }

    func containsOperation(for bundleIdentifier: String, appURL: URL? = nil) -> Bool {
        queue.operations.contains { matches($0, bundleIdentifier: bundleIdentifier, appURL: appURL) }
    }

    func cancelOperation(for bundleIdentifier: String, appURL: URL) {
        for operation in queue.operations where matches(operation, bundleIdentifier: bundleIdentifier, appURL: appURL) {
            operation.cancel()
        }
    }

    private func matches(_ operation: Operation, bundleIdentifier: String, appURL: URL?) -> Bool {
        guard !operation.isFinished else { return false }
        if let native = operation as? NativeAppUpdateOperation {
            return native.bundleIdentifier == bundleIdentifier || native.appURL == appURL?.standardizedFileURL
        }
        if let sparkle = operation as? SparkleUpdateOperation {
            return sparkle.bundleIdentifier == bundleIdentifier ||
                sparkle.app.appInfo.path.standardizedFileURL == appURL?.standardizedFileURL
        }
        return false
    }
}

/// A framework callback and queued-cancellation completion may race.
final class UpdateCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
