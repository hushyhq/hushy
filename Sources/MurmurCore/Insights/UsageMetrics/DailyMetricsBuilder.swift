import Foundation

/// Turns the day's event records into closed daily batches. Pure: the only inputs are the records,
/// the environment, the injected calendar/time and the injected batch-ID source.
///
/// - A day is closed only once it has fully elapsed in the calendar's time zone.
/// - One batch per (day, app build); a busier group is split every `maximumEventsPerBatch`
///   events, never truncated.
/// - The batch ID is drawn once per batch, at close, so a later retry reuses it (the queue stores
///   the batch, not the records).
public struct DailyMetricsBuilder: Sendable {
    public struct CloseResult: Sendable, Equatable {
        /// Ordered by day, then build.
        public let closedBatches: [DailyMetricsBatch]
        /// Records from today or later; keep them for the next close.
        public let openRecords: [MetricEventRecord]
        /// Records that could not be counted (invalid build number or an unrepresentable date).
        public let skippedRecordCount: Int
    }

    private struct GroupKey: Hashable, Comparable {
        let day: MetricsDay
        let build: Int
        static func < (lhs: GroupKey, rhs: GroupKey) -> Bool { (lhs.day, lhs.build) < (rhs.day, rhs.build) }
    }

    private struct Accumulator {
        var dictations: [DictationFeedback.CleanupModelProfile: DictationMetricTotals] = [:]
        var voiceActions = VoiceActionTotals()
        var meetings = MeetingTotals()
        var funnel = MetricsCountTable<FunnelStep>()
        var tones = MetricsCountTable<MetricsTone>()
        var editRate = MetricsEditRateTable()

        mutating func add(_ event: MetricEvent) {
            switch event {
            case .dictation(let value):
                dictations[value.feedback.cleanupModelProfile, default: DictationMetricTotals()].record(value)
                if let tone = value.tone { tones.increment(tone) }
                // Only a pasted dictation with a tone and a kind of app has an edit rate; one recorded by an
                // older build (no kind of app) is left out rather than put under a guess.
                if value.feedback.delivery == .succeeded, let tone = value.tone, let kind = value.appKind {
                    editRate.record(
                        tone: tone, appKind: kind, observation: value.feedback.editObservation,
                        coverage: value.feedback.editCoverage, size: value.editSize)
                }
            case .voiceAction(let value): voiceActions.record(value)
            case .meeting(let value): meetings.record(value)
            case .funnel(let step): funnel.increment(step)
            }
        }
    }

    /// Chooses the ID of the batch for (day, build, chunk index). The service passes a persisted,
    /// stable choice so closing the same day twice (after a crash) yields the same batches.
    public typealias BatchIdentifier = @Sendable (_ day: MetricsDay, _ build: Int, _ chunk: Int) -> UUID

    private let calendar: Calendar
    private let identify: BatchIdentifier

    /// `calendar` supplies the time zone only: days are always Gregorian, so an Islamic or Buddhist
    /// system calendar cannot produce a day the server would reject.
    public init(calendar: Calendar, makeBatchID: @escaping @Sendable () -> UUID = { UUID() }) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
        identify = { _, _, _ in makeBatchID() }
    }

    public init(calendar: Calendar, identify: @escaping BatchIdentifier) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
        self.identify = identify
    }

    public func close(
        records: [MetricEventRecord], environment: MetricsEnvironment, now: Date,
        retention: MetricsRetentionInput = MetricsRetentionInput()
    ) throws -> CloseResult {
        try close(records: records, environment: environment, today: day(of: now), retention: retention)
    }

    /// Closes every day before `today`. Records carry their own day (stamped when they happened),
    /// so a later time-zone change cannot move them.
    public func close(
        records: [MetricEventRecord], environment: MetricsEnvironment, today: MetricsDay,
        retention: MetricsRetentionInput = MetricsRetentionInput()
    ) throws -> CloseResult {
        var groups: [GroupKey: [MetricEventRecord]] = [:]
        var open: [MetricEventRecord] = []
        var skipped = 0
        for record in records {
            let recordDay = record.day
            guard (1...Int(Int32.max)).contains(record.appBuild) else {
                skipped += 1
                continue
            }
            if recordDay >= today {
                open.append(record)
            } else {
                groups[GroupKey(day: recordDay, build: record.appBuild), default: []].append(record)
            }
        }
        let activeDays = retention.activeDays.union(groups.keys.map(\.day))
        var batches: [DailyMetricsBatch] = []
        for key in groups.keys.sorted() {
            let events = (groups[key] ?? []).map(\.event)
            for (index, start) in stride(from: 0, to: events.count, by: MetricsLimits.maximumEventsPerBatch).enumerated() {
                let chunk = events[start..<min(start + MetricsLimits.maximumEventsPerBatch, events.count)]
                let numbers = MetricsRetention.compute(on: key.day, firstRunDay: retention.firstRunDay, activeDays: activeDays)
                batches.append(try batch(for: key, chunk: index, events: chunk, environment: environment, retention: numbers))
            }
        }
        return CloseResult(closedBatches: batches, openRecords: open, skippedRecordCount: skipped)
    }

    private func batch(
        for key: GroupKey, chunk: Int, events: ArraySlice<MetricEvent>, environment: MetricsEnvironment, retention: MetricsRetention
    ) throws -> DailyMetricsBatch {
        var accumulator = Accumulator()
        events.forEach { accumulator.add($0) }
        return try DailyMetricsBatch(
            batchID: identify(key.day, key.build, chunk), day: key.day, appBuild: key.build, environment: environment,
            dictationsByProfile: accumulator.dictations, voiceActions: accumulator.voiceActions,
            meetings: accumulator.meetings, funnel: accumulator.funnel, retention: retention, tones: accumulator.tones,
            editRate: accumulator.editRate)
    }

    /// The calendar day (in this builder's time zone) an event at `date` belongs to.
    public func day(of date: Date) throws -> MetricsDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return try MetricsDay(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }
}
