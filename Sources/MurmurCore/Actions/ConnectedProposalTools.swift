import Foundation

/// The catalog of connected `propose_*` tools (everything except `propose_action`, which is
/// on-device and already has a card): one validation entry point by tool name.
///
/// The MCP server does not serve these tools: no confirmation card exists for them, so a client
/// that called one would be told something was waiting in Hushy when nothing was. Only the
/// voice path's tool catalog and `AgentStreamParser` still use the names and validation.
public enum ConnectedProposalTools {
    /// Bare tool names, in the order they're listed.
    public static let names: [String] = [
        ProposeCalendarInviteTool.name, ProposeEmailDraftTool.name, ProposeMessageTool.name, ProposeIssueTool.name,
    ]

    /// Validates a call to `tool` (a bare name); nil when the name isn't one of these tools.
    public static func validate(
        tool: String, arguments: [String: Any], sourceText: String = "", now: Date = Date()
    ) -> Result<ConnectedProposal, ProposalValidationError>? {
        switch tool {
        case ProposeCalendarInviteTool.name:
            ProposeCalendarInviteTool.validate(arguments, sourceText: sourceText, now: now).map(ConnectedProposal.calendarInvite)
        case ProposeEmailDraftTool.name:
            ProposeEmailDraftTool.validate(arguments, sourceText: sourceText, now: now).map(ConnectedProposal.emailDraft)
        case ProposeMessageTool.name:
            ProposeMessageTool.validate(arguments, sourceText: sourceText, now: now).map(ConnectedProposal.message)
        case ProposeIssueTool.name:
            ProposeIssueTool.validate(arguments, sourceText: sourceText, now: now).map(ConnectedProposal.issue)
        default:
            nil
        }
    }

    public static func summary(of proposal: ConnectedProposal) -> String {
        switch proposal {
        case .calendarInvite(let invite): ProposeCalendarInviteTool.summary(of: invite)
        case .emailDraft(let draft): ProposeEmailDraftTool.summary(of: draft)
        case .message(let message): ProposeMessageTool.summary(of: message)
        case .issue(let issue): ProposeIssueTool.summary(of: issue)
        }
    }
}
