import XCTest
@testable import Pearcleaner

final class NativeArtifactDownloadTests: XCTestCase {
    func testForbiddenDownloadUsesFallbackExactlyOnceAndKeepsTheSameURL() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("native-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureURLProtocol.self]
        let calls = NativeFallbackCalls()
        let url = URL(string: "https://fixture.invalid/403?release=exact")!
        let download = NativeArtifactDownload(destination: destination, configuration: configuration, fallback: { requested, output, progress in
            calls.record(requested)
            try Data("fallback".utf8).write(to: output)
            progress(1)
        }, progress: { _ in })
        try await download.fetch(url)
        XCTAssertEqual(calls.urls, [url])
        XCTAssertEqual(try Data(contentsOf: destination), Data("fallback".utf8))
    }

    func testFallbackIsNotUsedForOtherFailuresOrSuccessfulDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-no-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureURLProtocol.self]
        let calls = NativeFallbackCalls()
        for path in ["ok", "404", "429", "503", "oversize", "unsafe-response", "invalid-response"] {
            let download = NativeArtifactDownload(destination: root.appendingPathComponent(path), configuration: configuration, fallback: { url, _, _ in
                calls.record(url)
                XCTFail("Fallback was triggered for \(url.lastPathComponent)")
            }, progress: { _ in })
            do { try await download.fetch(URL(string: "https://fixture.invalid/\(path)")!) }
            catch { XCTAssertNotEqual(path, "ok") }
        }
        XCTAssertTrue(calls.urls.isEmpty)
    }

    func testCancellingWhileFallbackRunsCancelsItsTaskWithoutReportingSuccess() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("native-fallback-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureURLProtocol.self]
        let started = expectation(description: "Fallback started")
        let download = NativeArtifactDownload(destination: destination, configuration: configuration, fallback: { _, _, _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            XCTFail("Cancelled fallback must not finish normally")
        }, progress: { _ in })
        let task = Task { try await download.fetch(URL(string: "https://fixture.invalid/403")!) }
        await fulfillment(of: [started], timeout: 2)
        download.cancel()
        do { try await task.value; XCTFail("Cancelled fallback reported success") }
        catch is CancellationError { }
    }
    func testRejectsCredentialBearingAndNonHTTPSLocations() {
        for location in ["http://example.test/update.zip", "file:///tmp/update.zip", "https://example.test/update.zip#fragment"] {
            XCTAssertFalse(NativeArtifactDownload.isSafeURL(URL(string: location)!))
        }
        var credentialURL = URLComponents(string: "https://example.test/update.zip")!
        credentialURL.user = "fixture-user"
        credentialURL.password = "fixture-password"
        XCTAssertFalse(NativeArtifactDownload.isSafeURL(credentialURL.url!))
        XCTAssertTrue(NativeArtifactDownload.isSafeURL(URL(string: "https://cdn.example.test/update.zip?signature=opaque")!))
    }

    func testVerifiesStreamingSHA256SHA512AndRejectsMismatch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertNoThrow(try NativeArtifactDownload.verifyDigest(.init(algorithm: .sha256, value: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), at: file))
        XCTAssertNoThrow(try NativeArtifactDownload.verifyDigest(.init(algorithm: .sha512, value: "3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw=="), at: file))
        XCTAssertThrowsError(try NativeArtifactDownload.verifyDigest(.init(algorithm: .sha256, value: String(repeating: "0", count: 64)), at: file))
    }

    func testStreamingDownloadAndOversizedHTTPResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureURLProtocol.self]
        let file = root.appendingPathComponent("payload")
        let download = NativeArtifactDownload(destination: file, configuration: configuration, fallback: nil, progress: { _ in })
        try await download.fetch(URL(string: "https://fixture.invalid/ok")!)
        XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
        for path in ["oversize", "forbidden"] {
            let rejected = NativeArtifactDownload(destination: root.appendingPathComponent(path), configuration: configuration, fallback: nil, progress: { _ in })
            do { try await rejected.fetch(URL(string: "https://fixture.invalid/\(path)")!); XCTFail("Response should be rejected") }
            catch NativeInstallError.invalidPayload { }
            catch { XCTFail("Permanent response or oversized payload must remain ineligible: \(error)") }
        }
    }

    func testTemporaryHTTPResponsesRemainRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-http-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureURLProtocol.self]
        for statusCode in [408, 425, 429, 500, 502, 503, 504, 599] {
            let download = NativeArtifactDownload(destination: root.appendingPathComponent("\(statusCode)"), configuration: configuration, fallback: nil, progress: { _ in })
            do {
                try await download.fetch(URL(string: "https://fixture.invalid/\(statusCode)")!)
                XCTFail("Temporary HTTP failure must be rejected")
            } catch let error as NativeArtifactDownload.RetryableHTTPError {
                XCTAssertEqual(error.statusCode, statusCode)
            } catch {
                XCTFail("Temporary HTTP failure must preserve retryability: \(error)")
            }
        }
    }

    func testPermanentHTTPFailureReportsItsStatusInsteadOfClaimingAnOversizedArchive() async throws {
        for statusCode in [401, 403, 404, 406] {
            let reason = try await rejectionReason(for: "\(statusCode)")
            XCTAssertTrue(reason.contains("HTTP \(statusCode)"), reason)
            XCTAssertFalse(reason.lowercased().contains("oversized"), reason)
        }
    }

    func testOversizedResponseReportsTheActualLengthAndLimit() async throws {
        let reason = try await rejectionReason(for: "oversize")
        let digits = reason.filter(\.isNumber)
        XCTAssertTrue(digits.contains("4294967297"), reason)
        XCTAssertTrue(digits.contains(String(NativeArtifactDownload.maximumBytes)), reason)
        XCTAssertFalse(reason.contains("HTTP"), reason)
    }

    func testNonHTTPResponseAndUnsafeResponseURLHaveDistinctReasons() async throws {
        let invalidHTTP = try await rejectionReason(for: "invalid-response")
        let unsafeURL = try await rejectionReason(for: "unsafe-response")
        XCTAssertNotEqual(invalidHTTP, unsafeURL)
        XCTAssertTrue(invalidHTTP.contains("HTTP"), invalidHTTP)
        XCTAssertFalse(unsafeURL.lowercased().contains("oversized"), unsafeURL)
    }

    private func rejectionReason(for path: String) async throws -> String {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("native-response-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeFixtureURLProtocol.self]
        let download = NativeArtifactDownload(destination: destination, configuration: configuration, fallback: nil, progress: { _ in })
        do {
            try await download.fetch(URL(string: "https://fixture.invalid/\(path)")!)
            XCTFail("Invalid response must be rejected")
        } catch NativeInstallError.invalidPayload(let reason) {
            return reason
        }
        return ""
    }

    func testRedirectRebuildsRequestWithoutCredentials() {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let download = NativeArtifactDownload(destination: destination, progress: { _ in })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://origin.invalid/archive.zip")!)
        var request = URLRequest(url: URL(string: "https://cdn.invalid/archive.zip")!)
        request.setValue("secret", forHTTPHeaderField: "Authorization")
        request.setValue("secret", forHTTPHeaderField: "Cookie")
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        download.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
            XCTAssertEqual(redirected?.url?.host, "cdn.invalid")
            XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(redirected?.value(forHTTPHeaderField: "Cookie"))
        }
        request.url = URL(string: "http://cdn.invalid/archive.zip")!
        download.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
            XCTAssertNil(redirected)
        }
    }

    func testCancellationBeforeDownloadCreatesNoPayload() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("native-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let download = NativeArtifactDownload(destination: destination, progress: { _ in })
        download.cancel()
        do {
            try await download.fetch(URL(string: "https://example.invalid/update.zip")!)
            XCTFail("Cancelled download must not start")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private final class NativeFallbackCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] { lock.withLock { recorded } }
    func record(_ url: URL) { lock.withLock { recorded.append(url) } }
}

private final class NativeFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let statusCode = Int(path) ?? (path == "forbidden" ? 403 : 200)
        let response: URLResponse
        if path == "invalid-response" {
            response = URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 3, textEncodingName: nil)
        } else {
            let url = path == "unsafe-response" ? URL(string: "http://fixture.invalid/archive.zip")! : request.url!
            response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": path == "oversize" ? "4294967297" : "3"])!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("abc".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
