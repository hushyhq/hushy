import Foundation
import Testing
@testable import MurmurCore

@Suite("Terminal agent prompt context")
struct TerminalAgentContextTests {
    private func job(_ pid: Int32, _ parent: Int32, _ group: Int32, _ foreground: Int32,
                     _ command: String, tty: String = "ttys001") -> TerminalAgentContext.Job {
        .init(pid: pid, parent: parent, group: group, foregroundGroup: foreground, tty: tty, command: command)
    }

    @Test("Claude under iTerm's foreground tty is a prompt")
    func claudeInITerm() {
        let jobs = [job(11, 10, 11, 12, "/bin/zsh"), job(12, 11, 12, 12, "/usr/local/bin/claude")]
        #expect(TerminalAgentContext.isAgent(bundleID: "com.googlecode.iterm2", terminalPID: 10,
                                             title: nil, focusedDescription: nil, jobs: jobs))
    }

    @Test("Codex under Terminal's foreground tty is a prompt")
    func codexInTerminal() {
        let jobs = [job(21, 20, 21, 22, "/bin/zsh"), job(22, 21, 22, 22, "/opt/homebrew/bin/codex")]
        #expect(TerminalAgentContext.isAgent(bundleID: "com.apple.Terminal", terminalPID: 20,
                                             title: "project — codex — 80x24", focusedDescription: nil, jobs: jobs))
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(ToneSettings.standard.dictationLevel)
        let prompt = PipelineSettings.forDictation(cleanup: CleanupOptions(level: .polished), tone: .standard,
                                                   mode: mode, category: .aiPrompts, bundleID: "com.apple.Terminal",
                                                   windowTitle: nil)
        #expect(!prompt.cleanupOptions.isCodeContext)
        #expect(prompt.style != nil)
        #expect(TerminalAgentContext.isAgent(bundleID: "com.apple.Terminal", terminalPID: 20,
                                             title: "project — codex", focusedDescription: nil, jobs: []))
    }

    @Test("A plain zsh prompt, vim and a background agent remain code")
    func otherForegroundJobs() {
        for command in ["/bin/zsh", "/usr/bin/vim"] {
            #expect(!TerminalAgentContext.isAgent(bundleID: "com.apple.Terminal", terminalPID: 30,
                                                  title: "project — zsh", focusedDescription: nil,
                                                  jobs: [job(31, 30, 31, 31, command)]))
        }
        #expect(!TerminalAgentContext.isAgent(bundleID: "com.apple.Terminal", terminalPID: 30,
                                              title: nil, focusedDescription: nil,
                                              jobs: [job(31, 30, 31, 32, "claude")]))
    }

    @Test("VS Code requires focused integrated terminal")
    func integratedTerminal() {
        let jobs = [job(41, 40, 41, 42, "zsh"), job(42, 41, 42, 42, "cursor-agent")]
        #expect(TerminalAgentContext.isAgent(bundleID: "com.microsoft.VSCode", terminalPID: 40,
                                             title: "main.swift — Visual Studio Code",
                                             focusedDescription: "Terminal 1", jobs: jobs))
        #expect(!TerminalAgentContext.isAgent(bundleID: "com.microsoft.VSCode", terminalPID: 40,
                                              title: "main.swift — Visual Studio Code",
                                              focusedDescription: "Source editor", jobs: jobs))
        #expect(!TerminalAgentContext.isAgent(bundleID: "com.microsoft.VSCode", terminalPID: 40,
                                              title: "Claude Code — Visual Studio Code",
                                              focusedDescription: "Terminal 1", jobs: []))
    }

    @Test("Only visible terminal text supplies names, identifiers, files and paths")
    func screenTerms() {
        let visible = """
        Claude Code
        Edited Sources/PromptRouter.swift and Tests/PromptRouterTests.swift
        The method promptSessionID reads ~/work/agent_config.json
        """
        let terms = TerminalScreenTerms.extract(visible)
        #expect(terms.contains("promptSessionID"))
        #expect(terms.contains("Sources/PromptRouter.swift"))
        #expect(terms.contains("~/work/agent_config.json"))
        #expect(!terms.contains("Edited Sources/PromptRouter.swift and Tests/PromptRouterTests.swift"))
    }

    @Test("ps parser keeps process fields without capturing arguments")
    func parsePS() {
        let jobs = TerminalAgentContext.parsePS(" 42 41 42 42 ttys001 /usr/local/bin/claude\n")
        #expect(jobs == [job(42, 41, 42, 42, "/usr/local/bin/claude")])
    }
}
