import Foundation

/// Limits for the local queue of closed batches that have not been acknowledged yet.
public struct MetricsQueuePolicy: Sendable, Equatable {
    /// Total size of all queued batch files.
    public let maximumBytes: Int
    /// A batch older than this (measured from when it was enqueued) is dropped, never offered.
    public let maximumAge: TimeInterval
    /// A single batch larger than this is refused at enqueue time.
    public let maximumBatchBytes: Int

    public init(maximumBytes: Int, maximumAge: TimeInterval, maximumBatchBytes: Int = MetricsLimits.maximumEncodedBatchBytes) {
        self.maximumBytes = maximumBytes
        self.maximumAge = maximumAge
        self.maximumBatchBytes = maximumBatchBytes
    }

    /// One megabyte, seven days.
    public static let standard = MetricsQueuePolicy(maximumBytes: 1_000_000, maximumAge: 7 * 86_400)
}

/// What a queue operation threw away.
public struct MetricsQueueDropReport: Sendable, Equatable {
    public let expired: Int
    public let overflow: Int
    public let corrupt: Int
    public var total: Int { expired + overflow + corrupt }
}

public enum MetricsQueueError: Error, Sendable, Equatable {
    case batchTooLarge
}

/// A directory of closed batches awaiting upload. There is no uploader here: the caller reads
/// `nextBatchesToSend`, sends them, and calls `acknowledge` for each one the server accepted.
/// A batch leaves the queue only through `acknowledge`, expiry, overflow, corruption, or
/// `discardAllUnsent` (sharing switched off).
///
/// Each batch is one file `<batchID>.batch.json` holding exactly `encodedBody()`. The time it was
/// enqueued is the file's modification date, set from the injected clock. The count of dropped
/// batches is a small local file, never uploaded by this type. Only these two kinds of file are
/// ever touched, so pointing the queue at a shared directory cannot delete anything else.
public actor MetricsBatchQueue {
    private static let batchSuffix = ".batch.json"
    private static let droppedCounterName = "dropped-batches.count"

    private struct Entry {
        let url: URL
        let batchID: UUID?
        let size: Int
        let enqueuedAt: Date
    }

    private let directory: URL
    private let policy: MetricsQueuePolicy
    private let files = FileManager.default

    public init(directory: URL, policy: MetricsQueuePolicy = .standard) {
        self.directory = directory
        self.policy = policy
    }

    /// Stores closed batches (idempotent per batch ID: an existing file is left byte-for-byte as is),
    /// then enforces age and size limits, dropping the oldest first.
    @discardableResult
    public func enqueue(_ batches: [DailyMetricsBatch], now: Date) throws -> MetricsQueueDropReport {
        let bodies = try batches.map { ($0, try $0.encodedBody()) }
        guard bodies.allSatisfy({ $0.1.count <= policy.maximumBatchBytes }) else { throw MetricsQueueError.batchTooLarge }
        try ensureDirectory()
        for (batch, body) in bodies {
            let url = fileURL(for: batch.batchID)
            guard !files.fileExists(atPath: url.path) else { continue }
            try write(body, to: url, modifiedAt: now)
        }
        return try prune(now: now)
    }

    /// Oldest first, after dropping what has expired, overflowed or cannot be read. Does not remove
    /// anything that is returned.
    public func nextBatchesToSend(limit: Int, now: Date) throws -> [DailyMetricsBatch] {
        try prune(now: now)
        var loaded: [DailyMetricsBatch] = []
        var corrupt = 0
        for entry in try entries().sorted(by: Self.isOlder) {
            if let batch = decode(entry) { loaded.append(batch) } else {
                try remove(entry.url)
                corrupt += 1
            }
        }
        try recordDrops(corrupt)
        return Array(loaded.prefix(max(0, limit)))
    }

    /// Deletes the batch the server accepted. Returns whether it was queued.
    @discardableResult
    public func acknowledge(batchID: UUID) throws -> Bool {
        let url = fileURL(for: batchID)
        guard files.fileExists(atPath: url.path) else { return false }
        try remove(url)
        return true
    }

    /// Sharing switched off: delete every unsent batch and the drop counter, and nothing else.
    /// Every file is attempted even if an earlier one fails; the first error is thrown at the end.
    public func discardAllUnsent() throws {
        var firstError: Error?
        do {
            for entry in try entries() {
                do { try remove(entry.url) } catch { firstError = firstError ?? error }
            }
        } catch { firstError = firstError ?? error }
        do { try remove(directory.appendingPathComponent(Self.droppedCounterName)) } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }

    public func droppedBatchCount() throws -> Int {
        let url = directory.appendingPathComponent(Self.droppedCounterName)
        guard let data = files.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else { return 0 }
        return max(0, Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    public func pendingCount() throws -> Int { try entries().count }

    public func totalBytes() throws -> Int { try entries().map(\.size).reduce(0, MetricsMath.add) }

    // MARK: - Pruning

    @discardableResult
    private func prune(now: Date) throws -> MetricsQueueDropReport {
        var kept: [Entry] = []
        var expired = 0
        var corrupt = 0
        for entry in try entries().sorted(by: Self.isOlder) {
            if entry.batchID == nil {
                try remove(entry.url); corrupt += 1
            } else if now.timeIntervalSince(entry.enqueuedAt) > policy.maximumAge {
                try remove(entry.url); expired += 1
            } else {
                kept.append(entry)
            }
        }
        var size = kept.map(\.size).reduce(0, MetricsMath.add)
        var overflow = 0
        for entry in kept where size > policy.maximumBytes {
            try remove(entry.url)
            size -= entry.size
            overflow += 1
        }
        try recordDrops(expired + overflow + corrupt)
        return MetricsQueueDropReport(expired: expired, overflow: overflow, corrupt: corrupt)
    }

    private static func isOlder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        (lhs.enqueuedAt, lhs.url.lastPathComponent) < (rhs.enqueuedAt, rhs.url.lastPathComponent)
    }

    // MARK: - Files

    private func fileURL(for batchID: UUID) -> URL {
        directory.appendingPathComponent(batchID.uuidString + Self.batchSuffix)
    }

    private func entries() throws -> [Entry] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        return urls.filter { $0.lastPathComponent.hasSuffix(Self.batchSuffix) }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let stem = String(url.lastPathComponent.dropLast(Self.batchSuffix.count))
            return Entry(
                url: url, batchID: UUID(uuidString: stem), size: values?.fileSize ?? 0,
                enqueuedAt: values?.contentModificationDate ?? .distantPast)
        }
    }

    private func decode(_ entry: Entry) -> DailyMetricsBatch? {
        guard let data = files.contents(atPath: entry.url.path),
              let batch = try? JSONDecoder().decode(DailyMetricsBatch.self, from: data),
              batch.batchID == entry.batchID else { return nil }
        return batch
    }

    private func ensureDirectory() throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func write(_ data: Data, to url: URL, modifiedAt date: Date) throws {
        guard files.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try files.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func remove(_ url: URL) throws {
        guard files.fileExists(atPath: url.path) else { return }
        try files.removeItem(at: url)
    }

    private func recordDrops(_ count: Int) throws {
        guard count > 0 else { return }
        let total = MetricsMath.add(try droppedBatchCount(), count)
        try ensureDirectory()
        let url = directory.appendingPathComponent(Self.droppedCounterName)
        guard files.createFile(atPath: url.path, contents: Data(String(total).utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
