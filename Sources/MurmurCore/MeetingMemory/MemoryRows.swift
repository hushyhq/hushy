import Foundation

/// The settled rows, as values. Read once from the memory database after it is built; every
/// answer is a filter over these plus FTS5 for quotes. Personal data: never log or meter them.
public struct MemoryMeeting: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let title: String
    public let start: Date
    public let end: Date
    public let seriesKey: String?
    /// Only the user's own company was in it.
    public let isInternal: Bool
    /// Person id → how they were in it ("attendee", "speaker", "mentioned").
    public let people: [Int64: Set<String>]
    public let companies: Set<Int64>
}

public struct MemoryPerson: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let companyId: Int64?
    public let isSelf: Bool
}

public struct MemoryCompany: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let domain: String?
    public let name: String
    public let isOwn: Bool
}

public struct MemoryDecision: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let noteId: Int64
    public let text: String
    public let quoteTurn: Int?
    /// The later decision on the same subject that replaced this one.
    public let supersededBy: Int64?
}

public struct MemoryItem: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case open, done, cancelled }

    public let id: Int64
    public let noteId: Int64
    /// The item's index in its note, the one the note page ticks off.
    public let ordinal: Int
    public let ownerText: String
    public let ownerId: Int64?
    public let task: String
    public let due: String
    public let status: Status
    public let quoteTurn: Int?
    /// The later meeting where it was said to be done or dropped (nil when ticked off in the app).
    public let closedNoteId: Int64?
    public let closedTurn: Int?
    /// The earlier item this one restates.
    public let duplicateOf: Int64?
}

/// Where a line comes from: the meeting and the moment, with the words said there.
public struct MemoryQuote: Sendable, Equatable {
    public let noteId: Int64
    public let ordinal: Int
    public let speaker: String?
    public let startSeconds: Double?
    public let text: String

    /// `hushy://note/<id>?t=<seconds>`, the moment in the meeting; just the meeting when the time is
    /// not a finite, representable number of seconds.
    public var link: URL {
        var string = "hushy://note/\(noteId)"
        if let startSeconds, startSeconds >= 0, let seconds = Int(exactly: startSeconds.rounded(.down)) {
            string += "?t=\(seconds)"
        }
        return URL(string: string)!
    }
}
