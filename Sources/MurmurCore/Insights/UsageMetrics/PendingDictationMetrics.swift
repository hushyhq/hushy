import Foundation

/// Holds each pasted dictation's metric until the edit watcher has reported (kept or edited) or its
/// window has closed, then releases it exactly once. Pure and clock-injected.
///
/// What is held is the finished `DictationMetricEvent` (closed-vocabulary enums and clamped
/// numbers), never the `DictationMetricInput`: its mode can carry a custom name, a prompt and app
/// bundle IDs, and none of that may sit in memory for the window, so it is reduced to a
/// `MetricsModeKind` before holding.
///
/// - `resolve` with a verdict (and, for an edited dictation, how many words changed) releases the
///   dictation with that verdict, unless the calendar day has
///   rolled over since it was held, in which case it is released as not checked.
/// - `expire` releases anything held longer than `window` as not checked (the watcher never reported).
/// - `drain` releases everything as not checked (the app is quitting).
/// - `drainBefore` releases, as not checked, everything held from an earlier calendar day. The
///   daily close calls it first, so a dictation that straddles midnight is written to the day it
///   happened on before that day is closed.
/// - A dictation already released is gone: a late or repeated report returns nil, so nothing is
///   ever recorded twice.
public struct PendingDictationMetrics: Sendable {
    /// The edit verdict is read 8 seconds after the paste; this leaves time for slow apps.
    public static let window: TimeInterval = LearningReadSchedule.verdictOffset + 12

    public struct Released: Sendable, Equatable {
        public let event: DictationMetricEvent
        /// When the dictation happened (kept for the window only).
        public let heldAt: Date
        /// The calendar day it happened on, fixed when it was held in the time zone then current.
        public let day: MetricsDay
        /// The data epoch it was held in: a release into a later epoch is dropped by the service.
        public let epoch: Int
    }

    private struct Entry: Sendable {
        /// Nil only if the facts contradicted each other; such an entry releases nothing.
        let event: DictationMetricEvent?
        let heldAt: Date
        let day: MetricsDay?
        let epoch: Int
    }

    private let calendar: Calendar
    private var entries: [UUID: Entry] = [:]

    public init(calendar: Calendar) { self.calendar = calendar }

    public var count: Int { entries.count }

    /// Holds one dictation. Its calendar day is taken now, from this calendar's time zone as it is
    /// now, and kept; `epoch` is the data epoch it was recorded in.
    public mutating func hold(_ input: DictationMetricInput, at now: Date, epoch: Int = 0) -> UUID {
        let id = UUID()
        entries[id] = Entry(event: try? input.event(), heldAt: now, day: try? MetricsDay(date: now, calendar: calendar), epoch: epoch)
        return id
    }

    private func isSameDay(_ entry: Entry, as now: Date) -> Bool {
        guard let day = entry.day, let today = try? MetricsDay(date: now, calendar: calendar) else { return false }
        return day == today
    }

    public mutating func resolve(
        _ id: UUID, observation: DictationFeedback.EditObservation, coverage: DictationFeedback.EditCoverage,
        size: MetricsEditSize? = nil, at now: Date
    ) -> Released? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        guard let event = entry.event else { return nil }
        let result = isSameDay(entry, as: now) ? event.withEdit(observation: observation, coverage: coverage, size: size) : event
        return result.flatMap { release(entry, event: $0) }
    }

    public mutating func expire(at now: Date) -> [Released] {
        let due = entries.filter { now.timeIntervalSince($0.value.heldAt) >= Self.window }
        return due.keys.compactMap { release(entries.removeValue(forKey: $0)) }
    }

    public mutating func drain() -> [Released] {
        let all = entries.values.compactMap { release($0) }
        entries.removeAll()
        return all
    }

    /// Releases, as not checked, every dictation held from a calendar day before `now`'s.
    public mutating func drainBefore(_ now: Date) -> [Released] {
        let prior = entries.filter { !isSameDay($0.value, as: now) }
        return prior.keys.compactMap { release(entries.removeValue(forKey: $0)) }
    }

    /// Forgets everything without releasing it (sharing switched off).
    public mutating func discardAll() { entries.removeAll() }

    private func release(_ entry: Entry?) -> Released? {
        entry.flatMap { held in held.event.flatMap { release(held, event: $0) } }
    }

    private func release(_ entry: Entry, event: DictationMetricEvent) -> Released? {
        entry.day.map { Released(event: event, heldAt: entry.heldAt, day: $0, epoch: entry.epoch) }
    }
}
