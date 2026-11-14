import Foundation
import GRDB

/// Read-only meeting-memory tools for the MCP helper: questions answered in code from the rows,
/// open commitments, and the rows themselves as JSON so the person's own agent (Claude Code,
/// Codex) can do heavier reasoning over them. Everything is built from the database the helper
/// already reads; nothing is written and nothing leaves the Mac except to that local client.
enum MeetingMemoryTools {
    static let names: Set<String> = ["meeting_memory", "meeting_commitments", "meeting_rows"]

    static var definitions: [[String: Any]] { [
        tool("meeting_memory",
             "Answer a question across all recorded meetings (decisions with a company or person, what someone owes, what changed since the last meeting, anything said about a topic). The answer is composed from stored decisions, action items, people and companies; every line names its meeting and date and links to the moment (hushy://note/<id>?t=<seconds>).",
             properties: ["question": ["type": "string", "description": "The question, as the user asked it"]], required: ["question"]),
        tool("meeting_commitments",
             "Open action items across meetings: what the user owes, what others owe the user, optionally for one person or company. Items ticked off, closed in a later meeting or dropped are left out.",
             properties: [
                "person": ["type": "string", "description": "A person's name (optional)"],
                "company": ["type": "string", "description": "A company's name (optional)"],
                "direction": ["type": "string", "enum": ["mine", "theirs", "both"], "description": "Whose items (default both)"],
             ], required: []),
        tool("meeting_rows",
             "The stored meeting rows as JSON: meetings (id, title, start, series), people and companies with the meetings they were in, decisions (with what replaced them) and action items (owner, due, status, where closed), each with its quote. For reasoning across many meetings yourself.",
             properties: ["since": ["type": "string", "description": "ISO-8601 date; only meetings from then on (optional)"],
                          "limit": ["type": "integer", "description": "Most meetings to include, newest first (default 50)"]],
             required: []),
    ] }

    static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    static func call(_ name: String, arguments: [String: Any], db: Database, now: Date, timeZone: TimeZone) throws -> String {
        let records = try Store.meetingRecords(db)
        guard !records.isEmpty else { return "No recorded meetings yet." }
        let memory = try MeetingMemory(records: records, selfNames: ["You", "Me"])
        let context = DateContext(now: now, timeZone: timeZone)
        switch name {
        case "meeting_memory":
            guard let question = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
                throw MCPServer.ToolError(message: "Missing string argument: question")
            }
            return text(memory.ask(question, context: context), context: context)
        case "meeting_commitments":
            let who = [arguments["person"] as? String, arguments["company"] as? String].compactMap { $0 }.joined(separator: " at ")
            let direction = arguments["direction"] as? String ?? "both"
            let question = switch direction {
            case "mine": who.isEmpty ? "What do I owe?" : "What do I owe \(who)?"
            case "theirs": who.isEmpty ? "What is owed to me?" : "What does \(who) owe me?"
            default: who.isEmpty ? "What open action items are there?" : "What open items are there with \(who)?"
            }
            return text(memory.ask(question, context: context), context: context)
        case "meeting_rows":
            let since = (arguments["since"] as? String).flatMap(ProposalFields.parseISO8601)
            let limit = min(max(arguments["limit"] as? Int ?? 50, 1), 500)
            return rows(memory, since: since, limit: limit, context: context)
        default:
            throw MCPServer.ToolError(message: "Unknown tool: \(name)")
        }
    }

    /// The answer as text for an agent: each line with its meeting, date, link and quote.
    static func text(_ answer: MemoryAnswer, context: DateContext) -> String {
        var out = [answer.heading]
        for section in answer.sections where !section.lines.isEmpty {
            out.append("")
            out.append("\(section.title):")
            for line in section.lines {
                var entry = "- \(line.text) — \(line.meeting.title), \(MemoryDates.label(line.meeting.start, context: context))"
                if let quote = line.quote {
                    entry += " <\(quote.link.absoluteString)> \"\(quote.speaker.map { "\($0): " } ?? "")\(quote.text)\""
                } else {
                    entry += " <hushy://note/\(line.meeting.noteId)>"
                }
                out.append(entry)
            }
        }
        return out.joined(separator: "\n")
    }

    static func rows(_ memory: MeetingMemory, since: Date?, limit: Int, context: DateContext) -> String {
        let meetings = memory.meetings.values.filter { meeting in since.map { meeting.start >= $0 } ?? true }
            .sorted { $0.start > $1.start }.prefix(limit)
        let ids = Set(meetings.map(\.id))
        let iso = ISO8601DateFormatter()
        iso.timeZone = context.timeZone
        func quote(_ noteId: Int64, _ ordinal: Int?) -> Any {
            guard let quote = memory.quote(noteId: noteId, ordinal: ordinal) else { return NSNull() }
            return ["speaker": quote.speaker ?? NSNull(), "text": quote.text, "link": quote.link.absoluteString] as [String: Any]
        }
        let json: [String: Any] = [
            "meetings": meetings.map { meeting -> [String: Any] in
                ["id": meeting.id, "title": meeting.title, "start": iso.string(from: meeting.start), "series": meeting.seriesKey ?? NSNull(),
                 "people": meeting.people.keys.sorted().map { ["person": $0, "how": Array(meeting.people[$0] ?? []).sorted()] },
                 "companies": meeting.companies.sorted()]
            },
            "people": memory.people.values.sorted { $0.id < $1.id }.map {
                ["id": $0.id, "name": $0.name, "company": $0.companyId ?? NSNull(), "isUser": $0.isSelf] as [String: Any]
            },
            "companies": memory.companies.values.sorted { $0.id < $1.id }.map {
                ["id": $0.id, "name": $0.name, "domain": $0.domain ?? NSNull(), "isOwn": $0.isOwn] as [String: Any]
            },
            "decisions": memory.decisions.filter { ids.contains($0.noteId) }.map {
                ["id": $0.id, "meeting": $0.noteId, "text": $0.text, "replacedBy": $0.supersededBy ?? NSNull(), "quote": quote($0.noteId, $0.quoteTurn)] as [String: Any]
            },
            "actionItems": memory.items.filter { ids.contains($0.noteId) && $0.duplicateOf == nil }.map { item -> [String: Any] in
                ["id": item.id, "meeting": item.noteId, "owner": memory.ownerName(item), "task": item.task, "due": item.due,
                 "status": item.status.rawValue, "closedIn": item.closedNoteId ?? NSNull(), "quote": quote(item.noteId, item.quoteTurn),
                 "closingQuote": item.closedNoteId.map { quote($0, item.closedTurn) } ?? NSNull()]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
