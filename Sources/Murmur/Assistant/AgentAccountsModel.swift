import AppKit
import Foundation
import MurmurCore
import Observation
import os

/// Each agent CLI's sign-in state (not installed / signed out / ready) and the "Sign in" flow,
/// shared by the Assistant column and Settings → AI connections. Hushy only launches the
/// vendor's own login (`AgentAuth`); it never sees or handles a credential.
@MainActor
@Observable
final class AgentAccountsModel {
    enum SignIn: Equatable {
        /// `codex login` is running; the browser finishes it.
        case inBrowser(AgentKind)
        /// Terminal was opened with `claude auth login`; the user clicks Check again after.
        case inTerminal(AgentKind)
        case failed(AgentKind, String)
    }

    private(set) var states: [AgentKind: AgentAccountState] = [:]
    private(set) var signIn: SignIn?
    private(set) var isChecking = false

    @ObservationIgnored private let checker: AgentAccountChecker
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "assistant")

    init(checker: AgentAccountChecker = AgentAccountChecker()) {
        self.checker = checker
    }

    func state(of agent: AgentKind) -> AgentAccountState { states[agent] ?? .notInstalled }

    /// Agents found on this Mac, in `AgentKind` order.
    var installedAgents: [AgentKind] { AgentKind.allCases.filter { state(of: $0) != .notInstalled } }

    /// Re-runs every agent's status check (a few hundred ms each, offline).
    func refresh() async {
        guard !pinned, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        for agent in AgentKind.allCases {
            states[agent] = await checker.state(for: agent)
        }
        if case .inTerminal(let agent) = signIn, state(of: agent) == .ready { signIn = nil }
    }

    /// Called when a chat request fails because the CLI says it isn't signed in.
    func markSignedOut(_ agent: AgentKind) {
        guard !pinned else { return }
        states[agent] = .signedOut
    }

    /// Starts `agent`'s own sign-in: in Terminal (Claude Code) or in the browser via the CLI's
    /// localhost callback (Codex). Never passes anything the user typed.
    func startSignIn(_ agent: AgentKind) {
        cancelSignIn()
        if AgentAuth.loginNeedsTerminal(agent) {
            openTerminalSignIn(agent)
            return
        }
        signIn = .inBrowser(agent)
        let checker = self.checker
        signInTask = Task { [weak self] in
            let exitCode = await checker.signIn(agent)
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
            if self.state(of: agent) == .ready {
                self.signIn = nil
            } else {
                self.signIn = .failed(agent, exitCode == nil
                    ? "Sign-in didn't finish. Try again, or sign in from Terminal."
                    : "Sign-in didn't complete (exit code \(exitCode ?? 0)).")
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = nil
    }

    /// Opens Terminal with a temporary `.command` file whose whole content is the fixed login
    /// command (`AgentAuth.terminalScript`). No AppleScript, so no Automation permission.
    func openTerminalSignIn(_ agent: AgentKind) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hushy-signin-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Sign in to \(agent.title).command")
            try AgentAuth.terminalScript(for: agent).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            signIn = .inTerminal(agent)
        } catch {
            log.error("couldn't open Terminal sign-in: \(error.localizedDescription)")
            signIn = .failed(agent, "Couldn't open Terminal. Run `\(agent.command) \(AgentAuth.loginArguments(for: agent).joined(separator: " "))` yourself.")
        }
    }

    /// Copies the official install command (Hushy never runs it).
    func copyInstallCommand(_ agent: AgentKind) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentAuth.installCommand(for: agent), forType: .string)
    }

    // MARK: Snapshots

    func pin(_ states: [AgentKind: AgentAccountState], signIn: SignIn? = nil) {
        pinned = true
        self.states = states
        self.signIn = signIn
    }
}
