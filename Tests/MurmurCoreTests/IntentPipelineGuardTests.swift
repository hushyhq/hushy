import Foundation
import Testing
@testable import MurmurCore

private struct IntentTestTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float]) async throws -> String { text }
}

private struct IntentTestModel: LanguageModel {
    let answer: String
    var identifier: String { "scripted-intent" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
    }
}

@Suite("Intent pipeline guards")
struct IntentPipelineGuardTests {
    private func run(_ raw: String, answer: String) async -> PipelineResult {
        let cleaner = SmartCleaner(model: IntentTestModel(answer: answer), health: ModelHealth(), wholeTranscript: { true })
        let pipeline = DictationPipeline(transcriber: IntentTestTranscriber(text: raw), cleaner: cleaner)
        return await pipeline.clean(raw, settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished)))
    }

    @Test("a number correction keeps the later quantity without restoring the earlier one")
    func numberCorrection() async {
        let result = await run("We need five licences, my mistake, fifty licences.", answer: "We need 50 licences.")
        #expect(result.text == "We need 50 licences.", "rejection: \(String(describing: result.rejection))")
    }

    @Test("a name correction keeps the later person")
    func nameCorrection() async {
        let result = await run("Loop in Elena, sorry, loop in Rahul.", answer: "Loop in Rahul.")
        #expect(result.text == "Loop in Rahul.", "rejection: \(String(describing: result.rejection))")
    }

    @Test("a month correction keeps the later month")
    func monthCorrection() async {
        let result = await run("We ship in June, hold on, November.", answer: "We ship in November.")
        #expect(result.text == "We ship in November.", "rejection: \(String(describing: result.rejection))")
    }

    @Test("correction lead-ins are removed with the abandoned value")
    func correctionLeadIns() async {
        for cue in ["my mistake", "my bad", "sorry", "I mean", "no wait", "scratch that", "actually"] {
            let raw = "We need five licences, \(cue), fifty licences."
            let result = await run(raw, answer: "We need 50 licences.")
            #expect(result.text == "We need 50 licences.", "cue: \(cue), rejection: \(String(describing: result.rejection))")
        }
    }

    @Test("an invented number is refused even beside a real correction")
    func inventedNumber() async {
        let answer = "We need 70 licences."
        let result = await run("We need five licences, my mistake, fifty licences.", answer: answer)
        #expect(result.text != answer)
        // The value span goes back as the rules draft wrote it (or the draft stands): 70 is never pasted.
        #expect(!result.text.contains("70"), "\(result.text)")
    }

    @Test("a final corrected quantity must not be omitted")
    func droppedFinalNumber() async {
        let answer = "We need licences."
        let result = await run("We need five licences, my mistake, fifty licences.", answer: answer)
        #expect(result.text != answer)
        #expect(result.text.contains("50") || result.text.lowercased().contains("fifty"), "\(result.text)")
    }

    @Test("an invented name is refused even beside a real correction")
    func inventedName() async {
        let answer = "Loop in Maya."
        let result = await run("Loop in Elena, sorry, loop in Rahul.", answer: answer)
        #expect(result.text != answer)
        #expect(result.rejection != nil)
    }

    @Test("a spoken month is not rejected by a correction heuristic")
    func retractedMonth() async {
        let answer = "We ship in June."
        let result = await run("We ship in June, hold on, November.", answer: answer)
        #expect(result.text == answer)
    }

    @Test("an omitted negation is left to the intent model")
    func unretractedNegation() async {
        let answer = "We ship in November."
        let result = await run("We do not ship in June, hold on, November.", answer: answer)
        #expect(result.text == answer)
    }

    @Test("omitted content is left to the intent model")
    func unretractedContent() async {
        let answer = "We need 50 licences."
        let result = await run("We need five licences for the remote design team, my mistake, fifty licences.", answer: answer)
        #expect(result.text == answer)
    }

    @Test("an admission may be omitted")
    func standaloneAdmission() async {
        let answer = "I will fix the invoice."
        let result = await run("That was my mistake, I will fix the invoice.", answer: answer)
        #expect(result.text == answer)
    }

    @Test("a clause before a hedge may be omitted")
    func clauseBeforeHedge() async {
        let answer = "I think we should wait."
        let result = await run("The warehouse lost the revised schedule. I think we should wait.", answer: answer)
        #expect(result.text == answer)
    }

    @Test("hedges, purpose phrases, retractions, and doubled words are model choices")
    func intentOmissions() async {
        let cases = [
            ("Maybe we can send the outline tomorrow.", "We can send the outline tomorrow."),
            ("Send the outline to prepare for the review.", "Send the outline."),
            ("Use the old draft, no wait, use the new draft.", "Use the new draft."),
            ("I I sent the outline yesterday.", "I sent the outline yesterday."),
        ]
        for (raw, answer) in cases {
            let result = await run(raw, answer: answer)
            #expect(result.text == answer, "rejection: \(String(describing: result.rejection))")
        }
    }

    @Test("a negation absent from the transcript is refused")
    func inventedNegation() async {
        let answer = "We should not send the outline today."
        let result = await run("We should send the outline today.", answer: answer)
        #expect(result.text != answer)
        #expect(result.rejection != nil)
    }

    @Test("the intent guard accepts spoken values in another form")
    func spokenValues() async {
        let result = await run("Send it to Elena on the fifth of March, sorry, Rahul on March sixth.",
                               answer: "Send it to Rahul on March 6.")
        #expect(result.text == "Send it to Rahul on March 6.", "rejection: \(String(describing: result.rejection))")
    }

    @Test("an answer rejected by intent checks is not span repaired")
    func noSpanRepair() async {
        let answer = "We need 70 licences."
        let result = await run("We need five licences, my mistake, fifty licences.", answer: answer)
        #expect(result.text != answer)
        #expect(!result.text.contains("70"))
    }

    @Test("protected dictionary terms still survive")
    func protectedTerm() async {
        let raw = "Send the Kubernetes notes to Elena."
        let answer = "Send the notes to Elena."
        let cleaner = SmartCleaner(model: IntentTestModel(answer: answer), wholeTranscript: { true })
        var options = CleanupOptions(level: .polished)
        options.protectedTerms = ["Kubernetes"]
        let output = await cleaner.clean(raw, options: options, strategy: .model)
        #expect(output.text != answer)
    }

    @Test("a reply to the question is refused")
    func answerInsteadOfRewrite() async {
        let answer = "Yes."
        let result = await run("Can you ask Elena, sorry, can you ask Rahul whether the build is ready?", answer: answer)
        #expect(result.text != answer)
        #expect(result.rejection?.hasPrefix("not a rewrite") == true)
    }

    @Test("the older cleanup profile still repairs a changed spoken number")
    func legacyFidelityUnchanged() {
        let original = "We need five licences."
        let changed = SpokenWordFidelity.enforce(
            answer: "We need fifty licences.", draft: original, lowConfidenceWords: nil)
        #expect(changed.text == original)
    }

    @Test("the comparison draft retains content after the corrected slot")
    func comparisonDraft() throws {
        let resolved = try #require(IntentCorrection.resolve(
            "We need five licences for the remote design team, my mistake, fifty licences."))
        #expect(resolved.reference.lowercased().contains("for the remote design team"))
        #expect(!resolved.retracted.lowercased().contains("remote design team"))
    }
}
