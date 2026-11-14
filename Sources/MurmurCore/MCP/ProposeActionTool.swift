import Foundation

/// `propose_action`: the one MCP tool that talks about doing something rather than reading.
/// It never does it. It checks an agent's proposal (a Calendar event, a Reminder, or a Shortcut
/// to run) and turns it into a `ProposedAction`, and that's all:
///
/// - **In Hushy's MCP server** (`MCPServer`), a valid proposal gets an acknowledgement back
///   ("proposed; awaiting the user's confirmation in Hushy") and an invalid one gets an error
///   the agent can correct. The server has no EventKit, no Shortcuts runner and no write
///   access to the database, so a call from Claude Desktop, Cursor or any other client is
///   harmless: nothing is shown or created anywhere.
/// - **In Hushy's Assistant chat**, the bridge sees the same tool call in the agent's stream,
///   runs the same validation, and shows a confirmation card. Only the user's click on that
///   card executes the action, through `ActionExecutor`, with Undo and an `ActionRecord`.
///
/// Field checks come from `ProposalFields`, shared with the connected `propose_*` tools
/// (`ConnectedProposalTools`), so every proposal is validated the same way everywhere.
public enum ProposeActionTool {
    public static let name = "propose_action"

    /// Why a proposal was rejected, worded for the agent (it's returned as the tool error).
    public typealias ValidationError = ProposalValidationError

    static let maxTitleLength = ProposalFields.maxTitleLength
    static let maxNotesLength = ProposalFields.maxNotesLength
    static let maxNameLength = ProposalFields.maxNameLength

    /// The MCP `tools/list` entry.
    static var definition: [String: Any] {
        [
            "name": name,
            "description": """
                Propose a Calendar event, a Reminder, or running one of the user's Shortcuts. \
                This does NOT create or run anything: Hushy shows the user a card and nothing \
                happens unless they confirm it there. Use it only when the user asks you to add, \
                schedule, remind or run something. Dates are ISO-8601 with a UTC offset, in the \
                user's local time zone (e.g. 2026-09-27T15:00:00-07:00).
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ProposedAction.Kind.allCases.filter { $0 != .openLink }.map(\.rawValue),
                             "description": "createEvent, createReminder or runShortcut"],
                    "title": ["type": "string", "description": "Event or reminder title (for runShortcut, a short label)"],
                    "start": ["type": "string", "description": "Event start or reminder due time, ISO-8601 with offset. Required for createEvent."],
                    "durationMinutes": ["type": "integer", "description": "Event length in minutes (default 30)"],
                    "notes": ["type": "string", "description": "Optional notes for the event or reminder"],
                    "location": ["type": "string", "description": "Optional event location"],
                    "calendarName": ["type": "string", "description": "Optional calendar name for an event"],
                    "listName": ["type": "string", "description": "Optional Reminders list name"],
                    "shortcutName": ["type": "string", "description": "The exact Shortcut name. Required for runShortcut."],
                    "shortcutInput": ["type": "string", "description": "Optional text input for the Shortcut"],
                ] as [String: Any],
                "required": ["kind", "title"],
            ] as [String: Any],
            // Nothing is changed by the call itself: it only validates and acknowledges.
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ]
    }

    /// Validates `arguments` (a tool call's JSON input) into an action. `sourceText` is what the
    /// action will be attributed to in History (the Assistant passes the user's question).
    public static func validate(
        _ arguments: [String: Any], sourceText: String = "", now: Date = Date()
    ) -> Result<ProposedAction, ValidationError> {
        do {
            return .success(try parse(arguments, sourceText: sourceText, now: now))
        } catch let error as ValidationError {
            return .failure(error)
        } catch {
            return .failure(ValidationError(message: "Invalid proposal."))
        }
    }

    /// The acknowledgement returned to the agent for a valid proposal.
    public static func acknowledgement(for action: ProposedAction) -> String {
        """
        Proposed (not created): \(summary(of: action)). This is awaiting the user's confirmation \
        in Hushy; nothing happens unless they confirm it there. Tell the user it's ready for them \
        to review, and don't claim it was added or run.
        """
    }

    /// "event “Dentist” at 2026-09-27T15:00:00-07:00 for 30 min".
    public static func summary(of action: ProposedAction) -> String {
        let when = action.start.map { " at \(isoFormatter().string(from: $0))" } ?? ""
        switch action.kind {
        case .createEvent:
            var length = ""
            if let start = action.start, let end = action.end {
                length = " for \(Int(end.timeIntervalSince(start) / 60)) min"
            }
            return "event “\(action.title)”\(when)\(length)"
        case .createReminder:
            return "reminder “\(action.title)”\(when)"
        case .runShortcut:
            return "run the Shortcut “\(action.shortcutName ?? action.title)”"
        case .openLink:
            return "open \(action.url ?? action.title)"
        }
    }

    // MARK: Parsing

    private static func parse(_ arguments: [String: Any], sourceText: String, now: Date) throws -> ProposedAction {
        guard let rawKind = arguments["kind"] as? String else {
            throw ValidationError(message: "Missing string argument: kind (createEvent, createReminder or runShortcut).")
        }
        guard let kind = ProposedAction.Kind(rawValue: rawKind) else {
            throw ValidationError(message: "Unknown kind “\(clip(rawKind, 40))”. Use createEvent, createReminder or runShortcut.")
        }
        let title = try requiredText(arguments, "title", limit: maxTitleLength)
        let notes = try optionalText(arguments, "notes", limit: maxNotesLength)
        let start = try date(arguments, "start", now: now)

        switch kind {
        case .createEvent:
            guard let start else {
                throw ValidationError(message: "createEvent needs start: an ISO-8601 date and time with offset.")
            }
            let minutes = try duration(arguments)
            return ProposedAction(
                kind: .createEvent, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                calendarName: try optionalText(arguments, "calendarName", limit: maxNameLength),
                location: try optionalText(arguments, "location", limit: maxNameLength),
                notes: notes, sourceText: sourceText)
        case .createReminder:
            return ProposedAction(
                kind: .createReminder, title: title, start: start,
                listName: try optionalText(arguments, "listName", limit: maxNameLength),
                notes: notes, sourceText: sourceText)
        case .runShortcut:
            let shortcut = try requiredText(arguments, "shortcutName", limit: maxNameLength)
            return ProposedAction(
                kind: .runShortcut, title: title, shortcutName: shortcut,
                shortcutInput: try optionalText(arguments, "shortcutInput", limit: maxNotesLength),
                sourceText: sourceText)
        case .openLink:
            // Links are built by Hushy's own code from spoken commands, never proposed by an
            // agent: an agent-supplied URL would be exactly the untrusted host this path forbids.
            throw ValidationError(message: "Unknown kind “openLink”. Use createEvent, createReminder or runShortcut.")
        }
    }

    private static func requiredText(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String {
        try ProposalFields.requiredFreeText(arguments, key, limit: limit)
    }

    private static func optionalText(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String? {
        try ProposalFields.optionalFreeText(arguments, key, limit: limit)
    }

    private static func date(_ arguments: [String: Any], _ key: String, now: Date) throws -> Date? {
        try ProposalFields.date(arguments, key, now: now)
    }

    private static func duration(_ arguments: [String: Any]) throws -> Int {
        try ProposalFields.durationMinutes(arguments)
    }

    /// Full date-time with an explicit offset or `Z`, with or without fractional seconds.
    static func parseISO8601(_ text: String) -> Date? {
        ProposalFields.parseISO8601(text)
    }

    public static func isoFormatter() -> ISO8601DateFormatter {
        ProposalFields.isoFormatter()
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        ProposalFields.clip(text, limit)
    }
}
