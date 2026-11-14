import Foundation
import os

/// Collects usage events into the daily batch, off the hot path and never in the user's way.
///
/// - `record` writes one line to the local journal, only while the switch is on. It never throws
///   and never touches the caller's work: a failure is logged without any content and dropped.
/// - `closeDays` turns every fully elapsed day in the journal into a batch (through
///   `DailyMetricsBuilder`) and puts it in the bounded local queue.
///
/// **Switching off is made safe by construction, not by deleting.** Everything this service keeps
/// lives in a folder named for the data epoch (`MetricsDataStore`), and the epoch goes up whenever
/// the switch goes off. Each operation reads the epoch once, at its start, uses that epoch's folder
/// for every read and write, and asks `MetricsSwitch.allows(epoch:)` before writing and after every
/// `await`. A step that straddles an off-and-on therefore either stops or only touches a folder
/// nothing will ever read again. Deleting old folders (`collectGarbage`) is tidying.
///
/// **Which day an event belongs to.** The calendar day in the Mac's time zone at the moment of the
/// event, stamped when it is recorded and stored as that day, so a later time-zone change or a
/// restart never moves it. A clock set back never reopens a closed day: the latest closed day is
/// kept, and an event that would land on or before it is stamped on the day after it instead.
public actor UsageMetricsService {
    static let journalName = "journal.jsonl"
    static let ledgerName = "active-days.json"
    static let batchIDsName = "batch-ids.json"
    public static let uploadStateName = "upload-state.json"

    private static let log = Logger(subsystem: "app.hushy", category: "usage-metrics")

    public nonisolated let store: MetricsDataStore

    private let appBuild: Int
    private let firstRunDay: MetricsDay?
    private let environment: MetricsEnvironment?
    private let timeZone: @Sendable () -> TimeZone
    private let gate: MetricsSwitch
    private let makeBatchID: @Sendable () -> UUID
    private var loadedEpoch: Int?
    private var state = MetricsActivityLedger.State()
    private var batchIDs: StableBatchIDs?

    /// - Parameters:
    ///   - store: the folder tree this service owns; it only ever touches the current epoch's folder.
    ///   - firstRunDay: the calendar day of this Mac's first run, kept locally; nil is read as "today".
    ///   - environment: coarse chip, memory and macOS bands; nil means batches cannot be built (and none are).
    ///   - timeZone: read at every event and close, so the day follows the Mac's current time zone.
    public init(
        store: MetricsDataStore, appBuild: Int, firstRunDay: MetricsDay?, environment: MetricsEnvironment?,
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent }, gate: MetricsSwitch,
        makeBatchID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.appBuild = appBuild
        self.firstRunDay = firstRunDay
        self.environment = environment
        self.timeZone = timeZone
        self.gate = gate
        self.makeBatchID = makeBatchID
    }

    /// The same, for a folder that holds a single service (tests and tools).
    public init(
        directory: URL, appBuild: Int, firstRunDay: MetricsDay?, environment: MetricsEnvironment?,
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent }, gate: MetricsSwitch,
        policy: MetricsQueuePolicy = .standard, makeBatchID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.init(
            store: MetricsDataStore(root: directory, policy: policy), appBuild: appBuild, firstRunDay: firstRunDay,
            environment: environment, timeZone: timeZone, gate: gate, makeBatchID: makeBatchID)
    }

    /// The current epoch's queue and folder, resolved at the moment of use.
    public nonisolated var queue: MetricsBatchQueue { store.queue(for: gate.epoch) }
    public nonisolated var directory: URL { store.directory(for: gate.epoch) }

    /// Removes the folders of earlier epochs. Safe at any time; failure only wastes disk.
    @discardableResult
    public nonisolated func collectGarbage() -> Int { store.collectGarbage(keeping: gate.epoch) }

    // MARK: - Recording

    /// Records one event on the calendar day of `date` in the Mac's current time zone. Does nothing
    /// while the switch is off, or if it has been off since `epoch` was read.
    public func record(_ event: MetricEvent, at date: Date, epoch: Int? = nil) async {
        let epoch = epoch ?? gate.epoch
        guard gate.allows(epoch: epoch) else { return }
        do { write(event, on: try currentDay(date), epoch: epoch) } catch { Self.logFailure("journal write", error) }
    }

    /// Records one event on a day chosen when it happened (a dictation held for its edit verdict
    /// keeps the day it was held on, whatever the time zone or clock becomes meanwhile).
    public func record(_ event: MetricEvent, onDay day: MetricsDay, epoch: Int? = nil) async {
        let epoch = epoch ?? gate.epoch
        guard gate.allows(epoch: epoch) else { return }
        write(event, on: day, epoch: epoch)
    }

    private func write(_ event: MetricEvent, on day: MetricsDay, epoch: Int) {
        do {
            load(epoch)
            let stamped = try stampedDay(day)
            try journal(epoch).append(MetricEventRecord(day: stamped, appBuild: appBuild, event: event))
            noteActive(stamped, epoch: epoch)
        } catch {
            Self.logFailure("journal write", error)
        }
    }

    // MARK: - Closing days

    /// Closes every fully elapsed day into the queue. Returns how many batches were queued.
    @discardableResult
    public func closeDays(now: Date) async -> Int {
        let epoch = gate.epoch
        guard gate.allows(epoch: epoch), let environment else { return 0 }
        if store.hasGarbage(keeping: epoch) { store.collectGarbage(keeping: epoch) }
        load(epoch)
        let loaded = journal(epoch).load()
        guard !loaded.records.isEmpty else { return 0 }
        do {
            let today = try currentDay(now)
            let ids = idStore(epoch)
            let builder = DailyMetricsBuilder(calendar: calendar()) { day, build, chunk in
                ids.id(day: day, build: build, chunk: chunk)
            }
            let result = try builder.close(records: loaded.records, environment: environment, today: today, retention: retentionInput())
            if let newest = result.closedBatches.map(\.day).max() { try markClosed(through: newest, epoch: epoch) }
            if !result.closedBatches.isEmpty {
                try ids.persist()   // before queueing: a crash from here on rebuilds the same batches
                try await store.queue(for: epoch).enqueue(result.closedBatches, now: now)
            }
            // After the await the switch may have been cycled; this epoch's folder is then unreachable, so stop.
            guard gate.allows(epoch: epoch) else { return 0 }
            // Re-read: an event recorded meanwhile must survive the rewrite.
            let journal = journal(epoch)
            try journal.replace(with: journal.load().records.filter { $0.day >= today })
            try ids.clearClosed(before: today)
            return result.closedBatches.count
        } catch {
            Self.logFailure("close day", error)
            return 0
        }
    }

    /// Today's numbers as they would be sent, for the "See what's sent" sheet. Nil when nothing
    /// has been recorded today. Never queued and never uploaded. Its batch ID is a throwaway:
    /// the sheet does not show it, because the stored batch gets its own ID when it is saved.
    public func previewToday(now: Date) -> DailyMetricsBatch? {
        let epoch = gate.epoch
        guard gate.allows(epoch: epoch), let environment, let today = try? currentDay(now),
              let tomorrow = try? today.adding(days: 1) else { return nil }
        load(epoch)
        let todays = journal(epoch).load().records.filter { $0.day == today }
            .map { MetricEventRecord(day: $0.day, appBuild: appBuild, event: $0.event) }
        guard !todays.isEmpty else { return nil }
        let builder = DailyMetricsBuilder(calendar: calendar())
        return try? builder.close(records: todays, environment: environment, today: tomorrow, retention: retentionInput()).closedBatches.first
    }

    // MARK: - Per-epoch files

    private func journal(_ epoch: Int) -> MetricsJournal {
        MetricsJournal(url: store.directory(for: epoch).appendingPathComponent(Self.journalName))
    }

    private func ledger(_ epoch: Int) -> MetricsActivityLedger {
        MetricsActivityLedger(url: store.directory(for: epoch).appendingPathComponent(Self.ledgerName))
    }

    private func idStore(_ epoch: Int) -> StableBatchIDs {
        load(epoch)
        if let batchIDs { return batchIDs }
        let created = StableBatchIDs(url: store.directory(for: epoch).appendingPathComponent(Self.batchIDsName), make: makeBatchID)
        batchIDs = created
        return created
    }

    /// Makes the in-memory copies belong to `epoch` (a different epoch starts from its own, empty, files).
    private func load(_ epoch: Int) {
        guard loadedEpoch != epoch else { return }
        loadedEpoch = epoch
        state = ledger(epoch).load()
        batchIDs = nil
    }

    // MARK: - Days

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone()
        return calendar
    }

    private func currentDay(_ date: Date) throws -> MetricsDay { try MetricsDay(date: date, calendar: calendar()) }

    /// `day`, but never on or before a day already closed.
    private func stampedDay(_ day: MetricsDay) throws -> MetricsDay {
        guard let closed = state.closedThrough, day <= closed else { return day }
        return try closed.adding(days: 1)
    }

    private func markClosed(through day: MetricsDay, epoch: Int) throws {
        guard state.closedThrough.map({ $0 < day }) ?? true else { return }
        state.closedThrough = day
        try ledger(epoch).save(state)
    }

    private func retentionInput() -> MetricsRetentionInput {
        MetricsRetentionInput(firstRunDay: firstRunDay, activeDays: state.days)
    }

    private func noteActive(_ day: MetricsDay, epoch: Int) {
        guard !state.days.contains(day) else { return }
        state.days.insert(day)
        do { try ledger(epoch).save(state) } catch { Self.logFailure("active day", error) }
    }

    /// Logs the stage and the error's type only. An error's own text can hold a path or a name.
    private static func logFailure(_ stage: StaticString, _ error: Error) {
        log.error("usage metrics: \(stage, privacy: .public) failed (\(String(describing: type(of: error)), privacy: .public))")
    }
}
