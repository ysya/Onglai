import Foundation

/// Guards scan publication across background queues, replacement scans, and cancellation.
final class AppScanCoordinator {
    private let lock = NSLock()
    private var currentID: UUID?

    func start() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        currentID = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentID == id
    }

    @discardableResult
    func finish(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentID == id else { return false }
        currentID = nil
        return true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        currentID = nil
    }
}

enum AppLoadCoordinator {
    @MainActor
    static func start(
        clear: () -> Void,
        load: @escaping @Sendable () -> Void
    ) {
        clear()
        DispatchQueue.global(qos: .userInitiated).async(execute: load)
    }
}
