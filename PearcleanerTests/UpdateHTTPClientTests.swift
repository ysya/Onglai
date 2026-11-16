import XCTest
@testable import Pearcleaner

final class UpdateHTTPClientTests: XCTestCase {
    func testRejectsInsecureAndCredentialBearingURLsBeforeRequesting() async {
        var credentialURL = URLComponents(string: "https://example.com/feed")!
        credentialURL.user = "fixture-user"
        credentialURL.password = "fixture-value"
        for url in [URL(string: "http://example.com/feed")!, credentialURL.url!] {
            do {
                _ = try await UpdateHTTPClient.data(from: url, maximumBytes: 1024)
                XCTFail("Unsafe metadata URL was accepted")
            } catch UpdateHTTPClient.Error.invalidURL {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsOversizedResponseUsingHeaders() async throws {
        let session = makeSession(status: 200, headers: ["Content-Length": "2048"], body: Data())
        defer { session.invalidateAndCancel() }
        do {
            _ = try await UpdateHTTPClient.response(
                for: URLRequest(url: URL(string: "https://example.com/feed")!), maximumBytes: 1024, session: session
            )
            XCTFail("Oversized metadata was accepted")
        } catch UpdateHTTPClient.Error.documentTooLarge {
        }
    }

    func testRejectsOversizedResponseWithoutContentLength() async throws {
        let session = makeSession(status: 200, headers: [:], body: Data(repeating: 65, count: 2048))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await UpdateHTTPClient.response(
                for: URLRequest(url: URL(string: "https://example.com/feed")!), maximumBytes: 1024, session: session
            )
            XCTFail("Unbounded metadata was accepted")
        } catch UpdateHTTPClient.Error.documentTooLarge {
        }
    }

    func testHeadReadsHeadersWithoutRejectingLargeInstallerSize() async throws {
        let session = makeSession(status: 200, headers: ["Content-Length": "250000000", "Content-Disposition": "attachment; filename=App-2.0.dmg"], body: Data())
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://example.com/latest")!)
        request.httpMethod = "HEAD"
        let (data, response) = try await UpdateHTTPClient.response(for: request, maximumBytes: 0, session: session)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Disposition"), "attachment; filename=App-2.0.dmg")
    }

    func testHTTPFailureDoesNotLookLikeEmptySuccessfulMetadata() async throws {
        let session = makeSession(status: 401, headers: [:], body: Data())
        defer { session.invalidateAndCancel() }
        do {
            _ = try await UpdateHTTPClient.response(
                for: URLRequest(url: URL(string: "https://example.com/feed")!), maximumBytes: 1024, session: session
            )
            XCTFail("HTTP failure was accepted")
        } catch UpdateHTTPClient.Error.httpStatus(let status) {
            XCTAssertEqual(status, 401)
        }
    }

    private func makeSession(status: Int, headers: [String: String], body: Data) -> URLSession {
        MetadataURLProtocol.response = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MetadataURLProtocol: URLProtocol {
    static var response: ((URLRequest) -> (HTTPURLResponse, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (response, body) = Self.response(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
