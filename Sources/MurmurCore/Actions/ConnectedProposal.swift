import Foundation

/// What an agent proposed through one of the connected `propose_*` tools (see
/// `docs/product/ASSISTANT-ACTIONS.md` §3): an invite with attendees, an email draft, a chat
/// message or a tracker issue. Plain data, the same on both sides of the bridge: the MCP server
/// validates it and acknowledges, the Assistant validates it and (once the cards exist) shows
/// it for confirmation. Nothing in `MurmurCore` sends, posts or creates any of these; the
/// user's own agent does, and only after a confirmation card — which is not built yet.
public enum ConnectedProposal: Sendable, Equatable, Codable, Identifiable {
    case calendarInvite(CalendarInviteProposal)
    case emailDraft(EmailDraftProposal)
    case message(MessageProposal)
    case issue(IssueProposal)

    public var id: UUID {
        switch self {
        case .calendarInvite(let proposal): proposal.id
        case .emailDraft(let proposal): proposal.id
        case .message(let proposal): proposal.id
        case .issue(let proposal): proposal.id
        }
    }

    /// The bare MCP tool name this came from (`propose_email_draft`, …).
    public var toolName: String {
        switch self {
        case .calendarInvite: ProposeCalendarInviteTool.name
        case .emailDraft: ProposeEmailDraftTool.name
        case .message: ProposeMessageTool.name
        case .issue: ProposeIssueTool.name
        }
    }

    /// The utterance or question the proposal is attributed to. Empty when parsed from the
    /// agent's stream; the caller fills it in from the user's message.
    public var sourceText: String {
        get {
            switch self {
            case .calendarInvite(let proposal): proposal.sourceText
            case .emailDraft(let proposal): proposal.sourceText
            case .message(let proposal): proposal.sourceText
            case .issue(let proposal): proposal.sourceText
            }
        }
        set {
            switch self {
            case .calendarInvite(var proposal): proposal.sourceText = newValue; self = .calendarInvite(proposal)
            case .emailDraft(var proposal): proposal.sourceText = newValue; self = .emailDraft(proposal)
            case .message(var proposal): proposal.sourceText = newValue; self = .message(proposal)
            case .issue(var proposal): proposal.sourceText = newValue; self = .issue(proposal)
            }
        }
    }
}

/// One invitee: an email address, a name to resolve from the user's contacts, or both.
public struct ProposedAttendee: Sendable, Equatable, Hashable, Codable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }

    /// "Dana Lee <dana@example.com>", "dana@example.com" or "Dana Lee".
    public var display: String {
        switch (name, email) {
        case (let name?, let email?): "\(name) <\(email)>"
        case (nil, let email?): email
        case (let name?, nil): name
        case (nil, nil): ""
        }
    }
}

/// `propose_calendar_invite`: an event with attendees, sent through the user's own calendar
/// account by their agent (never by Hushy) after confirmation.
public struct CalendarInviteProposal: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [ProposedAttendee]
    public var notes: String?
    public var location: String?
    /// Which calendar or account to use ("Work", "ada@company.com"), if the agent knows.
    public var calendarHint: String?
    public var sourceText: String

    public init(
        id: UUID = UUID(), title: String, start: Date, end: Date, attendees: [ProposedAttendee],
        notes: String? = nil, location: String? = nil, calendarHint: String? = nil, sourceText: String
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.notes = notes
        self.location = location
        self.calendarHint = calendarHint
        self.sourceText = sourceText
    }

    public var durationMinutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

/// `propose_email_draft`: a draft the user opens in their mail client and sends themselves.
public struct EmailDraftProposal: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var body: String
    /// The Message-ID being replied to, when this is a reply.
    public var replyToMessageID: String?
    public var sourceText: String

    public init(
        id: UUID = UUID(), to: [String], cc: [String] = [], subject: String, body: String,
        replyToMessageID: String? = nil, sourceText: String
    ) {
        self.id = id
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.replyToMessageID = replyToMessageID
        self.sourceText = sourceText
    }
}

/// `propose_message`: a chat message pre-filled in the named app, which the user sends.
public struct MessageProposal: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// The app or channel kind: "slack", "imessage", "whatsapp", "teams", …
    public var channel: String
    /// A person, group or channel in that app ("#launch", "Dana Lee", "+1 415 …").
    public var recipient: String
    public var text: String
    public var sourceText: String

    public init(id: UUID = UUID(), channel: String, recipient: String, text: String, sourceText: String) {
        self.id = id
        self.channel = channel
        self.recipient = recipient
        self.text = text
        self.sourceText = sourceText
    }
}

/// `propose_issue`: a tracker issue the user's agent creates after confirmation.
public struct IssueProposal: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// "linear", "jira", "github", "notion", …
    public var tracker: String
    public var project: String
    public var title: String
    public var description: String?
    public var labels: [String]
    public var sourceText: String

    public init(
        id: UUID = UUID(), tracker: String, project: String, title: String, description: String? = nil,
        labels: [String] = [], sourceText: String
    ) {
        self.id = id
        self.tracker = tracker
        self.project = project
        self.title = title
        self.description = description
        self.labels = labels
        self.sourceText = sourceText
    }
}
