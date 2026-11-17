import Foundation
import CryptoKit
import Darwin

/// Ephemeral, credential-free transport streams bounded response chunks directly to disk.
final class NativeArtifactDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct RetryableHTTPError: LocalizedError, Sendable {
        let statusCode: Int
        var errorDescription: String? {
            "The download server is temporarily unavailable (HTTP \(statusCode)). Try again."
        }
    }

    static let maximumBytes: Int64 = 4 * 1024 * 1024 * 1024
    private let configuration: URLSessionConfiguration
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: FileHandle?
    private var cancelled = false
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var redirects = 0
    private var failure: Error?

    init(destination: URL, configuration: URLSessionConfiguration = .ephemeral, progress: @escaping @Sendable (Double) -> Void) {
        self.configuration = configuration
        self.destination = destination
        self.progress = progress
    }

    func fetch(_ url: URL) async throws {
        guard Self.isSafeURL(url) else { throw NativeInstallError.invalidPayload("The download requires a credential-free HTTPS URL.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))); return }
            self.file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            self.continuation = continuation
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 1800
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: Self.request(url))
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              let url = response.url, Self.isSafeURL(url),
              response.expectedContentLength <= Self.maximumBytes else {
            failure = NativeInstallError.invalidPayload("The download server returned an unsupported response or an oversized archive.")
            completionHandler(.cancel)
            return
        }
        guard response.statusCode == 200 else {
            if [408, 425, 429].contains(response.statusCode) || (500...599).contains(response.statusCode) {
                failure = RetryableHTTPError(statusCode: response.statusCode)
            } else {
                failure = NativeInstallError.invalidPayload("The download server returned an unsupported response or an oversized archive.")
            }
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= Self.maximumBytes else {
            failure = NativeInstallError.invalidPayload("The download exceeds the archive size limit.")
            dataTask.cancel()
            return
        }
        do { try file?.write(contentsOf: data) }
        catch { failure = error; dataTask.cancel(); return }
        progress(expected > 0 ? min(1, Double(received) / Double(expected)) : 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 8, let url = request.url, Self.isSafeURL(url) else {
            failure = NativeInstallError.invalidPayload("The update redirected to an unsafe download location.")
            completionHandler(nil)
            task.cancel()
            return
        }
        // Rebuild on every hop: no Authorization, Cookie or original query is forwarded.
        completionHandler(Self.request(url))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try file?.synchronize(); try file?.close() }
        catch { if failure == nil { failure = error } }
        file = nil
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        let wasCancelled = cancelled
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure { continuation?.resume(throwing: failure) }
        else if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error { continuation?.resume(throwing: error) }
        else if received == 0 { continuation?.resume(throwing: NativeInstallError.invalidPayload("The downloaded archive is empty.")) }
        else { progress(1); continuation?.resume() }
    }

    static func verifyDigest(_ digest: NativeUpdateArtifact.Digest?, at url: URL) throws {
        guard let digest else { return }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha256 = SHA256()
        var sha512 = SHA512()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            switch digest.algorithm {
            case .sha256: sha256.update(data: data)
            case .sha512: sha512.update(data: data)
            }
        }
        let actual: String
        switch digest.algorithm {
        case .sha256: actual = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha512: actual = Data(sha512.finalize()).base64EncodedString()
        }
        let expected = digest.algorithm == .sha256 ? digest.value.lowercased() : digest.value
        guard actual == expected else { throw NativeInstallError.invalidPayload("The downloaded archive does not match the publisher's digest.") }
    }

    static func quarantine(_ url: URL) throws {
        let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));\(Bundle.main.bundleIdentifier ?? "native-updater");\(UUID().uuidString)"
        let status = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
        guard status == 0 else { throw NativeInstallError.invalidPayload("Cannot preserve download quarantine on this filesystem.") }
    }

    static func isSafeURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }
    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }
}
