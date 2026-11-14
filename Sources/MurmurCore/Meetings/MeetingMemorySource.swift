import Foundation

/// What Hushy knows across meetings, as the between-meetings screens read it. `EngineMeetingMemory`
/// answers from the cross-meeting rows (`MeetingMemory`, `docs/product/meeting-memory-api.md`).
/// Every answer is composed in code from stored rows, never merged by a model (0 of 32 when we
/// tried, meetings plan §3.1).
public protocol MeetingMemorySource: Sendable {
    /// People met in recorded meetings, most recent first.
    func people(limit: Int, myNames: [String]) throws -> [MeetingPerson]
    /// Companies met, most recent first, from attendee email domains and introductions.
    func companies(limit: Int) throws -> [MeetingCompany]
    /// Every meeting with someone or some company, newest first, with what was decided and owed.
    func timeline(for subject: MeetingSubject, myNames: [String]) throws -> [MeetingTimelineEntry]
    /// Open action items across meetings, split into what I owe and what I'm owed.
    func commitments(myNames: [String]) throws -> MeetingCommitments
    /// A brief for an upcoming event from earlier meetings with the same people or series.
    func prep(for event: CalendarEvent, myNames: [String]) throws -> MeetingPrep
    /// A dated list of decisions, items, notes and quotes matching a question.
    func ask(_ question: String, myNames: [String]) throws -> MeetingAnswer
}

public enum MeetingSubject: Sendable, Hashable {
    case person(String)
    case company(String)

    public var name: String {
        switch self {
        case let .person(name), let .company(name): name
        }
    }
}

public struct MeetingPerson: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name.lowercased() }
    public let name: String
    public let meetingCount: Int
    public let lastMet: Date
    public let openItems: Int

    public init(name: String, meetingCount: Int, lastMet: Date, openItems: Int) {
        self.name = name
        self.meetingCount = meetingCount
        self.lastMet = lastMet
        self.openItems = openItems
    }
}

public struct MeetingCompany: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name.lowercased() }
    public let name: String
    public let people: [String]
    public let meetingCount: Int
    public let lastMet: Date

    public init(name: String, people: [String], meetingCount: Int, lastMet: Date) {
        self.name = name
        self.people = people
        self.meetingCount = meetingCount
        self.lastMet = lastMet
    }
}

/// One item owed, wherever it was promised, with the way back to the moment.
public struct MeetingItemRef: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(noteId)-\(itemIndex)" }
    public let noteId: Int64
    public let noteTitle: String
    public let noteDate: Date
    public let itemIndex: Int
    public let detail: ActionItemDetail
    public let isMine: Bool

    public init(noteId: Int64, noteTitle: String, noteDate: Date, itemIndex: Int, detail: ActionItemDetail, isMine: Bool) {
        self.noteId = noteId
        self.noteTitle = noteTitle
        self.noteDate = noteDate
        self.itemIndex = itemIndex
        self.detail = detail
        self.isMine = isMine
    }
}

public struct MeetingCommitments: Sendable, Equatable {
    public let iOwe: [MeetingItemRef]
    public let owedToMe: [MeetingItemRef]
    /// Open items nobody took, so they are not lost.
    public let unowned: [MeetingItemRef]

    public init(iOwe: [MeetingItemRef], owedToMe: [MeetingItemRef], unowned: [MeetingItemRef]) {
        self.iOwe = iOwe
        self.owedToMe = owedToMe
        self.unowned = unowned
    }

    public var isEmpty: Bool { iOwe.isEmpty && owedToMe.isEmpty && unowned.isEmpty }
}

public struct MeetingTimelineEntry: Sendable, Equatable, Identifiable {
    public var id: Int64 { noteId }
    public let noteId: Int64
    public let title: String
    public let date: Date
    public let durationSeconds: Double
    public let decisions: [String]
    public let openItems: [MeetingItemRef]
    public let people: [String]

    public init(noteId: Int64, title: String, date: Date, durationSeconds: Double, decisions: [String], openItems: [MeetingItemRef], people: [String]) {
        self.noteId = noteId
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.decisions = decisions
        self.openItems = openItems
        self.people = people
    }
}

public struct MeetingPrep: Sendable, Equatable {
    public let eventTitle: String
    public let start: Date
    /// Attendees other than the person.
    public let attendees: [String]
    /// The most recent earlier meetings with these people or this series, newest first.
    public let lastTime: [MeetingTimelineEntry]
    /// Still open from those meetings.
    public let stillOpen: [MeetingItemRef]
    /// Talking points to start the notepad with: open items and earlier open questions.
    public let talkingPoints: [String]

    public init(eventTitle: String, start: Date, attendees: [String], lastTime: [MeetingTimelineEntry], stillOpen: [MeetingItemRef], talkingPoints: [String]) {
        self.eventTitle = eventTitle
        self.start = start
        self.attendees = attendees
        self.lastTime = lastTime
        self.stillOpen = stillOpen
        self.talkingPoints = talkingPoints
    }

    public var isFirstMeeting: Bool { lastTime.isEmpty }
}

public struct MeetingAnswer: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case decision, item, closed, changed, yourNote, quote, meeting
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public var id: String { "\(noteId)-\(kind.rawValue)-\(text.hashValue)" }
        public let noteId: Int64
        public let noteTitle: String
        public let noteDate: Date
        public let kind: Kind
        public let text: String
        /// Who said `quote`, or the speaker of a `.quote` line.
        public let speaker: String?
        public let atSeconds: Double?
        /// The words said at the moment that backs a decision or item line.
        public let quote: String?

        public init(noteId: Int64, noteTitle: String, noteDate: Date, kind: Kind, text: String, speaker: String? = nil,
                    atSeconds: Double? = nil, quote: String? = nil) {
            self.noteId = noteId
            self.noteTitle = noteTitle
            self.noteDate = noteDate
            self.kind = kind
            self.text = text
            self.speaker = speaker
            self.atSeconds = atSeconds
            self.quote = quote
        }

        /// `hushy://note/<id>?t=<seconds>`, the same link the MCP tools cite.
        public var link: URL {
            var string = "hushy://note/\(noteId)"
            if let atSeconds, let whole = Int(exactly: atSeconds.rounded(.down)) { string += "?t=\(whole)" }
            return URL(string: string)!
        }
    }

    public let question: String
    /// What the answer is ("Open commitments with Priya"); nil when the source has none.
    public let heading: String?
    public let lines: [Line]
    /// Said when nothing matched, so an empty answer is never a blank.
    public let emptyReason: String?

    public init(question: String, heading: String? = nil, lines: [Line], emptyReason: String?) {
        self.question = question
        self.heading = heading
        self.lines = lines
        self.emptyReason = emptyReason
    }
}
