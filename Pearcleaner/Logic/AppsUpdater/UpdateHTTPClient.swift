import Foundation

/// Shared, read-only transport for public update metadata. Installer files are
/// never downloaded here, including when a HEAD response advertises their size.
enum UpdateHTTPClient {
    enum Error: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
        case documentTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "The update metadata URL is not a public HTTPS URL")
            case .invalidResponse: return String(localized: "The update service returned an invalid response")
            case .httpStatus(let status): return String(localized: "The update service returned HTTP \(status)")
            case .documentTooLarge: return String(localized: "The update metadata document is too large")
            }
        }
    }

    static func data(from url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
        request.setValue("application/json, application/xml, text/yaml, text/plain", forHTTPHeaderField: "Accept")
        return try await response(for: request, maximumBytes: maximumBytes).0
    }

    static func response(
        for request: URLRequest,
        maximumBytes: Int,
        session: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse) {
        try validate(request.url)
        try Task.checkCancellation()
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw Error.invalidResponse }
        try validate(response.url)
        guard (200...299).contains(response.statusCode) else { throw Error.httpStatus(response.statusCode) }
        if request.httpMethod?.uppercased() == "HEAD" { return (Data(), response) }
        guard maximumBytes > 0,
              response.expectedContentLength <= Int64(maximumBytes) else { throw Error.documentTooLarge }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), maximumBytes))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw Error.documentTooLarge }
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }

    private static func validate(_ url: URL?) throws {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { throw Error.invalidURL }
    }
}
