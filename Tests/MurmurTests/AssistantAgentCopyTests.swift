import MurmurCore
import Testing
@testable import Murmur

@Suite struct AssistantAgentCopyTests {
    @Test("off-card copy names Claude Code only, not Codex chat")
    func offCardTruthful() {
        #expect(!AssistantAgentCopy.offCardTitle.localizedCaseInsensitiveContains("or codex"))
        #expect(AssistantAgentCopy.offCardInstallLine.contains("Install Claude Code"))
        #expect(AssistantAgentCopy.offCardInstallLine.contains("coming soon"))
    }

    @Test("setup copy tracks Claude Code sign-in vs install")
    func setupMapping() {
        #expect(AssistantAgentCopy.setupTitle(claudeState: .signedOut) == "Sign in to Claude Code")
        #expect(AssistantAgentCopy.setupTitle(claudeState: .notInstalled) == "Install Claude Code to chat")
        #expect(AssistantAgentCopy.setupBody(claudeState: .signedOut).contains("not signed in"))
        #expect(AssistantAgentCopy.codexInstalledFootnote(codexState: .notInstalled) == nil)
        #expect(AssistantAgentCopy.codexInstalledFootnote(codexState: .ready)?.contains("coming soon") == true)
    }

    @Test("four agent-detection cases match chat behavior")
    func fourCases() {
        let onlyClaude = AssistantAgentCopy.Availability(claude: .ready, codex: .notInstalled)
        #expect(onlyClaude.canChat)
        #expect(onlyClaude.outcomeSummary.contains("Claude Code"))

        let onlyCodex = AssistantAgentCopy.Availability(claude: .notInstalled, codex: .ready)
        #expect(!onlyCodex.canChat)
        #expect(onlyCodex.outcomeSummary.contains("install Claude Code"))
        #expect(onlyCodex.outcomeSummary.contains("cannot chat"))

        let both = AssistantAgentCopy.Availability(claude: .ready, codex: .ready)
        #expect(both.canChat)
        #expect(both.outcomeSummary.contains("coming soon"))

        let neither = AssistantAgentCopy.Availability(claude: .notInstalled, codex: .notInstalled)
        #expect(!neither.canChat)
        #expect(neither.outcomeSummary.contains("install Claude Code"))
    }

    @Test("signed-out Claude blocks chat until the person signs in")
    func signInRequired() {
        let availability = AssistantAgentCopy.Availability(claude: .signedOut, codex: .notInstalled)
        #expect(!availability.canChat)
        #expect(availability.outcomeSummary.contains("sign in"))
    }
}
