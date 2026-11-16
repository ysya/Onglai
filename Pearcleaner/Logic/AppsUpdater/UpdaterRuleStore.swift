import Foundation

/// A synchronized immutable snapshot shared by the update checkers. Only a
/// strictly newer, fully validated document can replace or persist that snapshot.
final class UpdaterRuleStore: @unchecked Sendable {
    typealias Loader = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    typealias Clock = @Sendable () -> Date

    static let shared = UpdaterRuleStore()
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/ysya/Onglai/main/Pearcleaner/Resources/updater-rules.json")!
    static let cacheKey = "settings.updater.rules.cache.v1"
    private static let checkedAtKey = "settings.updater.rules.checkedAt.v1"
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let loader: Loader
    private let clock: Clock
    private var rules: UpdaterRuleSet
    private var lastAttempt: Date?
    private var inFlight: Task<Void, Never>?

    var snapshot: UpdaterRuleSet { locked { rules } }
    var current: UpdaterRuleSet { snapshot }

    init(bundledRules: UpdaterRuleSet = .bundled(), defaults: UserDefaults = .standard,
         loader: @escaping Loader = { request, limit in
             try await UpdateHTTPClient.response(for: request, maximumBytes: limit)
         }, clock: @escaping Clock = { Date() }) {
        self.defaults = defaults
        self.loader = loader
        self.clock = clock
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? UpdaterRuleSet.decodeValidated(data), cached.revision > bundledRules.revision {
            rules = cached
        } else {
            rules = bundledRules
        }
        lastAttempt = defaults.object(forKey: Self.checkedAtKey) as? Date
    }

    func refreshIfNeeded(force: Bool = false) async {
        await refreshTask(force: force)?.value
    }

    private func refreshTask(force: Bool) -> Task<Void, Never>? {
        locked {
            if let inFlight { return inFlight }
            let now = clock()
            if !force, let lastAttempt,
               now >= lastAttempt, now.timeIntervalSince(lastAttempt) < Self.refreshInterval { return nil }
            lastAttempt = now
            defaults.set(now, forKey: Self.checkedAtKey)
            let task = Task<Void, Never> { [weak self] in await self?.performRefresh() }
            inFlight = task
            return task
        }
    }

    private func performRefresh() async {
        defer { locked { inFlight = nil } }
        var request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Onglai-UpdateChecker", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await loader(request, UpdaterRuleSet.maximumBytes)
            guard response.statusCode == 200, response.url == Self.sourceURL,
                  data.count <= UpdaterRuleSet.maximumBytes else { return }
            let candidate = try UpdaterRuleSet.decodeValidated(data)
            locked {
                guard candidate.revision > rules.revision else { return }
                defaults.set(data, forKey: Self.cacheKey)
                rules = candidate
            }
        } catch {
            // Missing publication, offline use, and invalid remote data all keep
            // the bundled or last-known-valid rules without an app-level error.
        }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
