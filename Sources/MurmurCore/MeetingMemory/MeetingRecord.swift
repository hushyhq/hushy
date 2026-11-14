import Foundation

/// One summarised meeting as meeting memory reads it: what was said, by whom, what the summary
/// decided and assigned, and who was invited. Built from Hushy's stored note in exactly one place
/// (`MeetingRecord.init(note:…)`), so a change to the summary types changes one mapping.
public struct MeetingRecord: Sendable, Equatable {
    public struct Attendee: Sendable, Equatable {
        public var name: String
        /// "acme.com"; nil for a personal mail domain or no address.
        public var companyDomain: String?
        public var isSelf: Bool

        public init(name: String, companyDomain: String? = nil, isSelf: Bool = false) {
            self.name = name
            self.companyDomain = companyDomain
            self.isSelf = isSelf
        }
    }

    /// One speaker turn, or one sentence when the note has no speaker turns.
    public struct Turn: Sendable, Equatable {
        public var speaker: String?
        /// Seconds from the start of the recording, when known.
        public var startSeconds: Double?
        public var text: String

        public init(speaker: String? = nil, startSeconds: Double? = nil, text: String) {
            self.speaker = speaker
            self.startSeconds = startSeconds
            self.text = text
        }
    }

    public struct ActionItem: Sendable, Equatable {
        /// As the summary wrote it ("Priya", "You"); empty when nobody took it.
        public var owner: String
        public var task: String
        public var due: String
        /// Ticked off in the app.
        public var isDone: Bool

        public init(owner: String = "", task: String, due: String = "", isDone: Bool = false) {
            self.owner = owner
            self.task = task
            self.due = due
            self.isDone = isDone
        }
    }

    public var noteId: Int64
    public var title: String
    public var start: Date
    public var end: Date
    /// Shared by every occurrence of one recurring calendar event; nil for an ad hoc meeting.
    public var seriesKey: String?
    public var attendees: [Attendee]
    public var turns: [Turn]
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]

    public init(
        noteId: Int64, title: String, start: Date, end: Date, seriesKey: String? = nil, attendees: [Attendee] = [],
        turns: [Turn] = [], keyPoints: [String] = [], decisions: [String] = [], actionItems: [ActionItem] = []
    ) {
        self.noteId = noteId
        self.title = title
        self.start = start
        self.end = end
        self.seriesKey = seriesKey
        self.attendees = attendees
        self.turns = turns
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
    }
}
