import Foundation
import Synchronization
import Testing

@testable import MurmurCore

/// A model that hands the transcript back unchanged and counts how often it was asked.
private final class CountingModel: LanguageModel, @unchecked Sendable {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    var identifier: String { "tone-pipeline-test" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        count.withLock { $0 += 1 }
        guard let start = prompt.range(of: "Transcript: ")?.upperBound,
              let end = prompt.range(of: "\nOutput:", range: start..<prompt.endIndex)?.lowerBound else {
            throw LanguageModelError.malformedOutput("test prompt did not contain a transcript")
        }
        return CompactCleanupPrompt.answerJSON(String(prompt[start..<end]))
    }
}

private struct NoSpeech: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// What the setting does to a dictation: the level it runs at, the tone it gets, and what is left
/// alone (code, other languages, "As spoken").
@Suite("Tone in the dictation pipeline")
struct TonePipelineTests {
    private let raw = "um I am gonna send the deck tomorrow and we do not need the demo"

    private func settings(
        _ tones: ToneSettings, category: AppCategory = .other, language: String? = nil, bundleID: String? = nil
    ) -> PipelineSettings {
        let plan = tones.plan(for: category, bundleID: bundleID)
        var options = CleanupOptions(level: plan.level)
        options.isCodeContext = category == .code
        options.detectedLanguage = language
        return PipelineSettings(cleanupOptions: options, style: plan.style, tone: plan.tone)
    }

    private func clean(
        _ text: String, _ settings: PipelineSettings, model: CountingModel = CountingModel(),
        strategy: SmartCleaner.Strategy? = .rules
    ) async -> PipelineResult {
        let pipeline = DictationPipeline(transcriber: NoSpeech(), cleaner: SmartCleaner(model: model))
        return await pipeline.clean(text, settings: settings, strategy: strategy)
    }

    // MARK: The tone reaches the output

    @Test("in email, an explicit tone wins over the place default, and the default only fills the gap")
    func emailChoiceIsHonoured() async {
        let mail = "hi dana I wanna send you the budget and I'm kinda worried, we don't have the number"
        let starting = await clean(mail, settings(ToneSettings.standard, category: .email)).text
        #expect(starting.contains("want to") && starting.contains("I am kind of") && starting.contains("do not"))
        for (tone, expectation) in [(DictationTone.casual, "I'm kinda"), (.refined, "I'm kinda")] {
            let chosen = ToneSettings.standard.settingTone(tone, for: .email)
            let text = await clean(mail, settings(chosen, category: .email)).text
            #expect(text.contains(expectation) && text.contains("don't") && text.contains("wanna"), "\(tone): \(text)")
        }
        let casual = await clean("hi dana I am happy and we do not need it",
                                 settings(ToneSettings.standard.settingTone(.casual, for: .email), category: .email)).text
        #expect(casual.contains("I'm happy") && casual.contains("don't need"))
    }

    @Test("each tone changes the words the way its rules say")
    func toneReachesOutput() async {
        var tones = ToneSettings.standard
        tones.choice = .refined
        let refined = await clean(raw, settings(tones)).text
        tones.choice = .casual
        let casual = await clean(raw, settings(tones)).text
        tones.choice = .professional
        let professional = await clean(raw, settings(tones)).text
        #expect(refined == "I am gonna send the deck tomorrow and we do not need the demo.")
        #expect(casual == "I'm gonna send the deck tomorrow and we don't need the demo")
        #expect(professional == "I am going to send the deck tomorrow and we do not need the demo.")
    }

    @Test("the tone for the place the dictation is going to is the one used")
    func perDestination() async {
        let tones = ToneSettings.standard.settingTone(.casual, for: .personalMessages)
            .settingTone(.professional, for: .email)
        let chat = await clean(raw, settings(tones, category: .personalMessages)).text
        let mail = await clean(raw, settings(tones, category: .email)).text
        let notes = await clean(raw, settings(tones, category: .documents)).text
        let slack = await clean(raw, settings(tones.settingApp(.tone(.casual), bundleIDs: ["com.tinyspeck.slackmacgap"]),
                                              category: .workMessages, bundleID: "com.tinyspeck.slackmacgap")).text
        #expect(slack.contains("I'm gonna") && slack.contains("don't"))
        #expect(chat.contains("I'm gonna") && chat.contains("don't"))
        #expect(mail.contains("going to") && mail.contains("do not"))
        #expect(notes.contains("I am gonna") && notes.contains("do not"))
    }

    @Test("a layout kept from the old Style page still lays the text out")
    func keptLayoutReachesOutput() async {
        let earlier = ToneSettings.Earlier(cleanupLevel: "clean", styles: ["other": "veryCasual"], isExistingInstall: true)
        let text = await clean("Hello there. How are you", settings(ToneSettings.migrated(from: earlier))).text
        #expect(text == "hello there. how are you?")
    }

    // MARK: Which level runs, and whether the model is asked

    @Test("a tone asks the model for the cleanup; As spoken never does")
    func modelIsAskedForTonesOnly() async {
        for choice in ToneChoice.allCases {
            var tones = ToneSettings.standard
            tones.choice = choice
            let model = CountingModel()
            _ = await clean(raw, settings(tones), model: model, strategy: nil)
            if choice == .asSpoken {
                #expect(model.calls == 0, "As spoken must not call the model")
            } else {
                #expect(model.calls > 0, "\(choice) must take the model path")
            }
        }
    }

    @Test("As spoken keeps every word and adds no tone")
    func asSpokenIsWordForWord() async {
        var tones = ToneSettings.standard.settingTone(.casual, for: .other)
        tones.choice = .asSpoken
        let result = await clean("Um, I am gonna go, do not wait", settings(tones), strategy: nil)
        #expect(result.text == "Um, I am gonna go, do not wait")
        #expect(!result.usedModel)
    }

    // MARK: What is left alone

    @Test("code editors and terminals get no tone")
    func codeIsUntouched() async {
        var tones = ToneSettings.standard
        tones.choice = .casual
        let model = CountingModel()
        let result = await clean("I am gonna run git status and do not push", settings(tones, category: .code), model: model)
        #expect(!result.text.contains("I'm"))
        #expect(!result.text.contains("don't"))
        #expect(result.text.contains("gonna"))
    }

    @Test("another language is laid out as before and no word is changed by a tone")
    func otherLanguageKeepsWords() async {
        var tones = ToneSettings.standard
        tones.choice = .casual
        let spanish = "hola I am gonna do not es la una"
        let result = await clean(spanish, settings(tones, language: "es"))
        #expect(result.text == "Hola I am gonna do not es la una")
        tones.choice = .professional
        let again = await clean(spanish, settings(tones, language: "es"))
        #expect(again.text == "Hola I am gonna do not es la una.")
    }

    @Test("a tone steps down from the model level for another language, and only then")
    func languageLevel() {
        let tones = ToneSettings.standard
        #expect(settings(tones, language: "es").resolvedForLanguage().cleanupOptions.level == .clean)
        #expect(settings(tones, language: "en").resolvedForLanguage().cleanupOptions.level == .polished)
        #expect(settings(tones, language: "en-GB").resolvedForLanguage().cleanupOptions.level == .polished)
        #expect(settings(tones, language: nil).resolvedForLanguage().cleanupOptions.level == .polished)
        var asSpoken = tones
        asSpoken.choice = .asSpoken
        #expect(settings(asSpoken, language: "es").resolvedForLanguage().cleanupOptions.level == .verbatim)
        var noTone = settings(tones, language: "es")
        noTone.tone = nil
        #expect(noTone.resolvedForLanguage().cleanupOptions.level == .polished)
    }
}
