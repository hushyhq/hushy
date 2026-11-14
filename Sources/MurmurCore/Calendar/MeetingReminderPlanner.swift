import Foundation

/// Pure decision logic for "Weekly sync starts in 1 min — Record?", the calendar counterpart of
/// `CallDetectionState`. Given the events in the next few minutes and the clock, it decides when
/// to show one reminder, when it lapses, and which meeting to start recording — and never touches
/// EventKit, a `Timer`, `UserDefaults` or the pill. The coordinator (after Checkpoint B) polls
/// the reader, feeds `observe`, and maps `Effect` onto the same banner slot the call-detected
/// prompt uses. See `docs/product/CONNECTORS.md` §2.1 for the rules this encodes.
public struct MeetingReminderPlanner: Sendable, Equatable {
    /// A visible reminder for one meeting occurrence.
    public struct Reminder: Sendable, Equatable {
        public let event: CalendarEvent
        /// When the reminder disappears unanswered: `lateGrace` after the start.
        public let expiresAt: Date

        public init(event: CalendarEvent, expiresAt: Date) {
            self.event = event
            self.expiresAt = expiresAt
        }

        /// "Weekly sync starts in 1 min" / "starts now" / "started 2 min ago" — the banner's line.
        public func headline(now: Date) -> String {
            let seconds = event.start.timeIntervalSince(now)
            let title = event.usableTitle ?? "Meeting"
            if seconds > 30 {
                let minutes = Int((seconds / 60).rounded(.up))
                return "\(title) starts in \(minutes) min"
            }
            if seconds > -30 { return "\(title) starts now" }
            let minutes = max(1, Int((-seconds / 60).rounded()))
            return "\(title) started \(minutes) min ago"
        }
    }

    public enum Effect: Sendable, Equatable {
        case none
        /// Show the reminder banner near the pill.
        case showReminder(Reminder)
        /// Take the banner down (lapsed, setting turned off, or a recording started another way).
        case dismissReminder
    }

    /// How far ahead of the start the reminder appears — Wispr's "before they begin", one minute.
    public static let leadTime: TimeInterval = 60
    /// How long after the start an unanswered reminder stays: people join late.
    public static let lateGrace: TimeInterval = 5 * 60
    /// How far ahead a coordinator queries the calendar so `observe` sees the next reminder in
    /// time; wider than `leadTime` to absorb a slow poll.
    public static let lookahead: TimeInterval = 15 * 60

    public private(set) var pending: Reminder?
    /// Occurrences already reminded about (shown, accepted or dismissed). Pruned as they age out
    /// so the set never grows across a long-running app session.
    private var handled: Set<CalendarEvent.OccurrenceID>

    public init(handled: Set<CalendarEvent.OccurrenceID> = []) {
        self.handled = handled
    }

    /// The occurrences this planner will not remind about again. Exposed for persistence tests.
    public var handledOccurrences: Set<CalendarEvent.OccurrenceID> { handled }

    /// Feeds one observation. Safe to call every tick with the same inputs.
    ///
    /// - Parameters:
    ///   - events: whatever the reader returned for `[now, now + lookahead)`; filtering to
    ///     meetings happens here so the reader stays dumb.
    ///   - isEnabled: the "Remind me to record" setting; off means no reminder and any pending one
    ///     is dismissed.
    ///   - isRecording: a note is already recording — never remind on top of it.
    public mutating func observe(events: [CalendarEvent], isEnabled: Bool, isRecording: Bool, now: Date) -> Effect {
        prune(now: now)

        if let reminder = pending {
            if !isEnabled || isRecording || now >= reminder.expiresAt {
                pending = nil
                return .dismissReminder
            }
            return .none
        }

        guard isEnabled, !isRecording else { return .none }
        guard let event = Self.nextMeeting(in: events, now: now, excluding: handled) else { return .none }
        let reminder = Reminder(event: event, expiresAt: event.start.addingTimeInterval(Self.lateGrace))
        pending = reminder
        handled.insert(event.id)
        return .showReminder(reminder)
    }

    /// Advances the clock without fresh events, for expiry between polls.
    public mutating func tick(now: Date) -> Effect {
        prune(now: now)
        guard let reminder = pending, now >= reminder.expiresAt else { return .none }
        pending = nil
        return .dismissReminder
    }

    /// User tapped Record: returns the meeting to record, titled by the caller from
    /// `event.usableTitle`.
    public mutating func accept() -> CalendarEvent? {
        defer { pending = nil }
        return pending?.event
    }

    /// User tapped Not now. Final for that occurrence.
    public mutating func dismiss() {
        pending = nil
    }

    /// The meeting to remind about: inside its window (`leadTime` before start until `lateGrace`
    /// after), not yet handled, earliest start first, then the one with more people.
    static func nextMeeting(in events: [CalendarEvent], now: Date, excluding handled: Set<CalendarEvent.OccurrenceID>) -> CalendarEvent? {
        events
            .filter { event in
                event.looksLikeMeeting
                    && !handled.contains(event.id)
                    && now >= event.start.addingTimeInterval(-leadTime)
                    && now < event.start.addingTimeInterval(lateGrace)
                    && now < event.end
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.otherAttendees.count != rhs.otherAttendees.count {
                    return lhs.otherAttendees.count > rhs.otherAttendees.count
                }
                return lhs.eventIdentifier < rhs.eventIdentifier
            }
            .first
    }

    private mutating func prune(now: Date) {
        // Anything whose reminder window closed more than a day ago cannot come back.
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        handled = handled.filter { $0.start > cutoff }
    }
}
