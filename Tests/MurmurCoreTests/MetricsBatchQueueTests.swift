import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: local queue policy")
struct MetricsBatchQueueTests {
    typealias F = UsageMetricsFixtures
    let now = F.noonOct5

    private func queue(_ directory: URL, policy: MetricsQueuePolicy = .standard) -> MetricsBatchQueue {
        MetricsBatchQueue(directory: directory, policy: policy)
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test("enqueued batches come back oldest first and are removed only by acknowledge")
    func enqueueSendAcknowledge() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = try F.simpleBatch(dayOffset: 0)
        let newer = try F.simpleBatch(dayOffset: 1)
        let q = queue(dir)
        try await q.enqueue([newer], now: now.addingTimeInterval(-60))
        try await q.enqueue([older], now: now.addingTimeInterval(-3_600))

        let next = try await q.nextBatchesToSend(limit: 10, now: now)
        #expect(next == [older, newer])
        // Reading is not acknowledging.
        #expect(try await q.nextBatchesToSend(limit: 10, now: now).count == 2)
        #expect(try await q.nextBatchesToSend(limit: 1, now: now) == [older])

        #expect(try await q.acknowledge(batchID: older.batchID))
        #expect(try await q.nextBatchesToSend(limit: 10, now: now) == [newer])
        #expect(try await q.acknowledge(batchID: older.batchID) == false)
    }

    @Test("a retry sends the exact same bytes: enqueueing the same batch again changes nothing")
    func idempotentEnqueue() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let batch = try F.simpleBatch()
        let q = queue(dir)
        try await q.enqueue([batch], now: now)
        let before = try Data(contentsOf: dir.appendingPathComponent("\(batch.batchID.uuidString).batch.json"))
        try await q.enqueue([batch], now: now.addingTimeInterval(500))
        let after = try Data(contentsOf: dir.appendingPathComponent("\(batch.batchID.uuidString).batch.json"))
        #expect(before == after)
        #expect(try await q.pendingCount() == 1)
        let reloaded = try #require(try await q.nextBatchesToSend(limit: 1, now: now).first)
        #expect(try reloaded.encodedBody() == batch.encodedBody())
    }

    @Test("batches older than seven days are dropped and counted, never offered")
    func expiry() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = queue(dir)
        let old = try F.simpleBatch(dayOffset: 0)
        let fresh = try F.simpleBatch(dayOffset: 1)
        try await q.enqueue([old], now: now.addingTimeInterval(-8 * 86_400))
        try await q.enqueue([fresh], now: now.addingTimeInterval(-6 * 86_400))
        #expect(try await q.nextBatchesToSend(limit: 10, now: now) == [fresh])
        #expect(try await q.droppedBatchCount() == 1)
    }

    @Test("exactly seven days old is still kept; one second more is not")
    func expiryBoundary() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = queue(dir)
        let batch = try F.simpleBatch()
        try await q.enqueue([batch], now: now.addingTimeInterval(-7 * 86_400))
        #expect(try await q.nextBatchesToSend(limit: 1, now: now).count == 1)
        #expect(try await q.nextBatchesToSend(limit: 1, now: now.addingTimeInterval(1)).isEmpty)
    }

    @Test("overflow drops the oldest first and counts them")
    func overflow() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = try F.simpleBatch()
        let size = try sample.encodedBody().count
        // Room for two batches plus envelope overhead, not three.
        let policy = MetricsQueuePolicy(maximumBytes: (size + 80) * 2, maximumAge: 7 * 86_400)
        let q = queue(dir, policy: policy)
        let a = try F.simpleBatch(dayOffset: 0)
        let b = try F.simpleBatch(dayOffset: 1)
        let c = try F.simpleBatch(dayOffset: 2)
        try await q.enqueue([a], now: now.addingTimeInterval(-300))
        try await q.enqueue([b], now: now.addingTimeInterval(-200))
        let report = try await q.enqueue([c], now: now.addingTimeInterval(-100))
        #expect(report.overflow == 1)
        #expect(try await q.nextBatchesToSend(limit: 10, now: now) == [b, c])
        #expect(try await q.droppedBatchCount() == 1)
        #expect(try await q.totalBytes() <= policy.maximumBytes)
    }

    @Test("the standard policy is the planned one megabyte and seven days")
    func standardPolicy() {
        #expect(MetricsQueuePolicy.standard.maximumBytes == 1_000_000)
        #expect(MetricsQueuePolicy.standard.maximumAge == 7 * 86_400)
    }

    @Test("turning sharing off deletes every unsent batch and the drop counter, and nothing else")
    func discardAll() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unrelated = dir.appendingPathComponent("keep-me.txt")
        try Data("hello".utf8).write(to: unrelated)
        let q = queue(dir)
        try await q.enqueue([F.simpleBatch(dayOffset: 0), F.simpleBatch(dayOffset: 1)], now: now.addingTimeInterval(-9 * 86_400))
        _ = try await q.nextBatchesToSend(limit: 1, now: now)   // forces an expiry, so the counter is non-zero
        #expect(try await q.droppedBatchCount() > 0)

        try await q.discardAllUnsent()
        #expect(try files(in: dir) == ["keep-me.txt"])
        #expect(try await q.pendingCount() == 0)
        #expect(try await q.droppedBatchCount() == 0)
    }

    @Test("a corrupt file is removed and counted rather than blocking the queue")
    func corruptFile() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = queue(dir)
        let good = try F.simpleBatch()
        try await q.enqueue([good], now: now)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).batch.json"))
        #expect(try await q.nextBatchesToSend(limit: 10, now: now) == [good])
        #expect(try await q.droppedBatchCount() == 1)
        #expect(try await q.pendingCount() == 1)
    }

    @Test("a batch that is too large to ever be accepted is refused, not queued")
    func oversizeRefused() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiny = MetricsQueuePolicy(maximumBytes: 1_000_000, maximumAge: 86_400, maximumBatchBytes: 10)
        await #expect(throws: MetricsQueueError.batchTooLarge) {
            try await queue(dir, policy: tiny).enqueue([F.simpleBatch()], now: now)
        }
        #expect(try files(in: dir).isEmpty)
    }

    @Test("queue files are private to the owner")
    func permissions() async throws {
        let dir = try F.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("queue", isDirectory: true)
        let batch = try F.simpleBatch()
        try await queue(nested).enqueue([batch], now: now)
        let file = nested.appendingPathComponent("\(batch.batchID.uuidString).batch.json")
        let filePerms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let dirPerms = try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int
        #expect(filePerms == 0o600)
        #expect(dirPerms == 0o700)
    }
}
