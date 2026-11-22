import Foundation

/// How a meeting's visible facts read in exports, the recap and MCP: grouped by kind, each with its owner and due,
/// its `[mm:ss]` moment as a `hushy://note/<id>?t=<s>` link, and the words it was said in.
public enum MeetingFactText {
    public struct Section: Sendable, Equatable {
        public let kind: MeetingFact.Kind
        public let title: String
        public let facts: [MeetingFact]
    }

    static let order: [(MeetingFact.Kind, String)] = [
        (.decision, "Decisions"), (.action, "Action items"), (.openQuestion, "Open questions"), (.change, "Changes"),
    ]

    /// The non-empty sections in reading order (decisions, action items, open questions, changes).
    public static func sections(_ facts: [MeetingFact]) -> [Section] {
        order.compactMap { kind, title in
            let ofKind = facts.filter { $0.kind == kind && $0.isVisible }.sorted { ($0.ordinal, $0.id ?? 0) < ($1.ordinal, $1.id ?? 0) }
            return ofKind.isEmpty ? nil : Section(kind: kind, title: title, facts: ofKind)
        }
    }

    /// "Priya: Send the deck — by Friday"; no owner prefix when nobody took it.
    public static func line(_ fact: MeetingFact) -> String { detail(fact).line }

    /// The fact as action-item fields, the sentence without its final full stop, as items have always read.
    public static func detail(_ fact: MeetingFact) -> ActionItemDetail {
        ActionItemDetail(owner: fact.ownerText ?? "", task: Punctuation.stripTrailing(oneLine(fact.text)), due: fact.due ?? "")
    }

    /// "04:05", or "1:02:10" past an hour.
    public static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite && seconds > 0 ? Int(seconds) : 0
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// `hushy://note/<id>?t=<seconds>`.
    public static func url(noteId: Int64, seconds: Double) -> String {
        "hushy://note/\(noteId)?t=\(seconds.isFinite && seconds > 0 ? Int(seconds) : 0)"
    }

    /// "[04:05](hushy://note/12?t=245)", or nil for a fact with no moment.
    public static func markdownLink(_ fact: MeetingFact, noteId: Int64) -> String? {
        fact.t0.map { "[\(clock($0))](\(url(noteId: noteId, seconds: $0)))" }
    }

    /// One Markdown list item, and the quote under it.
    public static func markdown(_ fact: MeetingFact, noteId: Int64) -> [String] {
        let box = fact.kind == .action ? "[\(fact.status == .done ? "x" : " ")] " : ""
        let link = markdownLink(fact, noteId: noteId).map { " \($0)" } ?? ""
        var lines = ["- \(box)\(line(fact))\(link)"]
        if let quote = fact.quote, !quote.isEmpty { lines.append("  > \(oneLine(quote))") }
        return lines
    }

    /// Plain text for the recap and Apple Notes: the line and "(04:05)".
    public static func plain(_ fact: MeetingFact) -> String {
        line(fact) + (fact.t0.map { " (\(clock($0)))" } ?? "")
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// The summary's key points. A summary written before facts carried "- Decided: …" lines; those decisions are facts
/// now (the v29 backfill), so they are left out here rather than shown twice. The only reader of those lines.
public enum LegacySummary {
    public static func keyPoints(_ summary: String) -> [String] {
        summary.components(separatedBy: .newlines).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "• ", "* "] where line.hasPrefix(bullet) { line = String(line.dropFirst(bullet.count)) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("Decided:") else { return nil }
            return line
        }
    }
}
