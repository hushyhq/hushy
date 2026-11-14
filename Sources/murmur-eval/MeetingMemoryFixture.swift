import Foundation
import MurmurCore

/// A `hushy.meeting-memory/v1` set (`Evals/meeting-memory/README.md`): invented meetings, upcoming
/// events and questions. `seed(into:)` writes the meetings into a store the way the app stores a
/// summarised meeting (note, summary lines, item fields, ticks, calendar match, speaker turns), so
/// memory built from it goes through the same mapping as the app's.
struct MeetingMemoryFixture: Decodable, Sendable {
    public struct Person: Decodable, Sendable {
        public var name: String
        public var email: String?
        public var isMe: Bool?
    }

    public struct Meeting: Decodable, Sendable {
        public struct Calendar: Decodable, Sendable {
            public var series: String?
            public var attendees: [Person]
        }
        public struct Turn: Decodable, Sendable {
            public var speaker: String?
            public var t: Double?
            public var text: String
        }
        public struct Summary: Decodable, Sendable {
            public struct Item: Decodable, Sendable {
                public var owner: String
                public var task: String
                public var due: String
            }
            public var keyPoints: [String]
            public var decisions: [String]
            public var actionItems: [Item]
        }
        public var id: String
        public var title: String
        public var start: String
        public var end: String
        public var calendar: Calendar?
        public var turns: [Turn]
        public var summary: Summary
        public var done: [Int]?
    }

    public struct Event: Decodable, Sendable {
        public var id: String
        public var title: String
        public var start: String
        public var end: String
        public var series: String?
        public var attendees: [Person]
    }

    public struct Case: Decodable, Sendable {
        public struct Fact: Decodable, Sendable {
            public var any: [String]
            public var meeting: String?
        }
        public var id: String
        public var kind: String
        public var now: String
        public var question: String
        public var facts: [Fact]
        public var forbidden: [String]
        public var decline: Bool
    }

    public var format: String
    public var name: String
    public var me: Person
    public var meetings: [Meeting]
    public var upcoming: [Event]
    public var cases: [Case]

    public static func load(_ url: URL) throws -> MeetingMemoryFixture {
        let set = try JSONDecoder().decode(MeetingMemoryFixture.self, from: Data(contentsOf: url))
        guard set.format == "hushy.meeting-memory/v1" else {
            throw NSError(domain: "MeetingMemoryFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected format \(set.format)"])
        }
        return set
    }

    static func date(_ text: String) -> Date {
        ProposalFields.parseISO8601(text) ?? Date(timeIntervalSince1970: 0)
    }

    static func attendee(_ person: Person) -> CalendarAttendee {
        CalendarAttendee(name: person.name, email: person.email, isCurrentUser: person.isMe == true, status: .accepted)
    }

    public var upcomingEvents: [CalendarEvent] {
        upcoming.map { event in
            CalendarEvent(eventIdentifier: event.series ?? event.id, title: event.title, start: Self.date(event.start),
                          end: Self.date(event.end), attendees: event.attendees.map(Self.attendee), iCalUID: event.series)
        }
    }

    /// Writes every meeting into `store`. Returns note id → meeting id.
    @discardableResult
    public func seed(into store: Store) throws -> [Int64: String] {
        var ids: [Int64: String] = [:]
        for meeting in meetings {
            let start = Self.date(meeting.start)
            let end = Self.date(meeting.end)
            let summary = meeting.summary.keyPoints.map { "- \($0)" } + meeting.summary.decisions.map { "- Decided: \($0)" }
            let details = meeting.summary.actionItems.map { ActionItemDetail(owner: $0.owner, task: $0.task, due: $0.due) }
            var note = Note(
                title: meeting.title, createdAt: start, updatedAt: start, durationSeconds: end.timeIntervalSince(start),
                transcript: meeting.turns.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n"),
                summary: summary.joined(separator: "\n"), status: .ready)
            note.setActionItems(details.map(\.line), details: details)
            let saved = try store.save(note)
            guard let noteId = saved.id else { continue }
            ids[noteId] = meeting.id
            for index in meeting.done ?? [] { try store.setActionItemDone(noteId: noteId, itemIndex: index, isDone: true) }
            if let calendar = meeting.calendar {
                let event = CalendarEvent(
                    eventIdentifier: calendar.series ?? "event-\(meeting.id)", title: meeting.title, start: start, end: end,
                    attendees: calendar.attendees.map(Self.attendee), iCalUID: calendar.series)
                if let match = NoteCalendarMatch(event: event) {
                    try store.applyCalendarMatch(match, toNote: noteId, replacingTitle: meeting.title)
                }
            }
            let names = meeting.turns.compactMap(\.speaker).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let speakers = names.enumerated().map { NoteSpeaker(noteId: noteId, label: "Speaker \($0.offset + 1)", displayName: $0.element) }
            let segments = meeting.turns.enumerated().map { index, turn -> (speakerIndex: Int?, segment: AlignedSegment) in
                let startTime = turn.t ?? Double(index * 30)
                let next = meeting.turns.indices.contains(index + 1) ? (meeting.turns[index + 1].t ?? startTime + 30) : startTime + 30
                return (turn.speaker.flatMap(names.firstIndex(of:)),
                        AlignedSegment(speakerLabel: turn.speaker ?? "", start: startTime, end: next, text: turn.text))
            }
            try store.replaceSpeakerSegments(noteId: noteId, speakers: speakers, segments: segments)
        }
        return ids
    }
}
