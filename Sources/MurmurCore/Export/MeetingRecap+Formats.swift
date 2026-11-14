import Foundation

/// One section of a recap, rendered by each output format in its own way.
private struct RecapBlock {
    enum Style { case paragraph, bullets, checklist, prose }
    let heading: String
    let style: Style
    let lines: [String]
    /// For a checklist: which lines are checked off, and the fields of each (for rich text).
    var done: [Bool] = []
    var details: [ActionItemDetail]?

    func isDone(_ index: Int) -> Bool { done.indices.contains(index) && done[index] }
}

extension MeetingRecap {
    /// Plain text for a message, a chat or a note: headings on their own line, "- " lists.
    public var plainText: String {
        var parts = [[title, metaLine].filter { !$0.isEmpty }]
        if let who = attendeeLine { parts.append(["Who was there: \(who)"]) }
        for block in blocks {
            parts.append([block.heading] + plainRows(block))
        }
        return parts.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }

    /// Markdown for tools that render it (Slack, Notion, GitHub, Obsidian). Action items are
    /// `- [ ]` task items, like the full-note export.
    public var markdown: String {
        var parts = ["# \(title)"]
        if !metaLine.isEmpty { parts.append("*\(metaLine)*") }
        if let who = attendeeLine { parts.append("**Who was there:** \(who)") }
        for block in blocks {
            let rows: [String]
            switch block.style {
            case .bullets: rows = block.lines.map { "- \($0)" }
            case .checklist: rows = block.lines.indices.map { "- [\(block.isDone($0) ? "x" : " ")] \(block.lines[$0])" }
            case .paragraph, .prose: rows = [block.lines.joined(separator: block.style == .prose ? "\n\n" : "\n")]
            }
            parts.append("## \(block.heading)\n\n" + rows.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Rich text for a mail body: put it on the pasteboard as HTML next to the plain text and a
    /// mail app pastes it formatted. Every piece of the user's words is escaped.
    public var html: String {
        var out = ["<h2>\(Self.escape(title))</h2>"]
        if !metaLine.isEmpty { out.append("<p><em>\(Self.escape(metaLine))</em></p>") }
        if let who = attendeeLine { out.append("<p><strong>Who was there:</strong> \(Self.escape(who))</p>") }
        for block in blocks {
            out.append("<h3>\(block.heading)</h3>")
            switch block.style {
            case .bullets: out.append("<ul>" + block.lines.map { "<li>\(Self.escape($0))</li>" }.joined() + "</ul>")
            case .checklist: out.append("<ul>" + block.lines.indices.map { Self.htmlItem(block, $0) }.joined() + "</ul>")
            case .paragraph, .prose: out += block.lines.map { "<p>\(Self.escape($0))</p>" }
            }
        }
        return "<html><body>" + out.joined(separator: "\n") + "</body></html>"
    }

    /// "- Priya: Send the deck — by Friday", with " (done)" after a checked-off item.
    private func plainRows(_ block: RecapBlock) -> [String] {
        switch block.style {
        case .bullets: return block.lines.map { "- \($0)" }
        case .checklist: return block.lines.indices.map { "- \(block.lines[$0])\(block.isDone($0) ? " (done)" : "")" }
        case .paragraph, .prose: return block.lines
        }
    }

    /// One list item; the owner is bold when the note has it as a field, and a checked-off item is struck through.
    private static func htmlItem(_ block: RecapBlock, _ index: Int) -> String {
        var text = escape(block.lines[index])
        if let detail = block.details?[index], !detail.owner.isEmpty, block.lines[index].hasPrefix(detail.owner + ": ") {
            text = "<strong>\(escape(detail.owner))</strong>: " + escape(String(block.lines[index].dropFirst(detail.owner.count + 2)))
        }
        return block.isDone(index) ? "<li><s>\(text)</s> (done)</li>" : "<li>\(text)</li>"
    }

    private var attendeeLine: String? { attendees.isEmpty ? nil : attendees.joined(separator: ", ") }

    private var blocks: [RecapBlock] {
        var result: [RecapBlock] = []
        if !summaryPoints.isEmpty {
            result.append(RecapBlock(
                heading: "Summary", style: summaryPoints.count == 1 ? .paragraph : .bullets, lines: summaryPoints))
        }
        if !actionItems.isEmpty {
            result.append(RecapBlock(
                heading: "Action items", style: .checklist, lines: actionItems, done: actionDone, details: actionDetails))
        }
        if let transcript {
            let paragraphs = transcript.components(separatedBy: .newlines).map(Self.trimmed).filter { !$0.isEmpty }
            result.append(RecapBlock(heading: "Transcript", style: .prose, lines: paragraphs))
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
