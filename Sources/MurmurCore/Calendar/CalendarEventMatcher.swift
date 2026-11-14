import Foundation

/// Pure helpers for the two calendar features that don't need a banner: naming a recording after
/// the meeting it overlaps, and offering attendee names when labelling speakers.
/// See `docs/product/CONNECTORS.md` §2.1.
public enum CalendarEventMatcher {
    /// A recording started this long before a meeting's start still counts as that meeting
    /// (people press Record while the call connects).
    public static let earlyStartTolerance: TimeInterval = 5 * 60

    /// The meeting a recording that started at `recordingStart` belongs to, or `nil`.
    /// Prefers an event already in progress, then one starting within `earlyStartTolerance`;
    /// among candidates, the one whose start is closest to the recording. Non-meetings (all-day,
    /// declined, no people and no video link) never match, so a "Focus time" block does not rename
    /// a memo dictated during it.
    public static func event(overlapping recordingStart: Date, in events: [CalendarEvent]) -> CalendarEvent? {
        events
            .filter { event in
                event.looksLikeMeeting
                    && recordingStart < event.end
                    && recordingStart >= event.start.addingTimeInterval(-earlyStartTolerance)
            }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs.start.timeIntervalSince(recordingStart))
                let rhsDistance = abs(rhs.start.timeIntervalSince(recordingStart))
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.eventIdentifier < rhs.eventIdentifier
            }
    }

    /// The title a new note gets: the overlapping meeting's title when there is one, otherwise
    /// `fallback` (the recorder's "Note · date"). Never `nil`, never empty.
    public static func recordingTitle(startedAt recordingStart: Date, events: [CalendarEvent], fallback: String) -> String {
        event(overlapping: recordingStart, in: events)?.usableTitle ?? fallback
    }

    /// Names to offer when labelling speakers: every other attendee's name, deduplicated in
    /// invite order, with the user and anyone who declined left out. Only ever a suggestion;
    /// attendee is not the same as speaker, so nothing is assigned automatically.
    public static func speakerNameSuggestions(for event: CalendarEvent) -> [String] {
        var seen = Set<String>()
        return event.otherAttendees
            .filter { $0.status != .declined }
            .map { attendee in
                let trimmed = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
                // EventKit falls back to the address when an invitee has no display name.
                return trimmed.isEmpty ? (attendee.email ?? "") : trimmed
            }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
