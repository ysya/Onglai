import Foundation

/// Bridges async native installation to the existing bounded OperationQueue.
final class NativeAppUpdateOperation: Operation, @unchecked Sendable {
    let bundleIdentifier: String
    let appURL: URL
    private let work: @Sendable () async throws -> NativeInstallResult
    private let completion: (Result<NativeInstallResult, Error>) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var started = false
    private var completed = false

    init(bundleIdentifier: String, appURL: URL,
         work: @escaping @Sendable () async throws -> NativeInstallResult,
         completion: @escaping (Result<NativeInstallResult, Error>) -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.appURL = appURL.standardizedFileURL
        self.work = work
        self.completion = completion
        super.init()
    }

    override func main() {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            finish(.failure(CancellationError()))
            return
        }
        started = true
        task = Task.detached(priority: .userInitiated) { [self] in
            defer { semaphore.signal() }
            do {
                try Task.checkCancellation()
                finish(.success(try await work()))
            } catch {
                finish(.failure(error))
            }
        }
        lock.unlock()
        semaphore.wait()
    }

    override func cancel() {
        super.cancel()
        lock.lock()
        let runningTask = task
        let finishImmediately = !started
        lock.unlock()
        runningTask?.cancel()
        if finishImmediately { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<NativeInstallResult, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        task = nil
        lock.unlock()
        completion(result)
    }
}
