import Foundation

/// The events of days that have not been closed yet, one JSON line each, in a file only this Mac
/// holds. Each line is an enum case and clamped numbers plus the calendar day it belongs to (no
/// time of day, no finer than the batch itself). No text of any kind is ever written here.
struct MetricsJournal {
    static let maximumRecords = 20_000
    static let maximumBytes = 16 * 1_024 * 1_024

    let url: URL
    private let files = FileManager.default

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Appends one record. Refuses (throws) once the file is at its size bound.
    func append(_ record: MetricEventRecord) throws {
        var line = try Self.encoder().encode(record)
        line.append(0x0A)
        try ensureDirectory()
        if !files.fileExists(atPath: url.path) {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard currentSize() + line.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Every readable record, oldest first, each passed back through its clamping initializers.
    /// Lines that cannot be read are skipped and counted.
    func load() -> (records: [MetricEventRecord], unreadable: Int) {
        guard let data = files.contents(atPath: url.path) else { return ([], 0) }
        var records: [MetricEventRecord] = []
        var unreadable = 0
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let record = try? decoder.decode(MetricEventRecord.self, from: Data(line)) {
                records.append(MetricEventRecord(day: record.day, appBuild: record.appBuild, event: record.event.normalized))
            } else {
                unreadable += 1
            }
        }
        return (records, unreadable)
    }

    /// Rewrites the file with exactly `records` (newest `maximumRecords` at most), atomically.
    func replace(with records: [MetricEventRecord]) throws {
        guard !records.isEmpty else { return try delete() }
        let encoder = Self.encoder()
        var data = Data()
        for record in records.suffix(Self.maximumRecords) {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try ensureDirectory()
        let temporary = url.appendingPathExtension("tmp")
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try files.replaceItemAt(url, withItemAt: temporary)
    }

    func delete() throws {
        guard files.fileExists(atPath: url.path) else { return }
        try files.removeItem(at: url)
    }

    private func currentSize() -> Int {
        ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func ensureDirectory() throws {
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// Local bookkeeping that outlives the journal: the calendar days this Mac used Hushy (so "days
/// active in the last 7" survives the journal being emptied each day), and the latest day already
/// closed (so a clock set back can never put an event on a day that was already closed). Days only.
struct MetricsActivityLedger {
    /// Longer than the retention window needs, so a late close still sees the whole week.
    static let keptDays = 14

    struct State: Codable, Equatable {
        var days: Set<MetricsDay> = []
        var closedThrough: MetricsDay?
    }

    let url: URL
    private let files = FileManager.default

    func load() -> State {
        guard let data = files.contents(atPath: url.path),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    func save(_ state: State) throws {
        guard let newest = state.days.max() ?? state.closedThrough else { return try delete() }
        var kept = state
        kept.days = state.days.filter { (0..<Self.keptDays).contains(newest.days(since: $0)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try MetricsAtomicFile.write(try encoder.encode(kept), to: url)
    }

    func delete() throws { try MetricsAtomicFile.remove(url) }
}

/// The IDs of batches whose day has been closed but whose events have not yet left the journal.
/// An ID is chosen once per (day, build, chunk) and saved before the batch is queued, so closing the
/// same day again after a crash rebuilds the same batch with the same ID and the queue (which
/// ignores an ID it already holds) cannot count it twice. Entries are dropped once the journal no
/// longer holds the day. Random UUIDs, not derived from anything about the Mac.
final class StableBatchIDs: @unchecked Sendable {
    private let url: URL
    private let make: @Sendable () -> UUID
    private let lock = NSLock()
    private var ids: [String: UUID]

    init(url: URL, make: @escaping @Sendable () -> UUID) {
        self.url = url
        self.make = make
        let stored = FileManager.default.contents(atPath: url.path).flatMap { try? JSONDecoder().decode([String: UUID].self, from: $0) }
        ids = stored ?? [:]
    }

    static func key(_ day: MetricsDay, _ build: Int, _ chunk: Int) -> String { "\(day.isoString)#\(build)#\(chunk)" }

    func id(day: MetricsDay, build: Int, chunk: Int) -> UUID {
        lock.withLock {
            let key = Self.key(day, build, chunk)
            if let existing = ids[key] { return existing }
            let created = make()
            ids[key] = created
            return created
        }
    }

    /// Saves every ID handed out so far. Throws if it cannot, so the caller does not queue.
    func persist() throws {
        let snapshot = lock.withLock { ids }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try MetricsAtomicFile.write(try encoder.encode(snapshot), to: url)
    }

    /// Forgets the IDs of days before `today` (their events have left the journal) and saves.
    func clearClosed(before today: MetricsDay) throws {
        lock.withLock { ids = ids.filter { (MetricsDay(isoString: String($0.key.prefix(10))) ?? today) >= today } }
        let remaining = lock.withLock { ids }
        if remaining.isEmpty { try MetricsAtomicFile.remove(url) } else { try persist() }
    }

    func delete() throws {
        lock.withLock { ids = [:] }
        try MetricsAtomicFile.remove(url)
    }
}

/// Whole-file writes that are atomic (a crash leaves the old file or the new one, never half),
/// owner-only, in an owner-only folder.
enum MetricsAtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
