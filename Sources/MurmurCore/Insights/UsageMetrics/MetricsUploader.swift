import Foundation
import os

/// Sends closed-day batches from the local queue, and nothing else.
///
/// - Inert unless the switch is on **and** an endpoint is configured; with no endpoint it makes no
///   network call at all and the batches wait in the bounded queue under its own age and size limits.
/// - One upload run per calendar day; each batch gets at most one attempt per day. The attempt is
///   recorded before the request is made, so a crash mid-send cannot cause a second attempt.
/// - A batch that could not be delivered is retried on a later day with backoff (1, 2, then 4 days),
///   at most `maximumAttempts` times in all, then dropped. The queue's own seven-day age limit also applies.
/// - The body is always `batch.encodedBody()`: the same batch gives the same bytes on every retry.
/// - Requests are owned here: turning the switch off cancels every one in flight at once, and a
///   response that arrives after switch-off changes nothing.
/// - It works inside one data epoch (`MetricsSwitch`): the epoch is read at the start of a run, the
///   queue and bookkeeping are that epoch's, and `allows(epoch:)` is asked before every send and
///   after every `await`. A batch read before an off-and-on is therefore never sent afterwards.
/// - Bookkeeping is replaced atomically. A damaged state file is read as "already ran today", so
///   damage can only delay a send, never cause an extra one.
public actor MetricsUploader {
    public struct Limits: Sendable, Equatable {
        public let maximumAttempts: Int
        public let maximumBatchesPerRun: Int
        public static let standard = Limits(maximumAttempts: 4, maximumBatchesPerRun: 7)
        public init(maximumAttempts: Int, maximumBatchesPerRun: Int) {
            self.maximumAttempts = maximumAttempts
            self.maximumBatchesPerRun = maximumBatchesPerRun
        }
    }

    public enum Skipped: Sendable, Equatable { case switchedOff, noEndpoint, alreadyRanToday, nothingDue }

    public struct Report: Sendable, Equatable {
        public let skipped: Skipped?
        public let attempted: Int
        public let accepted: Int
        public let dropped: Int
    }

    private struct Entry: Codable, Equatable {
        var attempts: Int
        var nextEligibleDay: MetricsDay
    }

    private struct State: Codable, Equatable {
        var lastRunDay: MetricsDay?
        var batches: [String: Entry] = [:]
    }

    private static let log = Logger(subsystem: "app.hushy", category: "usage-metrics")

    /// The queue and bookkeeping file that belong to one data epoch.
    typealias Locate = @Sendable (Int) -> (queue: MetricsBatchQueue, stateURL: URL)

    private let locate: Locate
    private let transport: MetricsTransport
    private let endpoint: URL?
    private let gate: MetricsSwitch
    private let limits: Limits
    private let timeZone: @Sendable () -> TimeZone
    private let inFlight = InFlightRequest()

    public init(
        store: MetricsDataStore, transport: MetricsTransport, endpoint: URL?, gate: MetricsSwitch,
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent }, limits: Limits = .standard
    ) {
        self.init(
            locate: { (store.queue(for: $0), store.uploadStateURL(for: $0)) }, transport: transport, endpoint: endpoint,
            gate: gate, timeZone: timeZone, limits: limits)
    }

    /// One fixed queue and bookkeeping file whatever the epoch (tests of the sending rules alone).
    public init(
        queue: MetricsBatchQueue, stateURL: URL, transport: MetricsTransport, endpoint: URL?, gate: MetricsSwitch,
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent }, limits: Limits = .standard
    ) {
        self.init(
            locate: { _ in (queue, stateURL) }, transport: transport, endpoint: endpoint, gate: gate,
            timeZone: timeZone, limits: limits)
    }

    /// Where each epoch's queue and bookkeeping are found; a closure so a test can act at the moment
    /// a run resolves its epoch.
    init(
        locate: @escaping Locate, transport: MetricsTransport, endpoint: URL?, gate: MetricsSwitch,
        timeZone: @escaping @Sendable () -> TimeZone, limits: Limits
    ) {
        self.locate = locate
        self.transport = transport
        self.endpoint = endpoint
        self.gate = gate
        self.limits = limits
        self.timeZone = timeZone
        let box = inFlight
        gate.whenTurnedOff { box.cancel() }
    }

    /// Cancels every request in flight. Safe to call from any thread.
    public nonisolated func cancelInFlight() { inFlight.cancel() }

    @discardableResult
    public func uploadIfDue(now: Date) async -> Report {
        let epoch = gate.epoch
        guard gate.allows(epoch: epoch) else { return Self.skip(.switchedOff) }
        guard let endpoint else { return Self.skip(.noEndpoint) }
        let (queue, stateURL) = locate(epoch)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone()
        guard let today = try? MetricsDay(date: now, calendar: calendar) else { return Self.skip(.nothingDue) }
        var (state, damaged) = loadState(today: today, at: stateURL)
        if damaged { save(state, to: stateURL) }   // remember "ran today" so the damage cannot recur tomorrow as another skip
        // A clock set back never allows a second run: only a later day than the last run counts.
        guard state.lastRunDay.map({ today > $0 }) ?? true else { return Self.skip(.alreadyRanToday) }
        guard let queued = try? await queue.nextBatchesToSend(limit: limits.maximumBatchesPerRun, now: now) else {
            return Self.skip(.nothingDue)
        }
        guard gate.allows(epoch: epoch) else { return Self.skip(.switchedOff) }   // off (and maybe on again) during the read
        let due = queued.filter { (state.batches[$0.batchID.uuidString]?.nextEligibleDay ?? today) <= today }
        guard !due.isEmpty else {
            save(Self.pruned(state, keeping: queued), to: stateURL)
            return Self.skip(.nothingDue)
        }
        var report = (attempted: 0, accepted: 0, dropped: 0)
        for batch in due {
            guard gate.allows(epoch: epoch), let body = try? batch.encodedBody() else { break }
            let attempts = (state.batches[batch.batchID.uuidString]?.attempts ?? 0) + 1
            state.batches[batch.batchID.uuidString] = Entry(attempts: attempts, nextEligibleDay: Self.next(after: today, attempts: attempts))
            state.lastRunDay = today
            guard save(state, to: stateURL) else { break }   // cannot record the attempt, so do not make it
            report.attempted += 1
            guard let outcome = await send(body, to: endpoint, epoch: epoch), gate.allows(epoch: epoch) else { break }
            switch outcome {
            case .accepted:
                report.accepted += 1
                await remove(batch, from: &state, queue: queue)
            case .rejected:
                report.dropped += 1
                await remove(batch, from: &state, queue: queue)
            case .retryLater:
                if attempts >= limits.maximumAttempts {
                    report.dropped += 1
                    await remove(batch, from: &state, queue: queue)
                }
            }
            if outcome == .retryLater { break }   // the server is struggling: leave the rest for tomorrow
        }
        if gate.allows(epoch: epoch) {
            let remaining = (try? await queue.nextBatchesToSend(limit: Int.max, now: now)) ?? []
            if gate.allows(epoch: epoch) { save(Self.pruned(state, keeping: remaining), to: stateURL) }   // after the await
        }
        return Report(skipped: nil, attempted: report.attempted, accepted: report.accepted, dropped: report.dropped)
    }

    // MARK: - Helpers

    /// Sends one batch in a task this uploader owns, so switching off can cancel it. The task is
    /// created and registered in one step under the lock the off handler also takes
    /// (`InFlightRequest.start`), after the epoch check: either the switch went off first and no task
    /// is made, or the task is registered before off can run and off cancels it. Nil when the request
    /// was cancelled or never started.
    private func send(_ body: Data, to endpoint: URL, epoch: Int) async -> MetricsTransportOutcome? {
        let gate = gate
        let transport = transport
        guard let task = inFlight.start(gate: gate, epoch: epoch, {
            Task<MetricsTransportOutcome?, Never> {
                guard gate.allows(epoch: epoch), !Task.isCancelled else { return nil }
                let outcome = await transport.post(body, to: endpoint)
                return Task.isCancelled ? nil : outcome
            }
        }) else { return nil }
        defer { inFlight.finish(task) }
        return await task.value
    }

    private static func skip(_ reason: Skipped) -> Report { Report(skipped: reason, attempted: 0, accepted: 0, dropped: 0) }

    /// Days to wait after the nth failed attempt: 1, 2, 4, ...
    static func next(after today: MetricsDay, attempts: Int) -> MetricsDay {
        let wait = 1 << min(max(attempts - 1, 0), 6)
        return (try? today.adding(days: wait)) ?? today
    }

    private func remove(_ batch: DailyMetricsBatch, from state: inout State, queue: MetricsBatchQueue) async {
        _ = try? await queue.acknowledge(batchID: batch.batchID)
        state.batches[batch.batchID.uuidString] = nil
    }

    private static func pruned(_ state: State, keeping queued: [DailyMetricsBatch]) -> State {
        let ids = Set(queued.map(\.batchID.uuidString))
        var copy = state
        copy.batches = state.batches.filter { ids.contains($0.key) }
        return copy
    }

    /// No file means a fresh start. A file that cannot be read means the bookkeeping was damaged
    /// (a crash mid-write on an old build, a disk fault): it is read as "already ran today" with no
    /// per-batch history, so the damage can delay a send by a day but never cause an extra one.
    private func loadState(today: MetricsDay, at stateURL: URL) -> (state: State, damaged: Bool) {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return (State(), false) }
        guard let data = FileManager.default.contents(atPath: stateURL.path),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return (State(lastRunDay: today), true)
        }
        return (state, false)
    }

    @discardableResult
    private func save(_ state: State, to stateURL: URL) -> Bool {
        do {
            try MetricsAtomicFile.write(try JSONEncoder().encode(state), to: stateURL)
            return true
        } catch {
            Self.log.error("usage metrics: upload state write failed (\(String(describing: type(of: error)), privacy: .public))")
            return false
        }
    }
}

/// The requests in flight, cancellable from any thread. `start` checks the gate and creates the
/// task while holding the lock that `cancel` takes, so a switch-off cannot slip between "allowed"
/// and "registered": it is either seen by the check or cancels the registered task. Runs of one
/// uploader can overlap (the actor lets a second call in while the first awaits its request), so
/// every request stays registered until it finishes and an off cancels all of them.
final class InFlightRequest: @unchecked Sendable {
    typealias Request = Task<MetricsTransportOutcome?, Never>
    private let lock = NSLock()
    private var tasks: Set<Request> = []

    func start(gate: MetricsSwitch, epoch: Int, _ make: () -> Request) -> Request? {
        lock.withLock {
            guard gate.allows(epoch: epoch) else { return nil }
            let created = make()
            tasks.insert(created)
            return created
        }
    }

    func finish(_ task: Request) { lock.withLock { _ = tasks.remove(task) } }
    func cancel() { lock.withLock { tasks }.forEach { $0.cancel() } }
}
