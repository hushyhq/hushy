import MurmurCore

/// User-facing sentences for the Assistant and how they map to detected agent CLIs. Kept in one
/// place so tests can hold the words to `AgentAccountsModel` / `AgentAccountChecker` behavior.
enum AssistantAgentCopy {
    // MARK: Off card (no probing while off — static, always truthful)

    static let offCardTitle = "Chat about your notes and meetings with Claude Code"
    static let offCardDetail =
        "Off. Uses Claude Code on your Mac and your own Anthropic account. Nothing is sent until you ask."
    /// One line for the install path; shown on the off card because detection does not run until the Assistant is on.
    static let offCardInstallLine = "Install Claude Code on this Mac to chat. Codex chat is coming soon."

    // MARK: Setup card (Assistant on, Claude Code not ready to chat)

    static func setupTitle(claudeState: AgentAccountState) -> String {
        claudeState == .signedOut ? "Sign in to Claude Code" : "Install Claude Code to chat"
    }

    static func setupBody(claudeState: AgentAccountState) -> String {
        switch claudeState {
        case .signedOut:
            "Claude Code is on this Mac but not signed in. Sign-in happens in Claude Code itself, in your browser. Hushy never sees your password or token."
        case .notInstalled, .unknown:
            "Hushy chats through Claude Code on your own account, with read-only access to your notes and meetings. Nothing is sent until you ask."
        case .ready:
            ""
        }
    }

    /// When Codex is on the Mac but chat only runs through Claude Code.
    static func codexInstalledFootnote(codexState: AgentAccountState) -> String? {
        codexState == .notInstalled ? nil : "Codex is installed. Chatting through Codex is coming soon."
    }

    // MARK: Detection summary (what each combination actually gets)

    struct Availability: Equatable, Sendable {
        var claude: AgentAccountState
        var codex: AgentAccountState

        init(claude: AgentAccountState, codex: AgentAccountState) {
            self.claude = claude
            self.codex = codex
        }

        init(states: [AgentKind: AgentAccountState]) {
            claude = states[.claudeCode] ?? .notInstalled
            codex = states[.codex] ?? .notInstalled
        }

        /// Matches `AssistantModel.isConnected` (Assistant on, entitlement assumed).
        var canChat: Bool { claude.canChat }

        /// Plain-language outcome for docs and tests.
        var outcomeSummary: String {
            switch (claude, codex) {
            case (.ready, _), (.unknown, _):
                if codex != .notInstalled {
                    return "Chat through Claude Code on your account. Codex is on this Mac for other uses; Assistant chat through Codex is coming soon."
                }
                return "Chat through Claude Code on your account after you turn the Assistant on."
            case (.signedOut, _):
                return "Turn on the Assistant, then sign in to Claude Code in its own flow before you can send a message."
            case (.notInstalled, .notInstalled):
                return "Turn on the Assistant, then install Claude Code using the copyable command on the setup card."
            case (.notInstalled, _):
                return "Turn on the Assistant, then install Claude Code. Codex is already on this Mac but cannot chat inside Hushy yet."
            }
        }
    }
}
