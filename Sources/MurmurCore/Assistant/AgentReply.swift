import Foundation

/// Why an assistant turn didn't produce an answer, worded for the chat bubble.
public enum AgentChatError: Error, Equatable, Sendable {
    case cliMissing(AgentKind)
    case unsupported(AgentKind)
    case serverMissing
    case notLoggedIn(AgentKind)
    case launchFailed(String)
    case exited(code: Int32, detail: String)
    case timedOut(seconds: Int)
    case outputTooLarge
    case toolPolicyViolation([String])
    /// `--resume` named a session the CLI no longer has (cleared, or created on another Mac).
    case sessionNotFound
    /// The CLI reported the user's Claude usage limit as reached (`rate_limit_event` rejected).
    case rateLimited(resetsAt: Date?)
    case agentError(String)

    public var userMessage: String {
        switch self {
        case .cliMissing(let agent):
            "\(agent.title) isn't installed on this Mac, or Hushy can't find it. Install it, then try again."
        case .unsupported(let agent):
            "Chatting through \(agent.title) is coming soon."
        case .serverMissing:
            "Hushy's data helper is missing from the app. Reinstall Hushy, then try again."
        case .notLoggedIn(let agent):
            "\(agent.title) isn't signed in. Open Terminal, run `\(agent.command)`, sign in, then ask again."
        case .launchFailed(let detail):
            "Couldn't start the agent: \(detail)"
        case .exited(let code, let detail):
            detail.isEmpty
                ? "The agent stopped unexpectedly (exit code \(code))."
                : "The agent stopped unexpectedly (exit code \(code)): \(detail)"
        case .outputTooLarge:
            "The agent response exceeded Hushy’s size limit."
        case .timedOut(let seconds):
            "No answer after \(seconds) seconds, so Hushy stopped the request. Try a narrower question."
        case .toolPolicyViolation(let tools):
            "Hushy stopped this request because the agent was offered tools beyond Hushy's read-only ones (\(tools.joined(separator: ", "))). Nothing ran."
        case .sessionNotFound:
            "The earlier \(AgentKind.claudeCode.title) session for this chat is gone."
        case .rateLimited(let resetsAt):
            if let resetsAt {
                "Your Claude usage limit is reached. It resets \(resetsAt.formatted(.relative(presentation: .named)))."
            } else {
                "Your Claude usage limit is reached. Try again later."
            }
        case .agentError(let detail):
            detail.isEmpty ? "The agent couldn't answer this time." : detail
        }
    }

    /// Whether this failure is the CLI saying the `--resume` session doesn't exist.
    public var meansSessionMissing: Bool {
        switch self {
        case .sessionNotFound: true
        case .exited(_, let detail), .agentError(let detail): Self.looksLikeMissingSession(detail)
        default: false
        }
    }

    /// Claude Code's wording when `--resume` names an unknown session.
    public static func looksLikeMissingSession(_ text: String) -> Bool {
        text.lowercased().contains("no conversation found")
    }

    /// Recognises the CLI's "please log in" wording in an error result or stderr.
    public static func looksLikeLoginProblem(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["not logged in", "/login", "invalid api key", "please log in", "authentication_error", "oauth token has expired"]
            .contains { lowered.contains($0) }
    }
}

/// Folds a turn's stream events into what the chat bubble shows: the answer so far, what the
/// agent is doing right now ("Searching your history…"), and how it ended.
///
/// Text arrives twice with `--include-partial-messages` — first as deltas, then as the complete
/// message — so a complete message *replaces* the deltas streamed since the last one instead of
/// being appended after them. Separate assistant messages (before and after a tool call) are
/// joined with a blank line.
public struct AgentReply: Equatable, Sendable {
    public private(set) var sessionID: String?
    /// Text from completed assistant messages.
    private var committed = ""
    /// Deltas received since the last completed message.
    private var streaming = ""
    /// A present-tense label while a tool call is in flight; nil while the agent is writing.
    public private(set) var activity: String?
    /// Every tool the agent called this turn, in order (fully qualified names).
    public private(set) var toolsUsed: [String] = []
    /// Actions the agent proposed through `propose_action` this turn, validated, in order.
    /// `sourceText` is empty; the caller attributes them to the user's question.
    public private(set) var proposedActions: [ProposedAction] = []
    /// Connected proposals (invites, email drafts, messages, issues) the agent made through the
    /// `propose_*` tools this turn, validated, in order. Data only for now: the chat shows a
    /// card for `proposedActions` but not yet for these.
    /// TODO(ASSISTANT-ACTIONS.md §4, after Checkpoint B): render a confirmation card per
    /// `ConnectedProposal` and hand the confirmed proposal back to the user's agent.
    public private(set) var connectedProposals: [ConnectedProposal] = []
    /// Tools offered at start-up (from the init line), for the policy check.
    public private(set) var offeredTools: [String] = []
    /// Set when Hushy's MCP server didn't connect, so the answer isn't grounded in the user's data.
    public private(set) var dataUnavailable = false
    /// The last `rate_limit_event` this turn: `"allowed"`, `"allowed_warning"` (the user is near
    /// their Claude usage limit) or `"rejected"`, with the window's reset time when given.
    public private(set) var rateLimitStatus: String?
    public private(set) var rateLimitResetsAt: Date?
    public private(set) var isFinished = false
    public private(set) var error: AgentChatError?
    let agent: AgentKind

    public init(agent: AgentKind = .claudeCode) {
        self.agent = agent
    }

    /// The answer as it should be shown right now.
    public var text: String {
        [committed, streaming].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public mutating func apply(_ event: AgentStreamEvent) {
        switch event {
        case .started(let sessionID, let tools, let servers):
            self.sessionID = sessionID ?? self.sessionID
            offeredTools = tools
            let status = servers[ClaudeCodeCommand.serverName]
            dataUnavailable = status != nil && status != "connected"
        case .textDelta(let delta):
            activity = nil
            streaming += delta
        case .assistantMessage(let text, let toolUses):
            let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                committed = [committed, finalText].filter { !$0.isEmpty }.joined(separator: "\n\n")
            } else if !streaming.isEmpty {
                committed = [committed, streaming].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            streaming = ""
            toolsUsed += toolUses
            activity = toolUses.last.map(Self.activityLabel(forTool:))
        case .toolResult:
            activity = "Reading what it found…"
        case .actionProposed(let action):
            proposedActions.append(action)
        case .connectedProposed(let proposal):
            connectedProposals.append(proposal)
        case .rateLimit(let status, let resetsAt):
            rateLimitStatus = status
            rateLimitResetsAt = resetsAt ?? rateLimitResetsAt
        case .finished(let result):
            finish(with: result)
        }
    }

    /// Swaps a recorded failure for a more specific one (e.g. a missing `--resume` session).
    public mutating func replaceError(with error: AgentChatError) {
        guard self.error != nil else { return }
        self.error = error
    }

    /// Records a failure that happened outside the stream (launch, exit code, timeout).
    public mutating func fail(_ error: AgentChatError) {
        guard self.error == nil else { return }
        self.error = error
        activity = nil
        isFinished = true
    }

    private mutating func finish(with result: AgentResult) {
        sessionID = result.sessionID ?? sessionID
        activity = nil
        isFinished = true
        if !streaming.isEmpty {
            committed = [committed, streaming].filter { !$0.isEmpty }.joined(separator: "\n\n")
            streaming = ""
        }
        if !result.permissionDenials.isEmpty {
            // The CLI refused a call: nothing ran, but the agent tried to step outside the policy.
            error = .toolPolicyViolation(result.permissionDenials)
        } else if result.isError {
            let detail = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if rateLimitStatus == "rejected" {
                error = .rateLimited(resetsAt: rateLimitResetsAt)
            } else if AgentChatError.looksLikeLoginProblem(detail) || AgentChatError.looksLikeLoginProblem(committed) {
                error = .notLoggedIn(agent)
            } else {
                error = .agentError(detail)
            }
        } else if committed.isEmpty {
            committed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// What a finished turn looked up, for the saved chat: "Searched your notes · Read a note".
    public static func toolSummary(_ tools: [String]) -> String? {
        var seen = Set<String>()
        let labels = tools.compactMap { name -> String? in
            let label: String
            switch name.components(separatedBy: "__").last ?? name {
            case "search_notes": label = "Searched your notes"
            case "list_notes": label = "Listed your notes"
            case "get_note": label = "Read a note"
            case "get_insights": label = "Checked your stats"
            case ProposeActionTool.name: label = "Proposed an action"
            case ProposeCalendarInviteTool.name: label = "Proposed an invite"
            case ProposeEmailDraftTool.name: label = "Drafted an email"
            case ProposeMessageTool.name: label = "Drafted a message"
            case ProposeIssueTool.name: label = "Proposed an issue"
            default: return nil
            }
            return seen.insert(label).inserted ? label : nil
        }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }

    /// "mcp__hushy__search_notes" → "Searching your notes…".
    public static func activityLabel(forTool name: String) -> String {
        let bare = name.components(separatedBy: "__").last ?? name
        switch bare {
        case "search_notes": return "Searching your notes…"
        case "list_notes": return "Looking through your notes…"
        case "get_note": return "Reading a note…"
        case "get_insights": return "Checking your stats…"
        case ProposeActionTool.name, ProposeCalendarInviteTool.name, ProposeEmailDraftTool.name,
             ProposeMessageTool.name, ProposeIssueTool.name:
            return "Preparing something for you to confirm…"
        default: return "Working…"
        }
    }
}

/// Which tools a session may be offered: exactly Hushy's own MCP tools by name (the notes
/// lookups, `propose_action` and the connected `propose_*` tools, all of which only propose).
/// Anything else — a shell, file access, web access,
/// another MCP server, even an unknown tool on Hushy's own server — is a violation, and the run
/// is stopped before the agent can use it. The two MCP resource helpers are allowed: with
/// `--strict-mcp-config` they can only reach Hushy's server, which exposes no resources.
public enum AgentToolPolicy {
    public static let harmlessMetaTools: Set<String> = ["ListMcpResourcesTool", "ReadMcpResourceTool"]

    public static func violations(in offered: [String], allowed: [String] = ClaudeCodeCommand.allowedTools) -> [String] {
        let permitted = Set(allowed).union(harmlessMetaTools)
        return offered.filter { !permitted.contains($0) }
    }
}
