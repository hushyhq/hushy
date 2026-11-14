import Foundation

/// A meeting as an answer line names it.
public struct MemoryMeetingRef: Sendable, Equatable, Hashable {
    public let noteId: Int64
    public let title: String
    public let start: Date
}

/// One line of an answer: one fact from one row, with the meeting and moment it came from.
public struct MemoryLine: Sendable, Equatable {
    public enum Kind: String, Sendable { case decision, item, closed, changed, quote, meeting }

    public let kind: Kind
    public var text: String
    public let meeting: MemoryMeetingRef
    /// The words said at that moment; nil when no turn carried the fact (it is in the summary).
    public let quote: MemoryQuote?
    /// The row it came from ("decision:12", "item:4"), so a phrased line can be traced back.
    public let rowKey: String
}

public struct MemorySection: Sendable, Equatable {
    public let title: String
    public var lines: [MemoryLine]
}

/// An answer composed in code from rows. Nothing in it comes from a model unless `phrasedBy` is
/// set, and even then every line keeps its row's meeting and quote.
public struct MemoryAnswer: Sendable, Equatable {
    public enum Kind: String, Sendable { case decisions, commitments, changes, prep, search, none }

    public let kind: Kind
    public var heading: String
    public var sections: [MemorySection]
    /// Meetings that matched but had nothing to say on it ("These Acme meetings had no decision").
    public let meetingsWithNothing: [MemoryMeetingRef]
    /// True when the honest answer is that there is nothing.
    public let isDecline: Bool
    public var phrasedBy: String?

    public var lines: [MemoryLine] { sections.flatMap(\.lines) }

    static func decline(_ kind: Kind, _ message: String) -> MemoryAnswer {
        MemoryAnswer(kind: kind, heading: message, sections: [], meetingsWithNothing: [], isDecline: true)
    }

    /// Plain text for a chat, a tool result or a test: the heading, each section with its lines,
    /// each line ending with its meeting and date.
    public func plainText(context: DateContext) -> String {
        var out = [heading]
        for section in sections where !section.lines.isEmpty {
            out.append("")
            out.append(section.title)
            for line in section.lines {
                out.append("- \(line.text) (\(line.meeting.title), \(MemoryDates.label(line.meeting.start, context: context)))")
            }
        }
        if !meetingsWithNothing.isEmpty {
            out.append("")
            out.append("Nothing on this in: " + meetingsWithNothing.map {
                "\($0.title) (\(MemoryDates.label($0.start, context: context)))"
            }.joined(separator: "; "))
        }
        return out.joined(separator: "\n")
    }
}
