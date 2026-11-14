import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// Records every request (URL, offset, If-Range, bearer) and answers from a script. No network.
private final class RecordingTransport: BearerDownloadTransport, @unchecked Sendable {
    struct Seen: Equatable { let url: URL; let offset: Int64; let ifRange: String?; let bearer: String? }
    enum Reply { case status(Int, retryAfter: TimeInterval? = nil), serve(Data) }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var seen: [Seen] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func open(_ url: URL, from offset: Int64, ifRange validator: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>) {
        try await open(url, from: offset, ifRange: validator, bearer: nil)
    }

    func open(_ url: URL, from offset: Int64, ifRange validator: String?, bearer: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>) {
        let reply: Reply = lock.withLock {
            seen.append(Seen(url: url, offset: offset, ifRange: validator, bearer: bearer))
            return replies.isEmpty ? .status(500) : replies.removeFirst()
        }
        switch reply {
        case .status(let code, let retryAfter):
            let body = AsyncThrowingStream<Data, Error> { $0.yield(Data("{}".utf8)); $0.finish() }
            return (TransportResponse(statusCode: code, retryAfter: retryAfter), body)
        case .serve(let data):
            let slice = offset > 0 ? data.subdata(in: Int(offset)..<data.count) : data
            let body = AsyncThrowingStream<Data, Error> { $0.yield(slice); $0.finish() }
            return (TransportResponse(statusCode: offset > 0 ? 206 : 200, validator: "\"etag-1\""), body)
        }
    }
}

/// Hands out tokens from a list; records what it was asked to reject.
private final class ScriptedAuthorizer: DownloadAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<String, AssetDownloadError>]
    private(set) var rejected: [String?] = []

    init(_ answers: [Result<String, AssetDownloadError>]) { self.answers = answers }

    func accessToken(rejecting: String?) async throws -> String {
        let answer = lock.withLock {
            rejected.append(rejecting)
            return answers.isEmpty ? .failure(.signInRequired) : answers.removeFirst()
        }
        return try answer.get()
    }
}

private final class NoSleepClock: DownloadClock, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sleeps: [TimeInterval] = []
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(for seconds: TimeInterval) async throws { lock.withLock { sleeps.append(seconds) } }
}

@Suite("Model downloads carry the account token")
struct AuthorizedDownloadTransportTests {
    private let modelURL = URL(string: "https://models.tryhushy.com/cleanup/hushy-cleanup-2b-v5.4-4bit/config.json")!
    private let otherURL = URL(string: "https://huggingface.co/mlx-community/Qwen3.5-2B-4bit/resolve/abc/config.json")!

    @Test("only Hushy's model host over https needs an account")
    func hostRule() {
        #expect(ModelDownloadHost.requiresAccount(modelURL))
        #expect(ModelDownloadHost.requiresAccount(URL(string: "https://MODELS.tryhushy.com/x")!))
        #expect(!ModelDownloadHost.requiresAccount(otherURL))
        #expect(!ModelDownloadHost.requiresAccount(URL(string: "http://models.tryhushy.com/x")!))
        #expect(!ModelDownloadHost.requiresAccount(URL(string: "https://models.tryhushy.com.evil.example/x")!))
        // Every Hushy model in the registry is on that host.
        for entry in ModelRegistry.entries where entry.id.hasPrefix("hushy-") {
            #expect(entry.files.allSatisfy { ModelDownloadHost.requiresAccount($0.remoteURL) })
        }
    }

    @Test("a model request carries the token; any other host gets none and the authorizer is not asked")
    func sendsTokenToModelHostOnly() async throws {
        let base = RecordingTransport([.status(200), .status(200)])
        let authorizer = ScriptedAuthorizer([.success("token-1")])
        let transport = AuthorizedDownloadTransport(base: base, authorizer: authorizer)
        _ = try await transport.open(modelURL, from: 0, ifRange: nil)
        _ = try await transport.open(otherURL, from: 0, ifRange: nil)
        #expect(base.seen.map(\.bearer) == ["token-1", nil])
        #expect(authorizer.rejected == [nil])
    }

    @Test("a resume keeps its range and validator with the token")
    func resumeKeepsRange() async throws {
        let base = RecordingTransport([.status(206)])
        let transport = AuthorizedDownloadTransport(base: base, authorizer: ScriptedAuthorizer([.success("t")]))
        _ = try await transport.open(modelURL, from: 4_096, ifRange: "\"etag-1\"")
        #expect(base.seen == [.init(url: modelURL, offset: 4_096, ifRange: "\"etag-1\"", bearer: "t")])
    }

    @Test("signed out: no request reaches the model host and the error says sign in")
    func signedOutNeverHitsNetwork() async throws {
        let base = RecordingTransport([])
        let transport = AuthorizedDownloadTransport(base: base, authorizer: ScriptedAuthorizer([.failure(.signInRequired)]))
        await #expect(throws: AssetDownloadError.signInRequired) { _ = try await transport.open(modelURL, from: 0, ifRange: nil) }
        #expect(base.seen.isEmpty)
    }

    @Test("a 401 gets one fresh token and one more try")
    func refreshOn401() async throws {
        let base = RecordingTransport([.status(401), .status(200)])
        let authorizer = ScriptedAuthorizer([.success("old"), .success("new")])
        let (head, _) = try await AuthorizedDownloadTransport(base: base, authorizer: authorizer).open(modelURL, from: 0, ifRange: nil)
        #expect(head.statusCode == 200)
        #expect(base.seen.map(\.bearer) == ["old", "new"])
        #expect(authorizer.rejected == [nil, "old"])
    }

    @Test("a second 401, or no newer token, means sign in again")
    func twice401IsSignIn() async throws {
        let twice = RecordingTransport([.status(401), .status(401)])
        await #expect(throws: AssetDownloadError.signInRequired) {
            _ = try await AuthorizedDownloadTransport(base: twice, authorizer: ScriptedAuthorizer([.success("a"), .success("b")]))
                .open(modelURL, from: 0, ifRange: nil)
        }
        #expect(twice.seen.count == 2)
        let same = RecordingTransport([.status(401)])
        await #expect(throws: AssetDownloadError.signInRequired) {
            _ = try await AuthorizedDownloadTransport(base: same, authorizer: ScriptedAuthorizer([.success("a"), .success("a")]))
                .open(modelURL, from: 0, ifRange: nil)
        }
        #expect(same.seen.count == 1)
    }

    @Test("the request carries Authorization only when given a token, and a redirect to another host drops it")
    func requestAndRedirect() {
        let signed = URLSessionDownloadTransport.request(for: modelURL, from: 10, ifRange: "\"e\"", bearer: "tok")
        #expect(signed.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(signed.value(forHTTPHeaderField: "Range") == "bytes=10-")
        #expect(signed.value(forHTTPHeaderField: "If-Range") == "\"e\"")
        #expect(URLSessionDownloadTransport.request(for: otherURL, from: 0, ifRange: nil).value(forHTTPHeaderField: "Authorization") == nil)

        var elsewhere = URLRequest(url: URL(string: "https://cdn.example/file")!)
        elsewhere.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        #expect(URLSessionDownloadTransport.redirect(elsewhere, from: signed).value(forHTTPHeaderField: "Authorization") == nil)
        var sameHost = URLRequest(url: URL(string: "https://models.tryhushy.com/cleanup/x/y")!)
        sameHost.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        #expect(URLSessionDownloadTransport.redirect(sameHost, from: signed).value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("Retry-After is read as seconds; a date or junk is ignored")
    func retryAfterParsing() throws {
        func response(_ value: String?) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: modelURL, statusCode: 429, httpVersion: nil,
                                         headerFields: value.map { ["Retry-After": $0] } ?? [:]))
        }
        #expect(URLSessionDownloadTransport.retryAfter(from: try response("3600")) == 3600)
        #expect(URLSessionDownloadTransport.retryAfter(from: try response("Wed, 21 Oct 2026 07:28:00 GMT")) == nil)
        #expect(URLSessionDownloadTransport.retryAfter(from: try response(nil)) == nil)
        #expect(URLSessionDownloadTransport.retryAfter(from: try response("-5")) == nil)
    }
}

@Suite("Downloader: sign-in and limits from the model host")
struct AssetDownloaderAccountTests {
    private let body = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    private var file: DownloadableAsset.File {
        DownloadableAsset.File(
            remoteURL: URL(string: "https://models.tryhushy.com/cleanup/hushy-cleanup-2b-v5.4-4bit/model.bin")!,
            relativePath: "model.bin", bytes: Int64(body.count),
            sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-auth-dl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func downloader(_ base: RecordingTransport, _ authorizer: ScriptedAuthorizer, clock: NoSleepClock) -> AssetDownloader {
        AssetDownloader(
            transport: AuthorizedDownloadTransport(base: base, authorizer: authorizer), clock: clock,
            backoff: RetryBackoff(initialDelay: 1, multiplier: 2, maximumDelay: 8, maximumAttempts: 3, jitter: 0))
    }

    @Test("signed out stops at once: no retries, no sleeps, nothing on disk")
    func signedOutIsNotRetried() async throws {
        let base = RecordingTransport([])
        let clock = NoSleepClock()
        let directory = tempDirectory()
        await #expect(throws: AssetDownloadError.signInRequired) {
            try await downloader(base, ScriptedAuthorizer([.failure(.signInRequired)]), clock: clock).fetch(file, into: directory)
        }
        #expect(base.seen.isEmpty)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("a long Retry-After on 429 is a limit to wait out; a short one is retried")
    func limitVersusHiccup() async throws {
        let limited = RecordingTransport([.status(429, retryAfter: 40_000)])
        let clock = NoSleepClock()
        await #expect(throws: AssetDownloadError.rateLimited(retryAfter: 40_000)) {
            try await downloader(limited, ScriptedAuthorizer([.success("t")]), clock: clock).fetch(file, into: tempDirectory())
        }
        #expect(limited.seen.count == 1)
        #expect(clock.sleeps.isEmpty)

        let burst = RecordingTransport([.status(429, retryAfter: 60), .serve(body)])
        let burstClock = NoSleepClock()
        let url = try await downloader(burst, ScriptedAuthorizer([.success("t"), .success("t")]), clock: burstClock)
            .fetch(file, into: tempDirectory())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(burst.seen.count == 2)
        #expect(burstClock.sleeps.count == 1)
    }

    @Test("an account service outage is retried with backoff, then the token is used")
    func accountOutageIsRetried() async throws {
        let base = RecordingTransport([.serve(body)])
        let clock = NoSleepClock()
        let authorizer = ScriptedAuthorizer([.failure(.accountUnavailable), .success("t")])
        _ = try await downloader(base, authorizer, clock: clock).fetch(file, into: tempDirectory())
        #expect(clock.sleeps.count == 1)
        #expect(base.seen.map(\.bearer) == ["t"])
    }

    @Test("a refused session mid-download keeps the bytes for the resume after sign-in")
    func partialSurvivesSignOut() async throws {
        let directory = tempDirectory()
        let destination = directory.appendingPathComponent(file.relativePath)
        try body.prefix(4_000).write(to: AssetDownloader.partialURL(for: destination))
        try "\"etag-1\"".write(to: AssetDownloader.validatorURL(for: destination), atomically: true, encoding: .utf8)
        await #expect(throws: AssetDownloadError.signInRequired) {
            try await downloader(RecordingTransport([.status(401), .status(401)]),
                                 ScriptedAuthorizer([.success("a"), .success("b")]), clock: NoSleepClock()).fetch(file, into: directory)
        }
        #expect(AssetDownloader.size(of: AssetDownloader.partialURL(for: destination)) == 4_000)

        let resumed = RecordingTransport([.serve(body)])
        _ = try await downloader(resumed, ScriptedAuthorizer([.success("c")]), clock: NoSleepClock()).fetch(file, into: directory)
        #expect(resumed.seen == [.init(url: file.remoteURL, offset: 4_000, ifRange: "\"etag-1\"", bearer: "c")])
        #expect(try Data(contentsOf: destination) == body)
    }
}

@Suite("Account authorizer for model downloads", .serialized)
struct AccountDownloadAuthorizerTests {
    private func session(_ access: String, expires: Date = .distantFuture) -> AccountSession {
        AccountSession(userID: "person", accessToken: access, refreshToken: "r-\(access)", expiresAt: expires, email: nil)
    }

    @Test("no session is sign in; a good one hands over its token")
    func signedOutAndIn() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        let keeper = AccountSessionKeeper(store: store) { _ in throw AccountError.requestFailed }
        await #expect(throws: AssetDownloadError.signInRequired) { _ = try await AccountDownloadAuthorizer(keeper: keeper).accessToken(rejecting: nil) }
        try store.save(session("a1"))
        #expect(try await AccountDownloadAuthorizer(keeper: keeper).accessToken(rejecting: nil) == "a1")
    }

    @Test("the gate's in-memory session is used when the store has none")
    func fallback() async throws {
        let keeper = AccountSessionKeeper(store: AccountSessionStore(keys: InMemoryKeyStore())) { _ in throw AccountError.requestFailed }
        let held = session("mem")
        #expect(try await AccountDownloadAuthorizer(keeper: keeper, fallback: { held }).accessToken(rejecting: nil) == "mem")
    }

    @Test("a refused token is replaced by a refresh; a refused refresh is sign in; an outage is not")
    func refreshOutcomes() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1"))
        let renewing = AccountSessionKeeper(store: store) { _ in AccountSession(userID: "person", accessToken: "a2", refreshToken: "r2", expiresAt: .distantFuture, email: nil) }
        #expect(try await AccountDownloadAuthorizer(keeper: renewing).accessToken(rejecting: "a1") == "a2")

        let refusedStore = AccountSessionStore(keys: InMemoryKeyStore())
        try refusedStore.save(session("x", expires: .distantPast))
        let refusing = AccountSessionKeeper(store: refusedStore) { _ in throw AccountError.httpStatus(400) }
        await #expect(throws: AssetDownloadError.signInRequired) { _ = try await AccountDownloadAuthorizer(keeper: refusing).accessToken(rejecting: nil) }

        let downStore = AccountSessionStore(keys: InMemoryKeyStore())
        try downStore.save(session("y", expires: .distantPast))
        let down = AccountSessionKeeper(store: downStore) { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: AssetDownloadError.accountUnavailable) { _ = try await AccountDownloadAuthorizer(keeper: down).accessToken(rejecting: nil) }
    }
}
