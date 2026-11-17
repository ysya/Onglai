import Foundation
import Darwin

/// Compatibility transport for public downloads rejected by URLSession with HTTP 403.
/// Redirects are followed here, never by curl, so each URL is checked before use.
enum NativeCurlDownload {
    typealias Progress = @Sendable (Double) -> Void
    struct Reply: Sendable {
        let statusCode: Int
        let exitCode: Int
        let headers: [String: [String]]
    }
    typealias Transfer = @Sendable (URL, URL, Int64, TimeInterval, @escaping Progress) throws -> Reply
    private static let maximumHeaderBytes = 256 * 1024

    static func fetch(from url: URL, to destination: URL,
                      maximumBytes: Int64 = NativeArtifactDownload.maximumBytes, timeout: TimeInterval = 1800,
                      progress: @escaping Progress,
                      transfer: Transfer = { url, file, limit, timeout, progress in
                          try performTransfer(url, to: file, limit: limit, timeout: timeout, progress: progress)
                      }) throws {
        guard NativeArtifactDownload.isSafeURL(url), maximumBytes > 0,
              maximumBytes <= NativeArtifactDownload.maximumBytes else {
            throw NativeInstallError.invalidPayload("The download requires a credential-free HTTPS URL and a bounded archive.")
        }
        guard timeout.isFinite, timeout > 0, timeout <= 1800 else { throw URLError(.timedOut) }
        try Task.checkCancellation()
        let manager = FileManager.default
        let workspace = destination.deletingLastPathComponent().appendingPathComponent(".native-curl-\(UUID().uuidString)")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: workspace) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var current = url
        var received: Int64 = 0
        for hop in 0...8 {
            try Task.checkCancellation()
            let remainingTime = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingTime > 0 else { throw URLError(.timedOut) }
            let remainingBytes = maximumBytes - received
            guard remainingBytes > 0 else { throw oversized() }
            let body = workspace.appendingPathComponent("body-\(hop)")
            let reply = try transfer(current, body, remainingBytes, remainingTime, progress)
            var info = stat()
            guard lstat(body.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1, info.st_size >= 0 else { throw invalidResponse() }
            guard info.st_size <= remainingBytes else { throw oversized() }
            received += info.st_size
            if reply.exitCode != 0 && !(reply.exitCode == 22 && (400...599).contains(reply.statusCode)) {
                switch reply.exitCode {
                case 6: throw URLError(.cannotFindHost)
                case 7: throw URLError(.cannotConnectToHost)
                case 23: throw URLError(.cannotWriteToFile)
                case 28: throw URLError(.timedOut)
                case 35: throw URLError(.secureConnectionFailed)
                case 60: throw URLError(.serverCertificateUntrusted)
                case 63: throw oversized()
                default: throw URLError(.networkConnectionLost)
                }
            }
            if reply.statusCode == 200 {
                guard info.st_size > 0 else { throw NativeInstallError.invalidPayload("The downloaded archive is empty.") }
                try Task.checkCancellation()
                // rename replaces the empty rejected payload atomically; it never follows a destination symlink.
                guard rename(body.path, destination.path) == 0 else { throw posixError() }
                progress(1)
                return
            }
            if [301, 302, 303, 307, 308].contains(reply.statusCode) {
                guard hop < 8, let locations = reply.headers["location"], locations.count == 1,
                      !locations[0].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let next = URL(string: locations[0], relativeTo: current)?.absoluteURL,
                      NativeArtifactDownload.isSafeURL(next) else {
                    throw NativeInstallError.invalidPayload("The update redirected to an unsafe download location.")
                }
                try manager.removeItem(at: body)
                current = next
                continue
            }
            if [408, 425, 429].contains(reply.statusCode) || (500...599).contains(reply.statusCode) {
                throw NativeArtifactDownload.RetryableHTTPError(statusCode: reply.statusCode)
            }
            throw NativeInstallError.invalidPayload(String(localized: "The download server returned HTTP \(reply.statusCode)."))
        }
    }

    static func parseReply(_ data: Data) throws -> Reply {
        guard data.count <= maximumHeaderBytes, let text = String(data: data, encoding: .isoLatin1) else { throw invalidResponse() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let markerIndex = lines.lastIndex(where: { $0.hasPrefix("ONGLAI_CURL_RESULT:") }) else { throw invalidResponse() }
        let marker = lines[markerIndex]
        let values = marker.split(separator: ":", omittingEmptySubsequences: false)
        guard values.count == 3, let status = Int(values[1]), let code = Int(values[2]),
              (100...599).contains(status) || (status == 0 && code != 0), (0...255).contains(code) else { throw invalidResponse() }
        var headerStatus: Int?
        var headers: [String: [String]] = [:]
        var readingHeaders = false
        for line in lines[..<markerIndex] {
            if line.hasPrefix("HTTP/") {
                let pieces = line.split(separator: " ", omittingEmptySubsequences: true)
                guard pieces.count >= 2, let value = Int(pieces[1]), (100...599).contains(value) else { throw invalidResponse() }
                headerStatus = value
                headers.removeAll()
                readingHeaders = true
            } else if line.isEmpty {
                readingHeaders = false
            } else if readingHeaders {
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw invalidResponse() }
                let name = String(line[..<colon]).lowercased()
                guard !name.isEmpty, name.unicodeScalars.allSatisfy({
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~").contains($0)
                }) else { throw invalidResponse() }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name, default: []].append(value)
            }
        }
        guard status == 0 || headerStatus == status else { throw invalidResponse() }
        return Reply(statusCode: status, exitCode: code, headers: headers)
    }

    private static func performTransfer(_ url: URL, to body: URL, limit: Int64, timeout: TimeInterval,
                                        progress: @escaping Progress) throws -> Reply {
        try Task.checkCancellation()
        let outputFD = open(body.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        let metadataURL = body.appendingPathExtension("headers")
        let metadataFD = open(metadataURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard metadataFD >= 0 else { throw posixError() }
        let metadata = FileHandle(fileDescriptor: metadataFD, closeOnDealloc: true)
        defer { try? metadata.close(); try? FileManager.default.removeItem(at: metadataURL) }

        let arguments = ["--disable", "--globoff", "--silent", "--fail", "--proto", "=https", "--disallow-username-in-url",
                         "--connect-timeout", String(min(30, timeout)), "--max-time", String(timeout),
                         "--max-filesize", String(limit), "--max-redirs", "0", "--header", "Accept: application/octet-stream",
                         "--dump-header", "/dev/stderr", "--output", "-", "--write-out",
                         "%{stderr}\nONGLAI_CURL_RESULT:%{http_code}:%{exitcode}\n", "--url", url.absoluteString]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // macOS sh uses 1024-byte units; a shell using POSIX 512-byte units applies a stricter bound.
        // Fixed source only: URLs remain separate, quoted argv values.
        process.arguments = ["-c", "ulimit -f \"$1\" || exit 125; shift; exec /usr/bin/curl \"$@\"", "native-curl", String(limit / 1024)] + arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "POSIXLY_CORRECT": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = metadata
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            try process.run()
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                let size = try fileSize(outputFD)
                guard size <= limit, try fileSize(metadataFD) <= maximumHeaderBytes else { throw oversized() }
                if let expected = expectedLength(at: metadataURL), expected > 0 {
                    progress(min(1, Double(size) / Double(expected)))
                }
                usleep(20_000)
            }
            process.waitUntilExit()
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                usleep(50_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGXFSZ { throw oversized() }
        try metadata.seek(toOffset: 0)
        let data = try metadata.read(upToCount: maximumHeaderBytes + 1) ?? Data()
        let reply = try parseReply(data)
        guard process.terminationReason == .exit, process.terminationStatus == Int32(reply.exitCode) else { throw invalidResponse() }
        return reply
    }

    private static func expectedLength(at url: URL) -> Int64? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumHeaderBytes + 1), data.count <= maximumHeaderBytes,
              let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let status = lines.lastIndex(where: { $0.hasPrefix("HTTP/") }),
              lines[status].split(separator: " ").dropFirst().first == "200",
              let line = lines[status...].first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let colon = line.firstIndex(of: ":") else { return nil }
        return Int64(line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func fileSize(_ fd: Int32) throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else { throw posixError() }
        return info.st_size
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func oversized() -> NativeInstallError { .invalidPayload("The download exceeds the archive size limit.") }
    private static func invalidResponse() -> NativeInstallError { .invalidPayload("The system download tool returned invalid response metadata.") }
}
