import XCTest
import Darwin
@testable import Pearcleaner

final class NativeCurlDownloadTests: XCTestCase {
    func testManualRedirectPreservesQueryAndCountsAllResponseBodies() throws {
        let fixture = try CurlFixture()
        defer { fixture.clean() }
        let calls = CurlTransfers()
        try NativeCurlDownload.fetch(from: fixture.url, to: fixture.output, maximumBytes: 10, progress: { _ in }, transfer: { url, file, limit, _, _ in
            calls.record(url, limit: limit)
            if url.path == "/start" {
                try Data("r".utf8).write(to: file)
                return .init(statusCode: 302, exitCode: 0, headers: ["location": ["/archive.zip?release=exact"]])
            }
            try Data("abc".utf8).write(to: file)
            return .init(statusCode: 200, exitCode: 0, headers: [:])
        })
        XCTAssertEqual(calls.urls.map(\.absoluteString), [fixture.url.absoluteString, "https://fixture.invalid/archive.zip?release=exact"])
        XCTAssertEqual(calls.limits, [10, 9])
        XCTAssertEqual(try Data(contentsOf: fixture.output), Data("abc".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["payload"])
    }

    func testUnsafeOrAmbiguousRedirectIsRejectedBeforeAnotherRequest() throws {
        var credentials = URLComponents(string: "https://fixture.invalid/archive.zip")!
        credentials.user = "fixture-user"
        credentials.password = "fixture-value"
        for locations in [["http://fixture.invalid/archive.zip"], [credentials.url!.absoluteString], ["https://fixture.invalid/archive.zip#fragment"], ["/one", "/two"]] {
            let fixture = try CurlFixture()
            defer { fixture.clean() }
            let calls = CurlTransfers()
            XCTAssertThrowsError(try NativeCurlDownload.fetch(from: fixture.url, to: fixture.output, progress: { _ in }, transfer: { url, file, limit, _, _ in
                calls.record(url, limit: limit)
                try Data().write(to: file)
                return .init(statusCode: 302, exitCode: 0, headers: ["location": locations])
            }))
            XCTAssertEqual(calls.urls.count, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.output), Data("original".utf8))
        }
    }

    func testRedirectLoopIsBoundedAtEightRedirects() throws {
        let fixture = try CurlFixture()
        defer { fixture.clean() }
        let calls = CurlTransfers()
        XCTAssertThrowsError(try NativeCurlDownload.fetch(from: fixture.url, to: fixture.output, progress: { _ in }, transfer: { url, file, limit, _, _ in
            calls.record(url, limit: limit)
            try Data().write(to: file)
            return .init(statusCode: 302, exitCode: 0, headers: ["location": ["/again"]])
        }))
        XCTAssertEqual(calls.urls.count, 9)
        XCTAssertEqual(try Data(contentsOf: fixture.output), Data("original".utf8))
    }

    func testAggregateBudgetRejectsOversizedFinalBodyWithoutReplacingDestination() throws {
        let fixture = try CurlFixture()
        defer { fixture.clean() }
        let calls = CurlTransfers()
        XCTAssertThrowsError(try NativeCurlDownload.fetch(from: fixture.url, to: fixture.output, maximumBytes: 5, progress: { _ in }, transfer: { url, file, limit, _, _ in
            calls.record(url, limit: limit)
            if url.path == "/start" {
                try Data("ab".utf8).write(to: file)
                return .init(statusCode: 302, exitCode: 0, headers: ["location": ["/final"]])
            }
            try Data("cdef".utf8).write(to: file)
            return .init(statusCode: 200, exitCode: 0, headers: [:])
        }))
        XCTAssertEqual(calls.limits, [5, 3])
        XCTAssertEqual(try Data(contentsOf: fixture.output), Data("original".utf8))
    }

    func testHTTPAndTransportFailuresKeepTheirRetryClassification() throws {
        for status in [403, 404, 408, 425, 429, 500, 503] {
            let fixture = try CurlFixture()
            defer { fixture.clean() }
            do {
                try NativeCurlDownload.fetch(from: fixture.url, to: fixture.output, progress: { _ in }, transfer: { _, file, _, _, _ in
                    try Data().write(to: file)
                    return .init(statusCode: status, exitCode: 22, headers: [:])
                })
                XCTFail("HTTP failure accepted")
            } catch let error as NativeArtifactDownload.RetryableHTTPError {
                XCTAssertTrue([408, 425, 429, 500, 503].contains(status))
                XCTAssertEqual(error.statusCode, status)
            } catch NativeInstallError.invalidPayload(let reason) {
                XCTAssertTrue([403, 404].contains(status))
                XCTAssertTrue(reason.contains("HTTP \(status)"))
            }
        }
        let fixture = try CurlFixture()
        defer { fixture.clean() }
        do {
            try NativeCurlDownload.fetch(from: fixture.url, to: fixture.output, progress: { _ in }, transfer: { _, file, _, _, _ in
                try Data().write(to: file)
                return .init(statusCode: 0, exitCode: 28, headers: [:])
            })
            XCTFail("Timeout accepted")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testResponseParserUsesLastHeaderBlockAndRejectsMalformedMetadata() throws {
        let reply = try NativeCurlDownload.parseReply(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/2 302 Found\r\nLocation: /release?token=public\r\nSet-Cookie: fixture=ignored\r\n\r\nONGLAI_CURL_RESULT:302:0\n".utf8))
        XCTAssertEqual(reply.statusCode, 302)
        XCTAssertEqual(reply.headers["location"], ["/release?token=public"])
        for text in ["HTTP/2 200\r\n\r\n", "HTTP/2 403\r\n\r\nONGLAI_CURL_RESULT:200:0\n", "HTTP/2 302\r\nLocation: /one\r\n /two\r\n\r\nONGLAI_CURL_RESULT:302:0\n"] {
            XCTAssertThrowsError(try NativeCurlDownload.parseReply(Data(text.utf8)))
        }
        XCTAssertThrowsError(try NativeCurlDownload.parseReply(Data(repeating: 65, count: 262_145)))
    }

    func testCancellingStopsTheRunningSystemCurlProcess() async throws {
        let fixture = try CurlFixture()
        defer { fixture.clean() }
        let connected = expectation(description: "System curl connected")
        let server = try CurlHandshakeFixture { connected.fulfill() }
        defer { server.stop() }
        let task = Task.detached {
            try NativeCurlDownload.fetch(from: server.url, to: fixture.output, progress: { _ in })
        }
        await fulfillment(of: [connected], timeout: 5)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { try await task.value; XCTFail("Cancelled process reported success") }
        catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.output), Data("original".utf8))
    }
}

private struct CurlFixture {
    let root: URL
    let output: URL
    let url = URL(string: "https://fixture.invalid/start")!
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-curl-tests-\(UUID().uuidString)")
        output = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: output)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class CurlTransfers: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(URL, Int64)] = []
    var urls: [URL] { lock.withLock { requests.map(\.0) } }
    var limits: [Int64] { lock.withLock { requests.map(\.1) } }
    func record(_ url: URL, limit: Int64) { lock.withLock { requests.append((url, limit)) } }
}

/// Holds the TLS handshake open on loopback so cancellation exercises a real child process.
private final class CurlHandshakeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let listener: Int32
    private var client: Int32 = -1
    private var stopped = false
    let url: URL

    init(connected: @escaping @Sendable () -> Void) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        listener = socketFD
        guard socketFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketFD, 1) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)); close(socketFD); throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard read == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)); close(listener); throw error
        }
        url = URL(string: "https://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/payload")!
        DispatchQueue.global().async { [self] in
            let accepted = accept(listener, nil, nil)
            lock.withLock {
                if stopped { if accepted >= 0 { close(accepted) } }
                else { client = accepted }
            }
            if accepted >= 0 { connected() }
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            if client >= 0 { shutdown(client, SHUT_RDWR); close(client) }
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
    }
}
