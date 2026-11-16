import XCTest
@testable import Pearcleaner

final class UpdaterRuleStoreTests: XCTestCase {
    func testValidatedSuccessPersistsAndSurvivesRestart() async throws {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults, loader: { request, limit in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://raw.githubusercontent.com/ysya/Onglai/main/Pearcleaner/Resources/updater-rules.json")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
            XCTAssertEqual(limit, 256 * 1024)
            return Self.response(UpdaterRuleFixture.data(revision: 3), request: request)
        })
        await store.refreshIfNeeded()
        XCTAssertEqual(store.snapshot.revision, 3)
        let cached = try XCTUnwrap(defaults.data(forKey: UpdaterRuleStore.cacheKey))
        XCTAssertEqual(try UpdaterRuleSet.decodeValidated(cached).revision, 3)
        let restarted = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults, loader: { _, _ in
            throw URLError(.notConnectedToInternet)
        })
        XCTAssertEqual(restarted.current.revision, 3)
    }

    func testNetworkAndHTTPFailuresKeepBundledRulesWithoutCaching() async {
        for status in [nil, 404, 503] as [Int?] {
            let defaults = temporaryDefaults()
            let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(revision: 2), defaults: defaults, loader: { request, _ in
                if let status { return Self.response(UpdaterRuleFixture.data(revision: 3), request: request, status: status) }
                throw URLError(.notConnectedToInternet)
            })
            await store.refreshIfNeeded()
            XCTAssertEqual(store.snapshot.revision, 2)
            XCTAssertNotNil(store.snapshot.officialSource(bundleIdentifier: "com.example.App"))
            XCTAssertNil(defaults.data(forKey: UpdaterRuleStore.cacheKey))
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
    }

    func testMalformedUnknownSchemaOversizedAndRedirectedResponsesKeepLastValidCache() async {
        let responses: [(Data, URL?)] = [
            (Data("not-json".utf8), nil), (UpdaterRuleFixture.data(schemaVersion: 2, revision: 10), nil),
            (Data(repeating: 32, count: 256 * 1024 + 1), nil),
            (UpdaterRuleFixture.data(revision: 10), URL(string: "https://another.example.com/updater-rules.json"))
        ]
        for (data, responseURL) in responses {
            let defaults = temporaryDefaults()
            let validCache = UpdaterRuleFixture.data(revision: 3)
            defaults.set(validCache, forKey: UpdaterRuleStore.cacheKey)
            let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults, loader: { request, _ in
                (data, HTTPURLResponse(url: responseURL ?? request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            await store.refreshIfNeeded(force: true)
            XCTAssertEqual(store.snapshot.revision, 3)
            XCTAssertEqual(defaults.data(forKey: UpdaterRuleStore.cacheKey), validCache)
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
    }

    func testInvalidOrOlderCacheFallsBackToBundledRevision() {
        for data in [Data("broken".utf8), UpdaterRuleFixture.data(schemaVersion: 2, revision: 20),
                     UpdaterRuleFixture.data(revision: 1)] {
            let defaults = temporaryDefaults()
            defaults.set(data, forKey: UpdaterRuleStore.cacheKey)
            let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(revision: 4), defaults: defaults)
            XCTAssertEqual(store.snapshot.revision, 4)
            XCTAssertNotNil(store.snapshot.officialSource(bundleIdentifier: "com.example.App"))
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
    }

    func testRefreshCannotRollBackOrReplaceTheCurrentRevision() async {
        for remoteRevision in [2, 3] {
            let defaults = temporaryDefaults()
            let validCache = UpdaterRuleFixture.data(revision: 3, officialSources: [UpdaterRuleFixture.official()])
            defaults.set(validCache, forKey: UpdaterRuleStore.cacheKey)
            let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults, loader: { request, _ in
                Self.response(UpdaterRuleFixture.data(revision: remoteRevision), request: request)
            })
            await store.refreshIfNeeded(force: true)
            XCTAssertEqual(store.snapshot.revision, 3)
            XCTAssertNotNil(store.snapshot.officialSource(bundleIdentifier: "com.example.App"))
            XCTAssertEqual(defaults.data(forKey: UpdaterRuleStore.cacheKey), validCache)
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
    }

    func testRefreshIsThrottledForSixHoursAndForceBypassesTheInterval() async {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let clock = RuleTestClock()
        let loader = RuleTestLoader()
        let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults,
                                    loader: { request, _ in await loader.load(request) }, clock: { clock.now })
        await store.refreshIfNeeded()
        XCTAssertEqual(store.snapshot.revision, 2)
        clock.advance(6 * 60 * 60 - 1)
        await store.refreshIfNeeded()
        XCTAssertEqual(store.snapshot.revision, 2)
        clock.advance(1)
        await store.refreshIfNeeded()
        XCTAssertEqual(store.snapshot.revision, 3)
        await store.refreshIfNeeded(force: true)
        XCTAssertEqual(store.snapshot.revision, 4)
    }

    func testRestartPreservesRefreshInterval() async {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let clock = RuleTestClock()
        let first = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults, loader: { request, _ in
            Self.response(UpdaterRuleFixture.data(revision: 3), request: request)
        }, clock: { clock.now })
        await first.refreshIfNeeded()
        let restarted = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults, loader: { request, _ in
            Self.response(UpdaterRuleFixture.data(revision: 4), request: request)
        }, clock: { clock.now })
        await restarted.refreshIfNeeded()
        XCTAssertEqual(restarted.snapshot.revision, 3)
        clock.advance(6 * 60 * 60)
        await restarted.refreshIfNeeded()
        XCTAssertEqual(restarted.snapshot.revision, 4)
    }

    func testFailedAttemptIsThrottledAndForceCanRecoverImmediately() async {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let loader = RecoveringRuleTestLoader()
        let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults,
                                    loader: { request, _ in try await loader.load(request) })
        await store.refreshIfNeeded()
        XCTAssertEqual(store.snapshot.revision, 1)
        await store.refreshIfNeeded()
        XCTAssertEqual(store.snapshot.revision, 1)
        await store.refreshIfNeeded(force: true)
        XCTAssertEqual(store.snapshot.revision, 2)
    }

    func testConcurrentRefreshesShareOneRequestAndSnapshotDoesNotMutate() async {
        let defaults = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let loader = RuleTestLoader(delayNanoseconds: 50_000_000)
        let store = UpdaterRuleStore(bundledRules: UpdaterRuleFixture.rules(), defaults: defaults,
                                    loader: { request, _ in await loader.load(request) })
        let before = store.snapshot
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await store.refreshIfNeeded(force: true) } }
        }
        XCTAssertEqual(before.revision, 1)
        XCTAssertNotNil(before.officialSource(bundleIdentifier: "com.example.App"))
        XCTAssertEqual(store.snapshot.revision, 2)
        XCTAssertNil(store.snapshot.officialSource(bundleIdentifier: "com.example.App"))
    }

    private let defaultsSuite = "UpdaterRuleStoreTests.\(UUID().uuidString)"

    private func temporaryDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        return defaults
    }

    private static func response(_ data: Data, request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor RuleTestLoader {
    private var revision = 1
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) { self.delayNanoseconds = delayNanoseconds }

    func load(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        revision += 1
        let next = revision
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        return (UpdaterRuleFixture.data(revision: next),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor RecoveringRuleTestLoader {
    private var attempted = false

    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if !attempted {
            attempted = true
            throw URLError(.notConnectedToInternet)
        }
        return (UpdaterRuleFixture.data(revision: 2),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class RuleTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}
