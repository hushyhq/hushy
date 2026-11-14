import Foundation

/// Time for the downloader: real in the app, fake in tests (so backoff never actually waits).
public protocol DownloadClock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemDownloadClock: DownloadClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// The response head of one HTTP request.
public struct TransportResponse: Equatable, Sendable {
    public let statusCode: Int
    /// A strong ETag or Last-Modified: what `If-Range` sends on resume. nil when the server gave
    /// neither (resume is then unsafe and the file restarts from zero).
    public let validator: String?
    /// `Retry-After` in seconds, when the server sent one (a 429 or 503).
    public let retryAfter: TimeInterval?

    public init(statusCode: Int, validator: String? = nil, retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.validator = validator
        self.retryAfter = retryAfter
    }
}

/// The network under `AssetDownloader`, as a protocol so tests drive resume/checksum/retry with
/// a fake that never touches the network.
public protocol DownloadTransport: Sendable {
    /// Requests `url` from byte `offset` (a `Range: bytes=offset-` request carrying
    /// `If-Range: validator` when `offset > 0`). Returns the head and the body as chunks.
    func open(_ url: URL, from offset: Int64, ifRange validator: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>)
}

public enum AssetDownloadError: Error, Equatable, Sendable {
    /// A permanent HTTP failure (404, 403, …): retrying won't help.
    case http(Int)
    /// A transient HTTP failure (5xx, 429, 408): retried with backoff.
    case transientHTTP(Int)
    /// The server rejected the resume range; the partial is discarded and the file restarts.
    case rangeNotSatisfiable
    /// The body ended early; the next attempt resumes from what arrived.
    case incomplete(received: Int64, expected: Int64)
    /// More bytes than expected: the partial is discarded.
    case oversized(received: Int64, expected: Int64)
    /// The finished file's SHA-256 didn't match. Retried once from zero, then fatal.
    case checksumMismatch(path: String)
    /// Every retry failed; `lastError` describes the final one.
    case exhaustedRetries(lastError: String)
    /// The model host wants a signed-in Hushy account (no session, or the server refused the token
    /// after one refresh). Retrying will not help until the person signs in.
    case signInRequired
    /// The account could not be checked just now (the token refresh could not reach the service):
    /// retried with backoff, never shown as "signed out".
    case accountUnavailable
    /// The server's download limit for now (a 429 with a long `Retry-After`, such as the daily limit).
    /// Not retried here; the queue waits `retryAfter` seconds before it tries again.
    case rateLimited(retryAfter: TimeInterval)

    var isRetryable: Bool {
        switch self {
        case .http, .signInRequired, .rateLimited: false
        case .transientHTTP, .rangeNotSatisfiable, .incomplete, .oversized, .checksumMismatch, .accountUnavailable: true
        case .exhaustedRetries: false
        }
    }
}

/// Downloads one file of a managed asset: resumable (bytes stream into `<file>.partial`; a
/// retry — or the next launch — continues with `Range`/`If-Range`), verified (SHA-256 before the
/// file is moved into place; a mismatch is never kept), and retried with exponential backoff on
/// transient failures. Cancellation stops at once and keeps the partial for the next resume.
public struct AssetDownloader: Sendable {
    public let transport: any DownloadTransport
    public let clock: any DownloadClock
    public let backoff: RetryBackoff
    let random: @Sendable () -> Double

    public init(
        transport: any DownloadTransport, clock: any DownloadClock = SystemDownloadClock(),
        backoff: RetryBackoff = RetryBackoff(), random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.transport = transport
        self.clock = clock
        self.backoff = backoff
        self.random = random
    }

    /// A `Retry-After` longer than this (seconds) is a limit to wait out, not a hiccup to retry through.
    public static let longestRetryWait: TimeInterval = 120

    public static func partialURL(for destination: URL) -> URL { destination.appendingPathExtension("partial") }
    public static func validatorURL(for destination: URL) -> URL { partialURL(for: destination).appendingPathExtension("validator") }

    /// Fetches `file` into `directory/file.relativePath`, reporting cumulative bytes on disk for
    /// this file (resumed bytes included, so progress never dips on resume).
    @discardableResult
    public func fetch(
        _ file: DownloadableAsset.File, into directory: URL, onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        let destination = directory.appendingPathComponent(file.relativePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? FileDigest.sha256(of: destination)) == file.sha256 {
                onProgress(file.bytes)
                return destination
            }
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var retry = 0
        var checksumFailures = 0
        while true {
            try Task.checkCancellation()
            do {
                try await attempt(file, destination: destination, onProgress: onProgress)
                try verifyAndPlace(file, destination: destination)
                return destination
            } catch let error as AssetDownloadError {
                if case .checksumMismatch = error {
                    checksumFailures += 1
                    if checksumFailures > 1 { throw error }
                }
                guard error.isRetryable else { throw error }
                retry = try await waitBeforeRetry(retry, after: error)
            } catch let error as URLError where Self.isTransient(error) {
                retry = try await waitBeforeRetry(retry, after: error)
            }
        }
    }

    private func waitBeforeRetry(_ retry: Int, after error: Error) async throws -> Int {
        let next = retry + 1
        guard let delay = backoff.delay(beforeRetry: next, random: random) else {
            throw AssetDownloadError.exhaustedRetries(lastError: String(describing: error))
        }
        try await clock.sleep(for: delay)
        return next
    }

    /// One request: resume from the partial when it has a validator, else start over.
    private func attempt(
        _ file: DownloadableAsset.File, destination: URL, onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let partial = Self.partialURL(for: destination)
        let validatorURL = Self.validatorURL(for: destination)
        var offset = Self.size(of: partial)
        let validator = try? String(contentsOf: validatorURL, encoding: .utf8)
        if offset > 0, validator?.isEmpty ?? true {
            Self.discard(partial: partial, validator: validatorURL)
            offset = 0
        }
        if offset >= file.bytes, offset > 0 { return }  // body complete from an earlier run

        let (response, body) = try await transport.open(file.remoteURL, from: offset, ifRange: offset > 0 ? validator : nil)
        switch response.statusCode {
        case 206 where offset > 0:
            break
        case 200..<300:
            // Full body (range ignored, or the remote changed): restart, never splice versions.
            Self.discard(partial: partial, validator: validatorURL)
            offset = 0
            if let tag = response.validator, !tag.hasPrefix("W/") {
                try tag.write(to: validatorURL, atomically: true, encoding: .utf8)
            }
        case 416:
            Self.discard(partial: partial, validator: validatorURL)
            throw AssetDownloadError.rangeNotSatisfiable
        case 401 where ModelDownloadHost.requiresAccount(file.remoteURL):
            throw AssetDownloadError.signInRequired
        case 429 where (response.retryAfter ?? 0) > Self.longestRetryWait:
            throw AssetDownloadError.rateLimited(retryAfter: response.retryAfter ?? Self.longestRetryWait)
        case 408, 429, 500..<600:
            throw AssetDownloadError.transientHTTP(response.statusCode)
        default:
            throw AssetDownloadError.http(response.statusCode)
        }

        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var written = offset
        onProgress(written)
        for try await chunk in body {
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            onProgress(written)
        }
        try handle.truncate(atOffset: UInt64(written))
        if written < file.bytes { throw AssetDownloadError.incomplete(received: written, expected: file.bytes) }
    }

    private func verifyAndPlace(_ file: DownloadableAsset.File, destination: URL) throws {
        let partial = Self.partialURL(for: destination)
        let validatorURL = Self.validatorURL(for: destination)
        let size = Self.size(of: partial)
        guard size == file.bytes else {
            Self.discard(partial: partial, validator: validatorURL)
            throw AssetDownloadError.oversized(received: size, expected: file.bytes)
        }
        guard try FileDigest.sha256(of: partial) == file.sha256 else {
            Self.discard(partial: partial, validator: validatorURL)
            throw AssetDownloadError.checksumMismatch(path: file.relativePath)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        try? FileManager.default.removeItem(at: validatorURL)
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func discard(partial: URL, validator: URL) {
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: validator)
    }

    /// Network conditions that a retry can fix. Cancellation is deliberately not here.
    public static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable,
             .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }
}
