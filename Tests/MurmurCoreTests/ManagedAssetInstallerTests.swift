import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Serves in-memory files by URL; never touches the network.
final class InMemoryTransport: DownloadTransport, @unchecked Sendable {
    private let files: [URL: Data]
    private let lock = NSLock()
    private(set) var opened: [URL] = []

    init(files: [URL: Data]) {
        self.files = files
    }

    func open(_ url: URL, from offset: Int64, ifRange validator: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>) {
        lock.withLock { opened.append(url) }
        guard let body = files[url] else { return (TransportResponse(statusCode: 404), AsyncThrowingStream { $0.finish() }) }
        let slice = offset > 0 ? body.subdata(in: Int(offset)..<body.count) : body
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            stride(from: 0, to: slice.count, by: 1_024).forEach { continuation.yield(slice.subdata(in: $0..<min($0 + 1_024, slice.count))) }
            continuation.finish()
        }
        return (TransportResponse(statusCode: offset > 0 ? 206 : 200, validator: "\"v1\""), stream)
    }
}

struct NoWaitClock: DownloadClock {
    func now() -> Date { Date() }
    func sleep(for seconds: TimeInterval) async throws {}
}

/// A tiny fake "model": a few files with real SHA-256s, served by `InMemoryTransport`.
struct FakeModelFiles {
    let files: [DownloadableAsset.File]
    let bodies: [URL: Data]

    init(prefix: String = "fake", sizes: [Int] = [3_000, 40, 9_000]) {
        var files: [DownloadableAsset.File] = []
        var bodies: [URL: Data] = [:]
        for (index, size) in sizes.enumerated() {
            let data = Data((0..<size).map { UInt8(($0 * 31 + index) % 251) })
            let url = URL(string: "https://example.invalid/\(prefix)/file\(index).bin")!
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files.append(DownloadableAsset.File(remoteURL: url, relativePath: "file\(index).bin", bytes: Int64(size), sha256: sha))
            bodies[url] = data
        }
        self.files = files
        self.bodies = bodies
    }

    var transport: InMemoryTransport { InMemoryTransport(files: bodies) }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

@Suite("Managed asset installer")
struct ManagedAssetInstallerTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hushy-installer-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("installs every file, verified, with cumulative progress that never goes backwards")
    func install() async throws {
        let model = FakeModelFiles()
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = ManagedAssetInstaller(downloader: AssetDownloader(transport: model.transport, clock: NoWaitClock()))
        let progress = Mutex<[Int64]>([])
        #expect(!ManagedAssetInstaller.isInstalled(model.files, in: directory))
        try await installer.install(model.files, into: directory) { bytes in progress.withLock { $0.append(bytes) } }
        let seen = progress.withLock { $0 }
        #expect(seen.last == model.totalBytes)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(ManagedAssetInstaller.isInstalled(model.files, in: directory))
        #expect(ManagedAssetInstaller.bytesOnDisk(model.files, in: directory) == model.totalBytes)
        let report = try ManagedAssetInstaller.verify(model.files, in: directory)
        #expect(report.isClean)
        #expect(report.verified == model.files.count)
    }

    @Test("verify catches a same-size tampered file and a missing one; remove deletes everything")
    func verifyAndRemove() async throws {
        let model = FakeModelFiles()
        let directory = tempDirectory()
        let installer = ManagedAssetInstaller(downloader: AssetDownloader(transport: model.transport, clock: NoWaitClock()))
        try await installer.install(model.files, into: directory)

        let tampered = directory.appendingPathComponent("file0.bin")
        var bytes = try Data(contentsOf: tampered)
        bytes[10] ^= 0xFF
        try bytes.write(to: tampered)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("file1.bin"))

        let report = try ManagedAssetInstaller.verify(model.files, in: directory)
        #expect(!report.isClean)
        #expect(Set(report.mismatches.map(\.path)) == ["file0.bin", "file1.bin"])
        #expect(!ManagedAssetInstaller.isInstalled(model.files, in: directory))

        // Re-running the install repairs only what is wrong (the good file is kept).
        let transport = model.transport
        let repair = ManagedAssetInstaller(downloader: AssetDownloader(transport: transport, clock: NoWaitClock()))
        try await repair.install(model.files, into: directory)
        #expect(try ManagedAssetInstaller.verify(model.files, in: directory).isClean)
        #expect(Set(transport.opened.map(\.lastPathComponent)) == ["file0.bin", "file1.bin"])

        try ManagedAssetInstaller.remove(directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try ManagedAssetInstaller.remove(directory)  // idempotent
    }

    @Test("the URLSession transport resumes with Range and a strong validator only")
    func transportRequest() throws {
        let url = URL(string: "https://huggingface.co/a/resolve/abc/model.safetensors")!
        let fresh = URLSessionDownloadTransport.request(for: url, from: 0, ifRange: "\"x\"")
        #expect(fresh.value(forHTTPHeaderField: "Range") == nil)
        #expect(fresh.value(forHTTPHeaderField: "If-Range") == nil)
        let resume = URLSessionDownloadTransport.request(for: url, from: 1_234, ifRange: "\"etag\"")
        #expect(resume.value(forHTTPHeaderField: "Range") == "bytes=1234-")
        #expect(resume.value(forHTTPHeaderField: "If-Range") == "\"etag\"")

        let strong = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"abc\""]))
        #expect(URLSessionDownloadTransport.validator(from: strong) == "\"abc\"")
        let weak = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["ETag": "W/\"abc\"", "Last-Modified": "Sat, 27 Sep 2026 10:00:00 GMT"]))
        #expect(URLSessionDownloadTransport.validator(from: weak) == "Sat, 27 Sep 2026 10:00:00 GMT")
        let none = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        #expect(URLSessionDownloadTransport.validator(from: none) == nil)
    }
}
