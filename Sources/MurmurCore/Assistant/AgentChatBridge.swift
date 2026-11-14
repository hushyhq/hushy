import Foundation

/// A per-conversation scratch area: an empty directory the agent runs in (Claude Code keys
/// `--resume` by working directory, so it must stay the same for the whole conversation, even
/// across launches) and, beside it rather than inside it, the `--mcp-config` file. Saved chats
/// use `forChat(id:)`, a stable folder under Hushy's data directory that is removed when the
/// chat is deleted; it never holds the conversation itself (that's in Hushy's database).
public struct AgentWorkspace: Sendable, Equatable {
    public let root: URL

    public var workingDirectory: URL { root.appendingPathComponent("workspace", isDirectory: true) }
    public var mcpConfigFile: URL { root.appendingPathComponent("hushy-mcp.json") }

    public init(root: URL) {
        self.root = root
    }

    /// A fresh workspace under the temporary directory.
    public static func makeTemporary(fileManager: FileManager = .default) throws -> AgentWorkspace {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("hushy-assistant-\(UUID().uuidString)", isDirectory: true)
        let workspace = AgentWorkspace(root: root)
        try fileManager.createDirectory(at: workspace.workingDirectory, withIntermediateDirectories: true)
        return workspace
    }

    /// The stable workspace for saved chat `id`: `<data>/Assistant/chat-<id>`.
    public static func forChat(id: Int64, base: URL = AppPaths.supportDirectory) -> AgentWorkspace {
        AgentWorkspace(root: base.appendingPathComponent("Assistant", isDirectory: true)
            .appendingPathComponent("chat-\(id)", isDirectory: true))
    }

    public func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }
}

/// Sends one message to the user's agent CLI with Hushy's MCP server attached, and streams the
/// reply as it forms. One call is one turn; pass the previous turn's `sessionID` to continue the
/// conversation. Every failure — CLI missing, not signed in, a crash, a timeout, a tool-policy
/// violation — arrives as a finished `AgentReply` with `error` set, never as a thrown error, so
/// the UI has exactly one thing to render.
public struct AgentChatBridge: Sendable {
    public var runner: AgentProcessRunner
    /// Resolves a bare command name to an executable path (`ExecutableLocator` by default).
    public var locate: @Sendable (String) -> String?
    /// The bundled read-only MCP server (`hushy-mcp`), or nil when it's missing.
    public var serverPath: String?
    /// Forwarded to the MCP server so it reads the same data directory as the app.
    public var murmurHome: String?

    public init(
        runner: AgentProcessRunner = AgentProcessRunner(),
        locate: @escaping @Sendable (String) -> String? = { ExecutableLocator.locate($0) },
        serverPath: String?,
        murmurHome: String? = ProcessInfo.processInfo.environment["MURMUR_HOME"]
    ) {
        self.runner = runner
        self.locate = locate
        self.serverPath = serverPath
        self.murmurHome = murmurHome
    }

    /// Builds the invocation for a turn, writing the MCP config into `workspace`.
    public func prepare(
        message: String, agent: AgentKind, turn: AgentTurnOptions, workspace: AgentWorkspace
    ) -> Result<AgentInvocation, AgentChatError> {
        guard agent.isSupported else { return .failure(.unsupported(agent)) }
        guard let executable = locate(agent.command) else { return .failure(.cliMissing(agent)) }
        guard let serverPath else { return .failure(.serverMissing) }
        do {
            try FileManager.default.createDirectory(at: workspace.workingDirectory, withIntermediateDirectories: true)
            let config = try ClaudeCodeCommand.mcpConfigJSON(serverPath: serverPath, murmurHome: murmurHome)
            try config.write(to: workspace.mcpConfigFile, options: .atomic)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        var invocation = ClaudeCodeCommand.invocation(
            executable: executable, message: message, turn: turn,
            workingDirectory: workspace.workingDirectory.path, mcpConfigPath: workspace.mcpConfigFile.path)
        // The child gets the same search path Hushy used to find it, so a Dock-launched app
        // (minimal PATH) still hands the CLI a usable one.
        let base = ProcessInfo.processInfo.environment
        invocation.environmentOverrides["PATH"] = ExecutableLocator
            .searchDirectories(path: base["PATH"], home: FileManager.default.homeDirectoryForCurrentUser.path)
            .joined(separator: ":")
        return .success(invocation)
    }

    /// Streams the reply for one message. Cancelling the consuming task stops the agent.
    public func send(
        message: String, agent: AgentKind, turn: AgentTurnOptions, workspace: AgentWorkspace
    ) -> AsyncStream<AgentReply> {
        let prepared = prepare(message: message, agent: agent, turn: turn, workspace: workspace)
        return stream(prepared, agent: agent, resumed: turn.resumeSessionID != nil)
    }

    /// `send` with default options, continuing `sessionID` if given.
    public func send(
        message: String, agent: AgentKind, sessionID: String?, workspace: AgentWorkspace
    ) -> AsyncStream<AgentReply> {
        send(message: message, agent: agent, turn: AgentTurnOptions(resumeSessionID: sessionID), workspace: workspace)
    }

    /// The streaming half of `send`, split out so tests can hand it any invocation.
    /// `resumed` marks a turn that passed `--resume`, so a "no such session" failure is reported
    /// as `.sessionNotFound` (the caller then starts afresh with the transcript as context).
    public func stream(
        _ prepared: Result<AgentInvocation, AgentChatError>, agent: AgentKind, resumed: Bool = false
    ) -> AsyncStream<AgentReply> {
        AsyncStream { continuation in
            var reply = AgentReply(agent: agent)
            let invocation: AgentInvocation
            switch prepared {
            case .failure(let error):
                reply.fail(error)
                continuation.yield(reply)
                continuation.finish()
                return
            case .success(let value):
                invocation = value
            }
            let lines = runner.lines(for: invocation)
            let task = Task {
                await Self.consume(lines, into: reply, agent: agent, resumed: resumed, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func consume(
        _ lines: AsyncThrowingStream<String, Error>, into initial: AgentReply, agent: AgentKind, resumed: Bool,
        continuation: AsyncStream<AgentReply>.Continuation
    ) async {
        var reply = initial
        do {
            lineLoop: for try await line in lines {
                for event in AgentStreamParser.events(fromLine: line) {
                    reply.apply(event)
                    // Offered at start-up, or called mid-turn: anything beyond Hushy's tools ends
                    // the run. Leaving the loop drops the line stream, which terminates the child.
                    let violations: [String] = switch event {
                    case .started: AgentToolPolicy.violations(in: reply.offeredTools)
                    case .assistantMessage(_, let toolUses): AgentToolPolicy.violations(in: toolUses)
                    default: []
                    }
                    if !violations.isEmpty {
                        reply.fail(.toolPolicyViolation(violations))
                        break lineLoop
                    }
                    continuation.yield(reply)
                }
            }
        } catch let error as AgentChatError {
            if !reply.isFinished { reply.fail(error) }
        } catch {
            if !reply.isFinished { reply.fail(.agentError(error.localizedDescription)) }
        }
        if Task.isCancelled, !reply.isFinished {
            reply.fail(.agentError("Stopped."))
        }
        if resumed, let error = reply.error, error.meansSessionMissing {
            reply.replaceError(with: .sessionNotFound)
        }
        if !reply.isFinished {
            if reply.text.isEmpty {
                reply.fail(.agentError("The agent ended without answering."))
            } else {
                reply.apply(.finished(AgentResult(isError: false, subtype: "success", text: reply.text, sessionID: reply.sessionID)))
            }
        }
        continuation.yield(reply)
        continuation.finish()
    }
}
