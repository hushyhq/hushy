import Foundation

/// One meaningful thing a Claude Code `--output-format stream-json` line says.
public enum AgentStreamEvent: Equatable, Sendable {
    /// The `system/init` line: the session id, every tool the session was given, and each MCP
    /// server's connection status (`"connected"`, `"failed"`, …) by name.
    case started(sessionID: String?, tools: [String], mcpServers: [String: String])
    /// A token-level text chunk (`stream_event` → `content_block_delta` → `text_delta`).
    case textDelta(String)
    /// A complete assistant message: its text blocks joined, and the tools it called.
    case assistantMessage(text: String, toolUses: [String])
    /// A tool result came back (the agent is about to continue).
    case toolResult(isError: Bool)
    /// The agent called `propose_action` with input that passes `ProposeActionTool` validation.
    /// Invalid proposals yield nothing here: the MCP server returns the error to the agent.
    case actionProposed(ProposedAction)
    /// The agent called one of the connected `propose_*` tools (`propose_calendar_invite`,
    /// `propose_email_draft`, `propose_message`, `propose_issue`) with input that passes that
    /// tool's validation. Carried as data only: there is no card for these yet.
    case connectedProposed(ConnectedProposal)
    /// A `rate_limit_event`: the CLI's usage-limit status (`"allowed"`, `"allowed_warning"`,
    /// `"rejected"`) and when the window resets. Informational unless rejected.
    case rateLimit(status: String, resetsAt: Date?)
    /// The final `result` line.
    case finished(AgentResult)
}

public struct AgentResult: Equatable, Sendable {
    public var isError: Bool
    public var subtype: String
    public var text: String
    public var sessionID: String?
    /// Tools the agent tried to call that the CLI refused (`permission_denials`), by name. With
    /// Hushy's flags nothing outside its MCP tools is even offered, so any entry here is an
    /// attempt to step outside the policy and is reported as such.
    public var permissionDenials: [String]

    public init(isError: Bool, subtype: String, text: String, sessionID: String?, permissionDenials: [String] = []) {
        self.isError = isError
        self.subtype = subtype
        self.text = text
        self.sessionID = sessionID
        self.permissionDenials = permissionDenials
    }
}

/// Parses Claude Code's newline-delimited stream-json output. Pure and forgiving: a line that
/// isn't JSON, or is a kind of event the assistant doesn't use (hooks, rate-limit notices,
/// sub-agent chatter), yields no events rather than an error, so a newer CLI adding event types
/// can't break the chat.
public enum AgentStreamParser {
    /// Parses one stream-json line.
    /// - Parameter now: the instant proposals are validated against (`ProposeActionTool` and the
    ///   connected `propose_*` tools reject a date outside their window around it). Defaults to
    ///   the wall clock; replaying a recorded turn passes its capture time instead, so a real
    ///   fixture doesn't age out of the window as the days pass.
    public static func events(fromLine line: String, now: Date = Date()) -> [AgentStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }
        // Output from a sub-agent (never enabled here, but be safe) isn't the reply.
        if let parent = object["parent_tool_use_id"] as? String, !parent.isEmpty { return [] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { return [] }
            return [started(from: object)]
        case "stream_event":
            return textDelta(from: object).map { [.textDelta($0)] } ?? []
        case "assistant":
            return (assistantMessage(from: object).map { [$0] } ?? []) + proposedActions(from: object, now: now)
                + connectedProposals(from: object, now: now)
        case "user":
            return toolResults(from: object)
        case "rate_limit_event":
            return rateLimit(from: object).map { [$0] } ?? []
        case "result":
            return [.finished(result(from: object))]
        default:
            return []
        }
    }

    /// `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1790535600,…}}`.
    private static func rateLimit(from object: [String: Any]) -> AgentStreamEvent? {
        guard let info = object["rate_limit_info"] as? [String: Any], let status = info["status"] as? String else { return nil }
        let resetsAt = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return .rateLimit(status: status, resetsAt: resetsAt)
    }

    private static func started(from object: [String: Any]) -> AgentStreamEvent {
        let tools = (object["tools"] as? [Any] ?? []).compactMap { $0 as? String }
        var servers: [String: String] = [:]
        for case let server as [String: Any] in object["mcp_servers"] as? [Any] ?? [] {
            if let name = server["name"] as? String {
                servers[name] = server["status"] as? String ?? "unknown"
            }
        }
        return .started(sessionID: object["session_id"] as? String, tools: tools, mcpServers: servers)
    }

    private static func textDelta(from object: [String: Any]) -> String? {
        guard let event = object["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    private static func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return (message["content"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func assistantMessage(from object: [String: Any]) -> AgentStreamEvent? {
        let blocks = contentBlocks(of: object)
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let tools = blocks
            .filter { $0["type"] as? String == "tool_use" }
            .compactMap { $0["name"] as? String }
        guard !text.isEmpty || !tools.isEmpty else { return nil }
        return .assistantMessage(text: text, toolUses: tools)
    }

    /// `tool_use` blocks calling Hushy's `propose_action`, validated into actions against `now`.
    private static func proposedActions(from object: [String: Any], now: Date) -> [AgentStreamEvent] {
        contentBlocks(of: object)
            .filter { $0["type"] as? String == "tool_use" && $0["name"] as? String == ClaudeCodeCommand.proposeActionTool }
            .compactMap { block in
                guard let input = block["input"] as? [String: Any],
                      case .success(let action) = ProposeActionTool.validate(input, now: now)
                else { return nil }
                return .actionProposed(action)
            }
    }

    /// `tool_use` blocks calling one of Hushy's connected `propose_*` tools, validated into
    /// `ConnectedProposal`s through the same `ConnectedProposalTools.validate` the MCP server
    /// uses, against `now`.
    private static func connectedProposals(from object: [String: Any], now: Date) -> [AgentStreamEvent] {
        contentBlocks(of: object)
            .filter { $0["type"] as? String == "tool_use" }
            .compactMap { block in
                guard let name = block["name"] as? String,
                      let tool = ClaudeCodeCommand.connectedProposalTool(named: name),
                      let input = block["input"] as? [String: Any],
                      case .success(let proposal) = ConnectedProposalTools.validate(tool: tool, arguments: input, now: now)
                else { return nil }
                return .connectedProposed(proposal)
            }
    }

    private static func toolResults(from object: [String: Any]) -> [AgentStreamEvent] {
        contentBlocks(of: object)
            .filter { $0["type"] as? String == "tool_result" }
            .map { .toolResult(isError: $0["is_error"] as? Bool ?? false) }
    }

    private static func result(from object: [String: Any]) -> AgentResult {
        let subtype = object["subtype"] as? String ?? "unknown"
        let isError = (object["is_error"] as? Bool ?? false) || subtype != "success"
        let text = object["result"] as? String
            ?? (object["errors"] as? [Any])?.compactMap { $0 as? String }.joined(separator: "\n")
            ?? ""
        // `permission_denials` is a list of `{tool_name, tool_input, tool_use_id}` (seen live; empty
        // in every captured turn). Bare strings are accepted too, in case the shape changes.
        let denials = (object["permission_denials"] as? [Any] ?? []).compactMap { entry -> String? in
            if let name = entry as? String { return name }
            return (entry as? [String: Any])?["tool_name"] as? String
        }
        return AgentResult(
            isError: isError, subtype: subtype, text: text, sessionID: object["session_id"] as? String,
            permissionDenials: denials)
    }
}
