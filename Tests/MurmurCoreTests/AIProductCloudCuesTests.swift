import Foundation
import Testing
@testable import MurmurCore

/// A bare "cloud" that is really "Claude", on evidence in the dictation or in the place it is spoken (TRY-103).
/// The common word stays safe: every must-not line here is ordinary English or another vendor's product.
@Suite("Bare cloud is Claude when the evidence is strong (TRY-103)")
struct AIProductCloudCuesTests {
    private static let claudeApp = "com.anthropic.claudefordesktop"

    private func fix(_ text: String, frontmost: String? = nil, agentSession: Bool = false,
                     screen: [String] = []) -> String {
        AIProductNameFixer.fix(text, settings: PipelineSettings(
            contextTerms: screen, frontmostBundleID: frontmost, focusedAgentSession: agentSession))
    }

    @Test("the founder's sentence in the Claude desktop app")
    func founderSentence() {
        let heard = "Cloud has a feature where pressing Tab triggers autocomplete. I think this is a great feature by Anthropic."
        let want = "Claude has a feature where pressing Tab triggers autocomplete. I think this is a great feature by Anthropic."
        #expect(fix(heard, frontmost: Self.claudeApp) == want)
        #expect(fix(heard) == want, "the Anthropic cue alone is enough, whatever app it is spoken in")
        let noAnthropic = "Cloud has a feature where pressing Tab triggers autocomplete."
        #expect(fix(noAnthropic, frontmost: Self.claudeApp) == "Claude has a feature where pressing Tab triggers autocomplete.")
        #expect(fix(noAnthropic) == noAnthropic, "no cue and no Anthropic app: nothing says it is the product")
    }

    @Test("cue 1: the same dictation names an Anthropic or AI product or word")
    func dictationCue() {
        let cases: [(String, String)] = [
            ("Anthropic released cloud last year", "Anthropic released Claude last year"),
            ("Is cloud better than Gemini?", "Is Claude better than Gemini?"),
            ("Sonnet is fast but cloud is better at planning", "Sonnet is fast but Claude is better at planning"),
            ("I think cloud wrote that prompt", "I think Claude wrote that prompt"),
            ("the cloud is cheaper than Opus, but cloud writes better", "the cloud is cheaper than Opus, but Claude writes better"),
            ("I asked cloud about Haiku pricing", "I asked Claude about Haiku pricing"),
            ("cloud and I tuned the LLM together", "Claude and I tuned the LLM together"),
            ("Codex wrote the tests and cloud reviewed them", "Codex wrote the tests and Claude reviewed them"),
            ("ChatGPT gave one answer, cloud gave another", "ChatGPT gave one answer, Claude gave another"),
            ("this model is why I like cloud so much", "this model is why I like Claude so much"),
            ("cloud's answer to the prompts was shorter", "Claude's answer to the prompts was shorter"),
            ("Cloud Code is open and Anthropic shipped an update", "Claude Code is open and Anthropic shipped an update"),
            ("I opened cloud code to try the new Opus", "I opened Claude Code to try the new Opus"),
        ]
        for (heard, want) in cases { #expect(fix(heard) == want, "\(heard)") }
    }

    @Test("cue 2: an Anthropic app and a name where a name would be")
    func anthropicAppCue() {
        let cases: [(String, String)] = [
            ("Cloud has a good answer for that", "Claude has a good answer for that"),
            ("I think cloud is wrong here", "I think Claude is wrong here"),
            ("ask cloud to review the plan", "ask Claude to review the plan"),
            ("tell Cloud what I want", "tell Claude what I want"),
            ("Cloud, can you shorten this?", "Claude, can you shorten this?"),
            ("Cloud's answer was shorter", "Claude's answer was shorter"),
            ("yesterday cloud said it would take an hour", "yesterday Claude said it would take an hour"),
        ]
        for (heard, want) in cases { #expect(fix(heard, frontmost: Self.claudeApp) == want, "\(heard)") }
        // A terminal running an agent counts as well.
        #expect(fix("Cloud thinks the test is flaky", agentSession: true) == "Claude thinks the test is flaky")
        #expect(fix("Cloud thinks the test is flaky") == "Cloud thinks the test is flaky", "an ordinary app")
    }

    @Test("cue 3: Cloud Code is a product only with a cue")
    func cloudCode() {
        #expect(fix("run cloud code here", frontmost: Self.claudeApp) == "run Claude Code here")
        #expect(fix("run cloud code here", agentSession: true) == "run Claude Code here")
        #expect(fix("Cloud Code works with Opus") == "Claude Code works with Opus")
        #expect(fix("Cloud Code works") == "Cloud Code works", "Google has a Cloud Code extension")
        #expect(fix("Google has a Cloud Code extension for the model", frontmost: Self.claudeApp)
                == "Google has a Cloud Code extension for the model")
        #expect(fix("Google Cloud Code and Anthropic") == "Google Cloud Code and Anthropic")
    }

    @Test("the common word stays as heard, whatever else is said")
    func ordinaryStays() {
        let lines = [
            "store it in the cloud, Anthropic says",
            "the cloud is cheaper than Opus",
            "Google Cloud and Anthropic",
            "iCloud Drive",
            "iCloud Drive and the Anthropic docs",
            "Anthropic runs its models on AWS and cloud",
            "I back up my photos to cloud storage and ask the model later",
            "move the model to the cloud",
            "the cloud model is slower than the on-device model",
            "Opus on cloud GPUs is expensive",
            "cloud or on-device, the prompt stays private",
            "local or cloud for the LLM",
            "Gemini runs in Google Cloud",
            "Azure cloud pricing for Anthropic usage",
            "private cloud hosting for the model",
            "multi-cloud setups with Codex",
            "our cloud provider changed the prompt limits",
            "keep the data in cloud because the model is big",
            "cloud-based tools like ChatGPT",
            "Cloud Code extension from Google, not Anthropic",
            "a cloud sync problem with the LLM",
            "cloud costs for Sonnet are high",
            "Amazon cloud has outages, the model was down",
            "Salesforce cloud vs on-prem for Anthropic",
            "deploy it to cloud for the prompt service",
        ]
        for line in lines { #expect(fix(line) == line, "\(line)") }
    }

    @Test("the common word stays as heard in an Anthropic app too")
    func ordinaryStaysInApp() {
        let lines = [
            "the cloud has outages", "Google Cloud has a new feature", "my cloud's bill is high",
            "iCloud has the file", "AWS cloud has outages", "I store files in cloud", "cloud storage is cheaper",
            "cloud costs are high", "cloud-based tools are fine", "the cloud is expensive",
            "move it to cloud, can you help", "Google Cloud Code has a new release", "cloud or on-device",
            "cloud provider has a status page",
        ]
        for line in lines {
            #expect(fix(line, frontmost: Self.claudeApp) == line, "\(line)")
            #expect(fix(line, agentSession: true) == line, "\(line)")
        }
    }

    @Test("the user's Dictionary and rejected pairs win over a cue")
    func userChoicesWin() {
        let own = Personalizer(dictionary: [DictionaryEntry(term: "Cloud", soundsLike: [])])
        let owned = PipelineSettings(personalizer: own)
        #expect(AIProductNameFixer.fix("Anthropic released Cloud last year", settings: owned) == "Anthropic released Cloud last year")
        let keep = KeepHeardSet(swaps: [VocabularySwap(heard: "Cloud", written: "Claude", source: .productName)])
        #expect(AIProductNameFixer.fix("Anthropic released Cloud last year", settings: PipelineSettings(keepHeard: keep))
                == "Anthropic released Cloud last year")
    }

    @Test("through the dictation pipeline path")
    func throughFixNames() {
        let settings = PipelineSettings(frontmostBundleID: Self.claudeApp, focusedAgentSession: false)
        #expect(DictionaryTermFixer.fixNames("Cloud has a feature by Anthropic", settings: settings) == "Claude has a feature by Anthropic")
    }

    @Test("an agent prompt box in a terminal or editor is an agent session; an ordinary app is not")
    func agentSessionFromPlan() {
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(ToneSettings.standard.dictationLevel)
        func settings(_ category: AppCategory, _ bundleID: String) -> PipelineSettings {
            PipelineSettings.forDictation(cleanup: CleanupOptions(level: .polished), tone: .standard, mode: mode,
                                          category: category, bundleID: bundleID, windowTitle: nil)
        }
        #expect(settings(.aiPrompts, "com.apple.Terminal").focusedAgentSession)
        #expect(!settings(.aiPrompts, Self.claudeApp).focusedAgentSession, "the desktop app is matched by its bundle ID")
        #expect(!settings(.code, "com.apple.Terminal").focusedAgentSession, "a terminal with no agent in it")
        #expect(!settings(.workMessages, "com.tinyspeck.slackmacgap").focusedAgentSession)
    }
}
