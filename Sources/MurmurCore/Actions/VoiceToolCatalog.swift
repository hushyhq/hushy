import Foundation

/// Tool schema v1: the closed catalogue of tools the on-device model may call for one spoken
/// command (`docs/product/LOCAL-MODEL-RESEARCH.md` §3.2, "one source of truth"). The MLX tool
/// router, the Apple FM path and `murmur-eval tools` all read it from here, so a tool the model
/// names always exists and the eval scores exactly what the runtime would accept.
///
/// Shape rules, shared with the existing validators:
/// - Local tools (`create_reminder`, `create_event`, `add_to_list`, `save_note`, `open_app`,
///   `run_shortcut`, `set_timer`) mirror `ProposedAction` / `ProposeActionTool` fields.
/// - Connected tools reuse the MCP names of `ConnectedProposalTools` (`propose_*`) and their
///   field meanings; the user's own agent executes them after the card (ASSISTANT-ACTIONS.md).
/// - `no_action` is the explicit "leave it as dictation" (or refuse) branch, with a reason.
/// - Dates are the spoken phrase ("tomorrow at 9"): the model copies, `DateAnchor` computes.
/// - Single step: one tool per utterance. Multi-intent answers `no_action` / `multi_intent`.
public enum VoiceToolCatalog {
    public static let version = "tools-v1"

    public static let noActionName = "no_action"

    /// Reasons `no_action` may carry. `not_a_command` is ordinary dictation or a mention; the
    /// others are refusals the app can explain on the pill.
    public enum NoActionReason: String, Sendable, CaseIterable, Codable {
        case notACommand = "not_a_command"
        case needsClarification = "needs_clarification"
        case multiIntent = "multi_intent"
        case sensitiveContent = "sensitive_content"
        case unsupported
    }

    public static let tools: [VoiceTool] = [
        VoiceTool(
            name: "create_reminder", risk: .local,
            description: "Create a reminder in Apple Reminders for the speaker (\"remind me to…\", \"don't let me forget…\").",
            parameters: [
                .init("title", .text, required: true, "What to be reminded about, in the speaker's words, without the date phrase"),
                .init("when", .dateTime, "Date/time phrase exactly as spoken, if any"),
                .init("list", .name, "Reminders list name if spoken"),
            ]),
        VoiceTool(
            name: "create_event", risk: .local,
            description: "Add an event to the speaker's own Mac calendar. Attendees are only noted on the event; to send invitations use propose_calendar_invite.",
            parameters: [
                .init("title", .text, required: true, "Short event title in the speaker's words, without the date phrase"),
                .init("when", .dateTime, required: true, "Start date/time phrase exactly as spoken"),
                .init("duration_minutes", .durationMinutes, "Length in minutes if stated"),
                .init("location", .name, "Place if stated"),
                .init("calendar", .name, "Calendar name if stated"),
                .init("attendees", .nameList, "People named as joining, as spoken"),
            ]),
        VoiceTool(
            name: "add_to_list", risk: .local,
            description: "Add one or more items to a named Reminders list (\"add eggs milk and bread to groceries\").",
            parameters: [
                .init("items", .textList, required: true, "Each item separately, as spoken"),
                .init("list", .name, required: true, "The list name as spoken"),
            ]),
        VoiceTool(
            name: "save_note", risk: .local,
            description: "Save a new Hushy note with the dictated text.",
            parameters: [
                .init("text", .text, required: true, "The note body, as spoken"),
                .init("title", .text, "A title if the speaker gave one"),
            ]),
        VoiceTool(
            name: "open_app", risk: .local,
            description: "Open an app, website or service link after confirmation.",
            parameters: [
                .init("target", .name, required: true, "App, website or service as spoken"),
                .init("service", .enumeration(DeepLinkBuilder.Service.allCases.map(\.rawValue)), "Named service"),
                .init("action", .enumeration(DeepLinkBuilder.Action.allCases.map(\.rawValue)), "Link action"),
                .init("query", .text, "Search text or owner/repo"),
                .init("date", .dateTime, "Day phrase as spoken"),
                .init("destination", .name, "Directions destination"),
                .init("browser", .enumeration(["default", "safari", "chrome", "arc", "firefox", "edge", "brave"]), "Preferred browser"),
            ]),
        VoiceTool(
            name: "run_shortcut", risk: .automation,
            description: "Run one of the speaker's existing Apple Shortcuts by name.",
            parameters: [
                .init("name", .name, required: true, "The Shortcut name as spoken"),
                .init("input", .text, "Text to pass to the Shortcut, if spoken"),
            ]),
        VoiceTool(
            name: "set_timer", risk: .local,
            description: "Start a countdown timer on the Mac.",
            parameters: [
                .init("duration", .duration, required: true, "The length as spoken, e.g. \"20 minutes\""),
                .init("label", .text, "What the timer is for, if spoken"),
            ]),
        VoiceTool(
            name: ProposeEmailDraftTool.name, risk: .connectedDraft,
            description: "Propose an email draft the speaker reviews and sends themselves. Never sends.",
            parameters: [
                .init("to", .nameList, required: true, "Recipients as spoken (names or addresses); the card resolves contacts"),
                .init("subject", .text, "Subject if spoken or obvious"),
                .init("body", .text, required: true, "What the email should say, in the speaker's words"),
            ]),
        VoiceTool(
            name: ProposeMessageTool.name, risk: .connectedDraft,
            description: "Propose a chat message pre-filled in Slack, Messages, WhatsApp or Teams for the speaker to send. Never posts.",
            parameters: [
                .init("channel", .enumeration(["slack", "imessage", "whatsapp", "teams", "discord"]), required: true, "Which app; the frontmost app decides when the speaker doesn't say"),
                .init("recipient", .name, required: true, "Person, group or #channel as spoken"),
                .init("text", .text, required: true, "The message, in the speaker's words"),
            ]),
        VoiceTool(
            name: ProposeIssueTool.name, risk: .connectedDraft,
            description: "Propose a new issue or ticket in the speaker's tracker; their agent creates it after the card.",
            parameters: [
                .init("tracker", .enumeration(["linear", "jira", "github", "notion", "asana"]), required: true, "The tracker named, or the frontmost one"),
                .init("project", .name, "Project, team, board or repository if spoken"),
                .init("title", .text, required: true, "Issue title in the speaker's words"),
                .init("description", .text, "Extra detail if spoken"),
            ]),
        VoiceTool(
            name: ProposeCalendarInviteTool.name, risk: .connectedDraft,
            description: "Propose a meeting invitation sent to other people from the speaker's calendar account, after the card.",
            parameters: [
                .init("title", .text, required: true, "Meeting title in the speaker's words"),
                .init("when", .dateTime, required: true, "Start date/time phrase exactly as spoken"),
                .init("duration_minutes", .durationMinutes, "Length in minutes if stated"),
                .init("attendees", .nameList, required: true, "Invitees as spoken (names or addresses)"),
                .init("location", .name, "Place or meeting link if stated"),
                .init("notes", .text, "Agenda or body if spoken"),
            ]),
        VoiceTool(
            name: noActionName, risk: .none,
            description: "Do nothing: the utterance is dictation, a mention, chit-chat, or a request to refuse (sensitive, unsupported, ambiguous or more than one action).",
            parameters: [
                .init("reason", .enumeration(NoActionReason.allCases.map(\.rawValue)), required: true, "Why no tool runs"),
            ]),
    ]

    public static var names: [String] { tools.map(\.name) }

    public static func tool(named name: String) -> VoiceTool? {
        tools.first { $0.name == name }
    }

    /// Every distinct parameter across the catalogue, first occurrence wins (a name means the
    /// same kind everywhere — pinned by `VoiceToolCatalogTests`). The flat envelope is built from it.
    public static var allParameters: [VoiceToolParameter] {
        var seen = Set<String>()
        return tools.flatMap(\.parameters).filter { seen.insert($0.name).inserted }
    }
}

/// One callable tool.
public struct VoiceTool: Sendable, Equatable {
    /// What confirming it means (the card and executor differ; every tool still needs a card).
    public enum Risk: String, Sendable, Codable {
        case none
        case local
        case automation
        case connectedDraft = "connected_draft"
    }

    public let name: String
    public let risk: Risk
    public let description: String
    public let parameters: [VoiceToolParameter]

    public init(name: String, risk: Risk, description: String, parameters: [VoiceToolParameter]) {
        self.name = name
        self.risk = risk
        self.description = description
        self.parameters = parameters
    }

    public var requiredParameters: [VoiceToolParameter] { parameters.filter(\.isRequired) }

    public func parameter(named name: String) -> VoiceToolParameter? {
        parameters.first { $0.name == name }
    }
}

/// One argument. `kind` decides both the JSON type and how the eval compares it.
public struct VoiceToolParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Free text copied from speech: titles, bodies, message text.
        case text
        /// A proper name or label: list, calendar, app, shortcut, person, place, project.
        case name
        /// A date/time phrase as spoken (or ISO-8601 with offset).
        case dateTime
        /// Whole minutes.
        case durationMinutes
        /// A countdown length as spoken ("20 minutes") or seconds.
        case duration
        /// People: names or email addresses.
        case nameList
        /// Separate items (a shopping list).
        case textList
        /// One of a fixed set of lowercase values.
        case enumeration([String])

        /// The tag written into the catalogue JSON (`x-match`).
        public var tag: String {
            switch self {
            case .text: "text"
            case .name: "name"
            case .dateTime: "datetime"
            case .durationMinutes: "duration_minutes"
            case .duration: "duration"
            case .nameList: "name_list"
            case .textList: "text_list"
            case .enumeration: "enum"
            }
        }

        var isList: Bool { self == .nameList || self == .textList }
    }

    public let name: String
    public let kind: Kind
    public let isRequired: Bool
    public let description: String

    public init(_ name: String, _ kind: Kind, required: Bool = false, _ description: String) {
        self.name = name
        self.kind = kind
        self.isRequired = required
        self.description = description
    }
}
