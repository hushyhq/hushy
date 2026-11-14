import Foundation
import Testing
@testable import MurmurCore

@Suite("Built-in AI product names (TRY-94)")
struct AIProductNameFixerTests {
    private func fix(_ text: String, screen: [String] = [], frontmost: String? = nil,
                     apps: [InstalledAppInfo] = []) -> String {
        AIProductNameFixer.fix(text, settings: PipelineSettings(
            contextTerms: screen, installedApps: apps, frontmostBundleID: frontmost))
    }

    @Test("Claude: a cue in the same clause names the product")
    func claudeWithCue() {
        #expect(fix("ask clawed to refactor this") == "ask Claude to refactor this")
        #expect(fix("I asked clawed about the prompt") == "I asked Claude about the prompt")
        #expect(fix("the model clod gave me a better answer") == "the model Claude gave me a better answer")
        #expect(fix("Anthropic makes claud") == "Anthropic makes Claude")
        #expect(fix("use clawed in the terminal") == "use Claude in the terminal")
        #expect(fix("clawed wrote the agent for me") == "Claude wrote the agent for me")
    }

    @Test("Claude: the screen or the frontmost app is enough")
    func claudeWithScreenOrApp() {
        #expect(fix("clawed said yes", screen: ["Claude"]) == "Claude said yes")
        #expect(fix("thanks to clawed", screen: ["Claude Code", "Rutger"]) == "thanks to Claude")
        #expect(fix("clawed said yes", frontmost: "com.anthropic.claudefordesktop") == "Claude said yes")
        let app = InstalledAppInfo(bundleID: "example.assistant", name: "Claude", declaredCategory: nil)
        #expect(fix("clawed said yes", frontmost: "example.assistant", apps: [app]) == "Claude said yes")
    }

    @Test("Claude: ordinary English stays as heard")
    func claudeOrdinary() {
        for text in [
            "the cat clawed the sofa", "the cat clawed at the door", "she clawed her way out",
            "a clod of dirt", "the clod of earth fell", "clawed hands", "the bear clawed it",
            "the cat clawed me when I asked it to stop",
            "the cloud bill is high", "ask the cloud provider", "I use cloud storage", "cloud code examples",
            "ask cloud to summarize",
        ] {
            #expect(fix(text) == text, "\(text)")
        }
        // The verb's grammar holds even when the screen shows the product.
        #expect(fix("the cat clawed the sofa", screen: ["Claude"]) == "the cat clawed the sofa")
        #expect(fix("a clod of dirt", screen: ["Claude"]) == "a clod of dirt")
        // No cue, no screen, no app: nothing says it is the product.
        #expect(fix("clawed said yes") == "clawed said yes")
    }

    @Test("Claude Code: the two words are the name")
    func claudeCode() {
        #expect(fix("I use clawed code every day") == "I use Claude Code every day")
        #expect(fix("clawed code is open") == "Claude Code is open")
        #expect(fix("open claud code") == "open Claude Code")
        #expect(fix("ask clod code to fix it") == "ask Claude Code to fix it")
        // "cloud code" is ordinary English often enough to need a cue other than "code".
        #expect(fix("ask cloud code to fix the tests") == "ask Claude Code to fix the tests")
        #expect(fix("cloud code is running", screen: ["Claude Code"]) == "Claude Code is running")
        #expect(fix("I use cloud code every day") == "I use cloud code every day")
        #expect(fix("the cloud code runs on the server") == "the cloud code runs on the server")
        #expect(fix("the cloud bill is high") == "the cloud bill is high")
    }

    @Test("ChatGPT")
    func chatGPT() {
        #expect(fix("I asked chat gpt about it") == "I asked ChatGPT about it")
        #expect(fix("compare chat g p t with the others") == "compare ChatGPT with the others")
        #expect(fix("chat gbt wrote this") == "ChatGPT wrote this")
        #expect(fix("I asked ChatGPT about it") == "I asked ChatGPT about it")
        #expect(fix("let us chat about it") == "let us chat about it")
        #expect(fix("a chat with the team about gpt models") == "a chat with the team about gpt models")
    }

    @Test("Codex")
    func codex() {
        #expect(fix("ask codecs to write the tests") == "ask Codex to write the tests")
        #expect(fix("codecs is running", screen: ["Codex"]) == "Codex is running")
        #expect(fix("the agent codecs fixed the bug") == "the agent Codex fixed the bug")
        #expect(fix("the video codecs are installed") == "the video codecs are installed")
        #expect(fix("ask the audio codecs team") == "ask the audio codecs team")
        #expect(fix("which codecs does the player support") == "which codecs does the player support")
    }

    @Test("Wispr Flow and Superwhisper")
    func dictationApps() {
        #expect(fix("I compared whisper flow with Hushy") == "I compared Wispr Flow with Hushy")
        #expect(fix("the dictation app whisper flow is fast") == "the dictation app Wispr Flow is fast")
        #expect(fix("I use super whisper for voice notes") == "I use Superwhisper for voice notes")
        #expect(fix("a super whisper in my ear") == "a super whisper in my ear")
        #expect(fix("the whisper flow of the river") == "the whisper flow of the river")
        #expect(fix("wispr flow is fast") == "Wispr Flow is fast")
    }

    @Test("the user's own Dictionary and rejected pairs win")
    func userChoicesWin() {
        let own = Personalizer(dictionary: [DictionaryEntry(term: "Clawed", soundsLike: [])])
        let settings = PipelineSettings(personalizer: own)
        #expect(AIProductNameFixer.fix("ask clawed to refactor this", settings: settings) == "ask clawed to refactor this")
        let keep = KeepHeardSet(swaps: [VocabularySwap(heard: "clawed", written: "Claude", source: .productName)])
        let kept = PipelineSettings(keepHeard: keep)
        #expect(AIProductNameFixer.fix("ask clawed to refactor this", settings: kept) == "ask clawed to refactor this")
    }

    @Test("the dictation pipeline path applies it and records a swap")
    func throughFixNames() {
        let settings = PipelineSettings(contextTerms: ["Claude"])
        #expect(DictionaryTermFixer.fixNames("ask clawed to refactor this", settings: settings) == "ask Claude to refactor this")
        let swaps = VocabularySwaps.diff(from: "ask clawed to go", to: "ask Claude to go", source: .productName)
        #expect(swaps.map(\.written) == ["Claude"])
    }

    @Test("Cloud set directly against another AI product is Claude (TRY-101)")
    func cloudPairedWithProduct() {
        #expect(fix("Which do you think is better, Codex or Cloud?") == "Which do you think is better, Codex or Claude?")
        #expect(fix("ChatGPT and cloud are both fine") == "ChatGPT and Claude are both fine")
        #expect(fix("Cloud vs Gemini for writing") == "Claude vs Gemini for writing")
        #expect(fix("cloud versus codex") == "Claude versus codex")
        #expect(fix("Cloud, Codex and Cursor all work") == "Claude, Codex and Cursor all work")
        #expect(fix("Codex, Cursor, and cloud") == "Codex, Cursor, and Claude")
        #expect(fix("Codex & cloud") == "Codex & Claude")
        #expect(fix("Gemini and/or cloud") == "Gemini and/or Claude")
        #expect(fix("Cursor or Cloud or ChatGPT") == "Cursor or Claude or ChatGPT")
        #expect(fix("Claude or cloud") == "Claude or Claude")
    }

    @Test("Cloud as the place, a vendor or a storage word stays as heard (TRY-101)")
    func cloudOrdinary() {
        for text in [
            "the cloud", "cloud storage", "iCloud", "Google Cloud", "cloud or on-device", "AWS and cloud",
            "the cloud or Codex", "Google Cloud vs ChatGPT", "I keep it in the cloud and Codex runs locally",
            "cloud storage and Codex", "Codex Cloud", "move it to the cloud, Cursor can wait", "Azure or cloud",
            "private cloud or ChatGPT", "is it cloud or local", "cloud and on-device models",
        ] {
            #expect(fix(text) == text, "\(text)")
        }
    }

    @Test("a pairing does not touch the existing Claude rules")
    func clawedRulesUnchanged() {
        #expect(fix("ask clawed to refactor this") == "ask Claude to refactor this")
        #expect(fix("the cat clawed the sofa") == "the cat clawed the sofa")
        #expect(fix("ask cloud code to fix the tests") == "ask Claude Code to fix the tests")
        #expect(fix("clawed said yes or no") == "clawed said yes or no", "no cue, so the bare 'clawed' still stays as heard")
        #expect(fix("Codex or clawed", screen: ["Claude"]) == "Codex or Claude")
        #expect(fix("ask cloud code or cloud", screen: []) == "ask Claude Code or Claude")
    }

    @Test("the user's Dictionary and rejected pairs also win over a pairing")
    func pairingRespectsUserChoices() {
        let own = Personalizer(dictionary: [DictionaryEntry(term: "Cloud", soundsLike: [])])
        #expect(AIProductNameFixer.fix("Codex or Cloud", settings: PipelineSettings(personalizer: own)) == "Codex or Cloud")
        let keep = KeepHeardSet(swaps: [VocabularySwap(heard: "Cloud", written: "Claude", source: .productName)])
        #expect(AIProductNameFixer.fix("Codex or Cloud", settings: PipelineSettings(keepHeard: keep)) == "Codex or Cloud")
    }
}
