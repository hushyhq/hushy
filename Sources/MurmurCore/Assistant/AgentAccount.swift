import Foundation

/// Whether an agent CLI can answer right now: not on this Mac, installed but signed out, or
/// ready. `unknown` means the status check itself couldn't run (timed out, crashed); the chat
/// then finds out on the first request, from the CLI's own "not logged in" error.
public enum AgentAccountState: Equatable, Sendable {
    case notInstalled, signedOut, ready, unknown

    /// Signed in, or not known to be signed out.
    public var canChat: Bool { self == .ready || self == .unknown }
}

/// The fixed commands Hushy uses to check and start each agent's own sign-in. Hushy never
/// sees, asks for, stores or types a credential: sign-in happens in the vendor's own flow (the
/// browser, on the vendor's site), and every argument here is a constant — nothing the user
/// typed is ever part of these commands.
///
/// | Agent | Status (offline, non-interactive) | Sign in | Needs a terminal |
/// |---|---|---|---|
/// | Claude Code | `claude auth status --json` (`loggedIn`, exit 0/1) | `claude auth login` | yes: an Ink UI that may ask to paste a code |
/// | Codex | `codex login status` ("Logged in using …" / "Not logged in") | `codex login` | no: opens the browser, completes on its own localhost callback |
public enum AgentAuth {
    public static func statusArguments(for agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode: ["auth", "status", "--json"]
        case .codex: ["login", "status"]
        }
    }

    public static func loginArguments(for agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode: ["auth", "login"]
        case .codex: ["login"]
        }
    }

    /// Claude Code's login renders an interactive terminal UI (it can prompt "Paste code here"),
    /// so it runs in Terminal. Codex's prints a URL, opens the browser and waits for its
    /// localhost callback, so Hushy can run it directly.
    public static func loginNeedsTerminal(_ agent: AgentKind) -> Bool {
        agent == .claudeCode
    }

    /// The whole content of the `.command` file Terminal opens for a terminal sign-in: a login
    /// shell (so the user's own PATH finds the CLI) running one fixed command.
    public static func terminalScript(for agent: AgentKind) -> String {
        "#!/bin/zsh -l\n" + ([agent.command] + loginArguments(for: agent)).joined(separator: " ") + "\n"
    }

    /// The official install command, shown for copying. Hushy never runs it.
    public static func installCommand(for agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        }
    }

    public static func docsURL(for agent: AgentKind) -> URL {
        switch agent {
        case .claudeCode: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        }
    }

    /// Reads a status command's result. `output` is stdout (plus stderr when it failed).
    public static func parseStatus(for agent: AgentKind, output: String, exitCode: Int32) -> AgentAccountState {
        switch agent {
        case .claudeCode:
            if let data = jsonObject(in: output), let loggedIn = data["loggedIn"] as? Bool {
                return loggedIn ? .ready : .signedOut
            }
            if AgentChatError.looksLikeLoginProblem(output) { return .signedOut }
            return exitCode == 0 ? .ready : .signedOut
        case .codex:
            let lowered = output.lowercased()
            if lowered.contains("not logged in") { return .signedOut }
            if lowered.contains("logged in") { return .ready }
            return exitCode == 0 ? .ready : .signedOut
        }
    }

    private static func jsonObject(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Runs the status and sign-in commands as plain subprocesses (no shell), through the same
/// `AgentProcessRunner` as the chat.
public struct AgentAccountChecker: Sendable {
    public var locate: @Sendable (String) -> String?
    public var statusTimeout: Duration
    public var loginTimeout: Duration

    public init(
        locate: @escaping @Sendable (String) -> String? = { ExecutableLocator.locate($0) },
        statusTimeout: Duration = .seconds(10), loginTimeout: Duration = .seconds(600)
    ) {
        self.locate = locate
        self.statusTimeout = statusTimeout
        self.loginTimeout = loginTimeout
    }

    /// The invocation for `arguments` of `agent`'s CLI, or nil when it isn't installed.
    public func invocation(for agent: AgentKind, arguments: [String]) -> AgentInvocation? {
        guard let executable = locate(agent.command) else { return nil }
        var environment = ClaudeCodeCommand.cleanEnvironment
        let base = ProcessInfo.processInfo.environment
        environment["PATH"] = ExecutableLocator
            .searchDirectories(path: base["PATH"], home: FileManager.default.homeDirectoryForCurrentUser.path)
            .joined(separator: ":")
        return AgentInvocation(
            executable: executable, arguments: arguments, stdin: "",
            workingDirectory: FileManager.default.temporaryDirectory.path, environmentOverrides: environment)
    }

    public func state(for agent: AgentKind) async -> AgentAccountState {
        guard let invocation = invocation(for: agent, arguments: AgentAuth.statusArguments(for: agent)) else {
            return .notInstalled
        }
        let result = await run(invocation, timeout: statusTimeout)
        guard let exitCode = result.exitCode else { return .unknown }
        return AgentAuth.parseStatus(for: agent, output: result.output, exitCode: exitCode)
    }

    /// Runs the non-terminal sign-in (`codex login`) until it exits, is cancelled or times out.
    /// Returns the exit code, or nil if it didn't finish. The caller re-checks `state(for:)`.
    public func signIn(_ agent: AgentKind) async -> Int32? {
        guard !AgentAuth.loginNeedsTerminal(agent),
              let invocation = invocation(for: agent, arguments: AgentAuth.loginArguments(for: agent))
        else { return nil }
        return await run(invocation, timeout: loginTimeout).exitCode
    }

    private func run(_ invocation: AgentInvocation, timeout: Duration) async -> (exitCode: Int32?, output: String) {
        var lines: [String] = []
        do {
            for try await line in AgentProcessRunner(timeout: timeout, killGrace: .seconds(1)).lines(for: invocation) {
                lines.append(line)
            }
            return (Task.isCancelled ? nil : 0, lines.joined(separator: "\n"))
        } catch AgentChatError.exited(let code, let detail) {
            return (code, (lines + [detail]).joined(separator: "\n"))
        } catch AgentChatError.notLoggedIn {
            return (1, (lines + ["not logged in"]).joined(separator: "\n"))
        } catch {
            return (nil, lines.joined(separator: "\n"))
        }
    }
}
