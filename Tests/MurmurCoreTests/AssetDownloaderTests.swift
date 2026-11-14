import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// A scripted transport: each `open` pops the next response. Records the offsets and `If-Range`
/// values it was asked for, so resume behaviour is asserted without any network.
private final class FakeTransport: DownloadTransport, @unchecked Sendable {
    enum Reply {
        /// Serve `body[offset...]` as a 206 (or the whole body as a 200 when `honourRange` is
        /// false), optionally dropping the connection after `cut` bytes.
        case serve(status: Int? = nil, honourRange: Bool = true, validator: String? = "\"etag-1\"", cut: Int? = nil)
        case status(Int)
        case fail(URLError.Code)
    }

    let body: Data
    private var replies: [Reply]
    private let lock = NSLock()
    private(set) var requests: [(offset: Int64, ifRange: String?)] = []

    init(body: Data, replies: [Reply]) {
        self.body = body
        self.replies = replies
    }

    func open(_ url: URL, from offset: Int64, ifRange validator: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>) {
        let reply: Reply = lock.withLock {
            requests.append((offset, validator))
            return replies.isEmpty ? .status(500) : replies.removeFirst()
        }
        switch reply {
        case .fail(let code):
            throw URLError(code)
        case .status(let code):
            return (TransportResponse(statusCode: code), AsyncThrowingStream { $0.finish() })
        case .serve(let status, let honourRange, let tag, let cut):
            let ranged = honourRange && offset > 0
            var slice = ranged ? body.subdata(in: Int(offset)..<body.count) : body
            let dropped = cut.map { $0 < slice.count } ?? false
            if let cut, cut < slice.count { slice = slice.prefix(cut) }
            let code = status ?? (ranged ? 206 : 200)
            let chunks = stride(from: 0, to: slice.count, by: 4096).map { slice.subdata(in: $0..<min($0 + 4096, slice.count)) }
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                if dropped {
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                } else {
                    continuation.finish()
                }
            }
            return (TransportResponse(statusCode: code, validator: tag), stream)
        }
    }
}

/// Never sleeps; records every requested delay.
private final class FakeClock: DownloadClock, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sleeps: [TimeInterval] = []
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(for seconds: TimeInterval) async throws { lock.withLock { sleeps.append(seconds) } }
}

@Suite("Asset downloader: resume, checksum, backoff")
struct AssetDownloaderTests {
    private let body = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private var sha: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    private let noJitter = RetryBackoff(initialDelay: 2, multiplier: 2, maximumDelay: 60, maximumAttempts: 4, jitter: 0)

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-dl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(sha256: String? = nil) -> DownloadableAsset.File {
        DownloadableAsset.File(
            remoteURL: URL(string: "https://example.invalid/model.bin")!, relativePath: "weights/model.bin",
            bytes: Int64(body.count), sha256: sha256 ?? sha)
    }

    private func downloader(_ transport: FakeTransport, _ clock: FakeClock) -> AssetDownloader {
        AssetDownloader(transport: transport, clock: clock, backoff: noJitter, random: { 0.5 })
    }

    @Test("a dropped connection resumes from the bytes on disk with If-Range")
    func resumesAfterDrop() async throws {
        let directory = tempDirectory()
        let transport = FakeTransport(body: body, replies: [.serve(cut: 20_000), .serve()])
        let clock = FakeClock()
        let url = try await downloader(transport, clock).fetch(file(), into: directory)
        #expect(try Data(contentsOf: url) == body)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].offset == 0 && transport.requests[0].ifRange == nil)
        #expect(transport.requests[1].offset == 20_000 && transport.requests[1].ifRange == "\"etag-1\"")
        #expect(clock.sleeps == [2])
        #expect(!FileManager.default.fileExists(atPath: AssetDownloader.partialURL(for: url).path))
    }

    @Test("a partial left by an earlier launch is resumed, not restarted")
    func resumesAcrossLaunches() async throws {
        let directory = tempDirectory()
        let destination = directory.appendingPathComponent("weights/model.bin")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.prefix(30_000).write(to: AssetDownloader.partialURL(for: destination))
        try "\"etag-1\"".write(to: AssetDownloader.validatorURL(for: destination), atomically: true, encoding: .utf8)
        let transport = FakeTransport(body: body, replies: [.serve()])
        let url = try await downloader(transport, FakeClock()).fetch(file(), into: directory)
        #expect(try Data(contentsOf: url) == body)
        #expect(transport.requests.map(\.offset) == [30_000])
    }

    @Test("a server that ignores the range restarts the file instead of splicing")
    func rangeIgnored() async throws {
        let directory = tempDirectory()
        let transport = FakeTransport(body: body, replies: [.serve(cut: 10_000), .serve(honourRange: false)])
        let url = try await downloader(transport, FakeClock()).fetch(file(), into: directory)
        #expect(try Data(contentsOf: url) == body)
        #expect(transport.requests.map(\.offset) == [0, 10_000])
    }

    @Test("a partial without a validator can't be resumed safely and restarts")
    func noValidator() async throws {
        let directory = tempDirectory()
        let transport = FakeTransport(body: body, replies: [.serve(validator: nil, cut: 10_000), .serve()])
        _ = try await downloader(transport, FakeClock()).fetch(file(), into: directory)
        #expect(transport.requests.map(\.offset) == [0, 0])
    }

    @Test("416 discards the partial and starts over")
    func rangeNotSatisfiable() async throws {
        let directory = tempDirectory()
        let transport = FakeTransport(body: body, replies: [.serve(cut: 10_000), .status(416), .serve()])
        let url = try await downloader(transport, FakeClock()).fetch(file(), into: directory)
        #expect(try Data(contentsOf: url) == body)
        #expect(transport.requests.map(\.offset) == [0, 10_000, 0])
    }

    @Test("a checksum mismatch is never kept: one clean retry, then it fails")
    func checksumMismatch() async throws {
        let directory = tempDirectory()
        let transport = FakeTransport(body: body, replies: [.serve(), .serve()])
        let clock = FakeClock()
        await #expect(throws: AssetDownloadError.checksumMismatch(path: "weights/model.bin")) {
            try await downloader(transport, clock).fetch(file(sha256: String(repeating: "0", count: 64)), into: directory)
        }
        #expect(transport.requests.map(\.offset) == [0, 0])
        let destination = directory.appendingPathComponent("weights/model.bin")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: AssetDownloader.partialURL(for: destination).path))
    }

    @Test("transient failures back off exponentially and give up after the budget")
    func backoffExhausted() async throws {
        let transport = FakeTransport(body: body, replies: [.fail(.timedOut), .status(503), .fail(.networkConnectionLost), .status(500), .status(500)])
        let clock = FakeClock()
        await #expect(throws: AssetDownloadError.self) {
            try await downloader(transport, clock).fetch(file(), into: tempDirectory())
        }
        #expect(clock.sleeps == [2, 4, 8, 16])
        #expect(transport.requests.count == 5)
    }

    @Test("permanent HTTP errors fail fast without retrying")
    func permanent() async throws {
        let transport = FakeTransport(body: body, replies: [.status(404)])
        let clock = FakeClock()
        await #expect(throws: AssetDownloadError.http(404)) {
            try await downloader(transport, clock).fetch(file(), into: tempDirectory())
        }
        #expect(clock.sleeps.isEmpty)
    }

    @Test("an already-downloaded file with the right hash is not fetched again")
    func alreadyPresent() async throws {
        let directory = tempDirectory()
        let destination = directory.appendingPathComponent("weights/model.bin")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: destination)
        let transport = FakeTransport(body: body, replies: [])
        _ = try await downloader(transport, FakeClock()).fetch(file(), into: directory)
        #expect(transport.requests.isEmpty)
    }

    @Test("progress includes resumed bytes, so it never dips")
    func progressMonotonic() async throws {
        let directory = tempDirectory()
        let transport = FakeTransport(body: body, replies: [.serve(cut: 20_000), .serve()])
        let seen = LockedArray()
        _ = try await downloader(transport, FakeClock()).fetch(file(), into: directory) { seen.append($0) }
        let values = seen.values
        #expect(values.last == Int64(body.count))
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

private final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    func append(_ value: Int64) { lock.withLock { storage.append(value) } }
    var values: [Int64] { lock.withLock { storage } }
}

@Suite("Checksum manifest")
struct ChecksumManifestTests {
    private let listing = """
    [
      {"type": "directory", "oid": "abc", "size": 0, "path": "Decoder.mlmodelc"},
      {"type": "file", "oid": "ignored", "size": 11, "path": "Decoder.mlmodelc/weights/weight.bin",
       "lfs": {"oid": "B94D27B9934D3E08A52E52D7DA7DABFAC484EFE37A5380EE9088F7ACE2EFCDE9", "size": 11, "pointerSize": 132}},
      {"type": "file", "oid": "95d09f2b10159347eece71399a7e2e907ea3df4f", "size": 11, "path": "config.json"},
      {"type": "file", "size": 5, "path": "no-checksum.txt"}
    ]
    """

    @Test("parses LFS SHA-256 and git blob ids; skips directories and unusable rows")
    func parse() throws {
        let entries = try ChecksumManifest.parseHuggingFaceTree(Data(listing.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].digest == .sha256("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"))
        #expect(entries[1].digest == .gitBlobSHA1("95d09f2b10159347eece71399a7e2e907ea3df4f"))
        #expect(throws: ChecksumManifest.ParseError.notAListing) {
            try ChecksumManifest.parseHuggingFaceTree(Data("{\"error\":\"x\"}".utf8))
        }
    }

    @Test("verifies files on disk, flags a corrupted one, ignores ones not downloaded")
    func verify() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-sum-\(UUID().uuidString)")
        let weights = directory.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin")
        try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: weights)  // sha256 b94d27…
        try Data("hello world".utf8).write(to: directory.appendingPathComponent("config.json"))  // git blob 95d09f…
        let manifest = ChecksumManifest(entries: try ChecksumManifest.parseHuggingFaceTree(Data(listing.utf8)))
        let clean = try manifest.verify(directory: directory)
        #expect(clean.isClean)
        #expect(clean.verified == 2)

        try Data("hello world".utf8.reversed()).write(to: weights)
        let corrupted = try manifest.verify(directory: directory)
        #expect(corrupted.mismatches.map(\.path) == ["Decoder.mlmodelc/weights/weight.bin"])

        try FileManager.default.removeItem(at: weights)
        #expect(try manifest.verify(directory: directory).verified == 1)
    }

    @Test("digests match the reference tools (shasum, git hash-object)")
    func digests() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-digest-\(UUID().uuidString)")
        try Data("hello world".utf8).write(to: url)
        #expect(try FileDigest.sha256(of: url) == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        #expect(try FileDigest.gitBlobSHA1(of: url) == "95d09f2b10159347eece71399a7e2e907ea3df4f")
    }
}
