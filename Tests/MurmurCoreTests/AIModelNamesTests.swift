import Foundation
import Testing
@testable import MurmurCore

/// Model names the recogniser writes wrongly ("son at agent" for "Sonnet agent") or in lower case. Every sentence is
/// invented; the must-not lines are ordinary English that has to stay as heard.
@Suite("AI model names: Sonnet, Opus, Haiku, Codex, Gemini, GPT, Claude Code")
struct AIModelNamesTests {
    private static let claudeApp = "com.anthropic.claudefordesktop"

    private func fix(_ text: String, frontmost: String? = nil, agentSession: Bool = false, screen: [String] = []) -> String {
        AIProductNameFixer.fix(text, settings: PipelineSettings(
            contextTerms: screen, frontmostBundleID: frontmost, focusedAgentSession: agentSession))
    }

    @Test("the two-word mishearing of Sonnet, with an AI word in the clause")
    func sonAtIsSonnet() {
        let cases: [(String, String)] = [
            ("Please start a son at agent to work on this", "Please start a Sonnet agent to work on this"),
            ("Please start a son at agent to work on this and report back", "Please start a Sonnet agent to work on this and report back"),
            ("spin up a son at subagent for the migration", "spin up a Sonnet subagent for the migration"),
            ("Use son at for this prompt, not Opus", "Use Sonnet for this prompt, not Opus"),
            ("Ask the son net model to rewrite the prompt", "Ask the Sonnet model to rewrite the prompt"),
            ("Can you spin up some at agent for the migration", "Can you spin up Sonnet agent for the migration"),
            ("start a sonet agent and an opus agent", "start a Sonnet agent and an Opus agent"),
            ("Anthropic says sonnett is cheaper", "Anthropic says Sonnet is cheaper"),
        ]
        for (heard, want) in cases { #expect(fix(heard) == want, "\(heard)") }
        #expect(fix("Please start a son at agent to work on this", frontmost: Self.claudeApp)
                == "Please start a Sonnet agent to work on this")
    }

    @Test("ordinary English with the same words stays as heard")
    func sonAtStays() {
        let cases = [
            "My son at school forgot his lunch",
            "my son at the agent's office signed the form",
            "I picked up his son at home after the agent called",
            "Their son at college asked the agent about the lease",
            "She has some at the table and some at the door",
            "the agent said some at the front were late",
            "Is your son at the model railway club today",
            "We lost a son at war and an agent at the border",
            "The sonnet is fourteen lines and the haiku is three",
            "Write a haiku and a sonnet about spring",
        ]
        for text in cases {
            #expect(fix(text) == text, "\(text)")
            #expect(fix(text, frontmost: Self.claudeApp) == text, "in the Claude app: \(text)")
        }
    }

    @Test("sonnet, opus, haiku: capital letters with an AI cue, or in an Anthropic app at a name position")
    func lowerCaseNames() {
        let withCue: [(String, String)] = [
            ("use sonnet for the agent and opus for the planner", "use Sonnet for the agent and Opus for the planner"),
            ("the model called haiku is the fastest", "the model called Haiku is the fastest"),
            ("Anthropic's opus is slower than sonnet", "Anthropic's Opus is slower than Sonnet"),
            ("I asked claude to compare sonnet and haiku", "I asked claude to compare Sonnet and Haiku"),
            ("switch the api to opus 4", "switch the api to Opus 4"),
        ]
        for (heard, want) in withCue { #expect(fix(heard) == want, "\(heard)") }
        let inApp: [(String, String)] = [
            ("use sonnet for this one", "use Sonnet for this one"),
            ("switch to opus before the long task", "switch to Opus before the long task"),
            ("start a haiku agent to check the notes", "start a Haiku agent to check the notes"),
            ("try opus 4 on the same file", "try Opus 4 on the same file"),
            ("use opus and sonnet together", "use Opus and Sonnet together"),
        ]
        for (heard, want) in inApp { #expect(fix(heard, frontmost: Self.claudeApp) == want, "\(heard)") }
        // Without a cue or an Anthropic app nothing says it is the model.
        #expect(fix("use sonnet for this one") == "use sonnet for this one")
    }

    @Test("the poem, the music and the star sign stay lower case")
    func poemsStay() {
        let cases = [
            "write a sonnet about autumn",
            "she composed an opus for the choir",
            "he read a haiku at dinner",
            "my sister is a gemini and loves poetry",
            "a haiku and a sonnet",
        ]
        for text in cases {
            #expect(fix(text) == text, "\(text)")
            #expect(fix(text, frontmost: Self.claudeApp) == text, "in the Claude app: \(text)")
        }
    }

    @Test("codex, gpt, claude code and spoken letters")
    func otherProducts() {
        let cases: [(String, String)] = [
            ("compare gpt and gemini on this prompt", "compare gpt and Gemini on this prompt"),
            ("run claude code in the terminal", "run Claude Code in the terminal"),
            ("ask g p t to summarize the doc", "ask GPT to summarize the doc"),
        ]
        for (heard, want) in cases { #expect(fix(heard) == want, "\(heard)") }
        // Products spelled right are left alone, and the cloud fixers keep working beside them.
        #expect(fix("Sonnet and Opus are Claude models") == "Sonnet and Opus are Claude models")
        #expect(fix("Cloud has a feature by Anthropic and sonnet is fast") == "Claude has a feature by Anthropic and Sonnet is fast")
    }

    @Test("a dictionary entry or a rejected swap keeps what the person said")
    func keepsHeard() {
        let keep = KeepHeardSet(swaps: [VocabularySwap(heard: "son at", written: "Sonnet", source: .productName)])
        let settings = PipelineSettings(keepHeard: keep)
        #expect(AIProductNameFixer.fix("Please start a son at agent", settings: settings) == "Please start a son at agent")
    }

    @Test("AI-prompt apps boost the model names for the recogniser; other apps do not")
    func boosting() {
        let plain = PipelineSettings().vocabulary.terms.map(\.text)
        #expect(!plain.contains("Sonnet"))
        let prompt = PipelineSettings(aiPromptApp: true).vocabulary.terms.map(\.text)
        for name in ["Sonnet", "Opus", "Haiku", "Claude Code", "Codex", "Gemini", "GPT"] { #expect(prompt.contains(name), "\(name)") }
        #expect(PipelineSettings(aiPromptApp: true).contextWarmVocabulary != nil)
        #expect(PipelineSettings().contextWarmVocabulary == nil)
        let settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(), tone: .standard, mode: Mode.builtIns(userName: "")[0], category: .aiPrompts,
            bundleID: Self.claudeApp, windowTitle: nil)
        #expect(settings.aiPromptApp)
        let mail = PipelineSettings.forDictation(
            cleanup: CleanupOptions(), tone: .standard, mode: Mode.builtIns(userName: "")[0], category: .email,
            bundleID: "com.apple.mail", windowTitle: nil)
        #expect(!mail.aiPromptApp)
    }
}
