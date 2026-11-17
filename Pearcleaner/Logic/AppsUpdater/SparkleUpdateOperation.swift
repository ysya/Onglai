import Foundation

protocol SparkleUpdateSession: AnyObject {
    func startUpdate()
    func cancelUpdate()
}

/// Retains the queue slot until Sparkle confirms its update session ended.
class SparkleUpdateOperation: Operation, @unchecked Sendable {
    typealias DriverFactory = (@escaping (Bool, Error?) -> Void) -> SparkleUpdateSession
    let app: UpdateableApp
    let includePreReleases: Bool
    let progressCallback: (Double, UpdateStatus) -> Void
    let completionCallback: (Bool, Error?) -> Void

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    private var completed = false
    private var driver: SparkleUpdateSession?
    private let makeDriver: DriverFactory?

    var bundleIdentifier: String { app.appInfo.bundleIdentifier }

    init(app: UpdateableApp, includePreReleases: Bool,
         progressCallback: @escaping (Double, UpdateStatus) -> Void,
         completionCallback: @escaping (Bool, Error?) -> Void,
         makeDriver: DriverFactory? = nil) {
        self.app = app
        self.includePreReleases = includePreReleases
        self.progressCallback = progressCallback
        self.completionCallback = completionCallback
        self.makeDriver = makeDriver
        super.init()
    }

    override func main() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            finish(false, CancellationError())
            return
        }
        started = true
        lock.unlock()

        DispatchQueue.main.sync {
            guard !isCancelled else { finish(false, CancellationError()); return }
            let completion: (Bool, Error?) -> Void = { [weak self] in self?.finish($0, $1) }
            driver = makeDriver?(completion) ?? SparkleUpdateDriver(
                appInfo: app.appInfo, includePreReleases: includePreReleases,
                cachedAppcastItem: app.appcastItem, progressCallback: progressCallback,
                completionCallback: completion
            )
            driver?.startUpdate()
            if isCancelled { driver?.cancelUpdate() }
        }
        semaphore.wait()
    }

    override func cancel() {
        super.cancel()
        lock.lock()
        let pending = !started
        lock.unlock()
        if pending {
            finish(false, CancellationError())
        } else {
            DispatchQueue.main.async { [weak self] in self?.driver?.cancelUpdate() }
        }
    }

    private func finish(_ success: Bool, _ error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completionCallback(success, error)
        semaphore.signal()
        DispatchQueue.main.async { [weak self] in self?.driver = nil }
    }
}
