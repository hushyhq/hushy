import Foundation
import Testing
@testable import MurmurCore

/// A deterministic fake ASR engine so pipeline tests don't depend on FluidAudio or real audio.
private struct FakeTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float]) async throws -> String { text }
}

private struct FailingTranscriber: Transcriber {
    struct Failure: Error {}
    func transcribe(_ samples: [Float]) async throws -> String { throw Failure() }
}

private struct LayoutReplyModel: LanguageModel {
    let flattenLineBreaks: Bool
    var delay: Duration = .zero
    var identifier: String { "layout-reply-test" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        let prefix = "Transcript: "
        guard let start = prompt.range(of: prefix)?.upperBound,
              let end = prompt.range(of: "\nOutput:", range: start..<prompt.endIndex)?.lowerBound else {
            throw LanguageModelError.malformedOutput("test prompt did not contain a transcript")
        }
        var text = String(prompt[start..<end])
        if flattenLineBreaks {
            text = text.replacingOccurrences(of: "\n", with: " ")
        }
        struct Reply: Encodable { let text: String }
        let data = try JSONEncoder().encode(Reply(text: text))
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("DictationPipeline")
struct DictationPipelineTests {
    @Test("a slow model call appears in the per-dictation stage line")
    func slowCleanupStageLine() async {
        let model = LayoutReplyModel(flattenLineBreaks: false, delay: .milliseconds(80))
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "unused"),
            cleaner: SmartCleaner(model: model))
        let result = await pipeline.clean("Please send the updated draft today.",
            settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished)))
        #expect(result.cleanupStages.contains("firstMs="))
        #expect(result.cleanupStages.contains("opinionCalls=0"))
        let first = result.groups.first?.measured.callMs ?? 0
        #expect(first >= 70)
        #expect(result.cleanupStages.contains("firstMs=\(first)"))
    }
    @Test("runs normalize, ASR, cleanup and style in one pass")
    func fullRun() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "hey are you free, um, tomorrow"))
        let settings = PipelineSettings(style: (.personalMessages, .casual))
        let result = try await pipeline.run(samples: [Float](repeating: 0, count: 16_000), settings: settings)
        #expect(result.raw == "hey are you free, um, tomorrow")
        // Fillers removed by cleanup, then casual style drops the trailing period.
        #expect(result.text == "Hey are you free tomorrow")
        #expect(!result.pressEnter)
        #expect(!result.usedModel)
    }

    @Test("empty ASR output short-circuits without calling cleanup")
    func emptyTranscript() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: ""))
        let result = try await pipeline.run(samples: [Float](repeating: 0, count: 16_000), settings: PipelineSettings())
        #expect(result.raw.isEmpty)
        #expect(result.text.isEmpty)
    }

    @Test("verbatim level skips styling")
    func verbatimSkipsStyle() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "hey, are you free tomorrow"))
        let settings = PipelineSettings(
            cleanupOptions: CleanupOptions(level: .verbatim), style: (.personalMessages, .casual))
        let result = try await pipeline.run(samples: [Float](repeating: 0, count: 16_000), settings: settings)
        // Verbatim keeps fillers/corrections and skips styling entirely: the casual style's
        // "drop the leading hey/hi comma" rewrite never runs, so the comma survives.
        #expect(result.text == "hey, are you free tomorrow")
        #expect(result.usedModel == false)
    }

    @Test("transcription errors propagate to the caller")
    func propagatesTranscriptionErrors() async {
        let pipeline = DictationPipeline(transcriber: FailingTranscriber())
        await #expect(throws: FailingTranscriber.Failure.self) {
            try await pipeline.run(samples: [Float](repeating: 0, count: 16_000), settings: PipelineSettings())
        }
    }

    @Test("clean(_:settings:) runs cleanup/style on an already-transcribed string")
    func cleanTextOnly() async {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "unused"))
        let result = await pipeline.clean("Um, let's meet at 10, no, 9.", settings: PipelineSettings())
        #expect(result.raw == "Um, let's meet at 10, no, 9.")
        #expect(result.text == "Let's meet at 9.")
    }

    @Test("model cannot flatten an explicit spoken paragraph through the production pipeline")
    func spokenParagraphSurvivesModelRewrite() async throws {
        let raw = "The trial ends on Friday, new paragraph, billing starts Monday."
        let cleaner = SmartCleaner(model: LayoutReplyModel(flattenLineBreaks: true), health: ModelHealth())
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: raw), cleaner: cleaner)
        let result = try await pipeline.run(
            samples: [Float](repeating: 0, count: 16_000),
            settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished))
        )
        #expect(result.text == "The trial ends on Friday\n\nBilling starts Monday.")
        #expect(result.usedModel)
        #expect(result.rejection == nil)
    }

    @Test("accepted Polished output keeps casing in explicit casual context")
    func polishedCasualCasingSurvivesAcceptedModelOutput() async throws {
        let raw = "hey, that works for me. see you around 6!"
        let cleaner = SmartCleaner(model: LayoutReplyModel(flattenLineBreaks: false), health: ModelHealth())
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: raw), cleaner: cleaner)
        var options = CleanupOptions(level: .polished)
        options.isCasualContext = true
        let result = try await pipeline.run(
            samples: [Float](repeating: 0, count: 16_000),
            settings: PipelineSettings(cleanupOptions: options)
        )
        #expect(result.text == raw)
        #expect(result.usedModel)
    }

    @Test("transcribeRaw normalizes and transcribes with no cleanup, for notes chunks")
    func transcribeRawSkipsCleanup() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "um, so this is a note"))
        let text = try await pipeline.transcribeRaw([Float](repeating: 0, count: 16_000))
        #expect(text == "um, so this is a note")
    }

    // MARK: Context awareness (PipelineSettings.contextTerms / vocabulary / usedContext)

    @Test("contextTerms merge into vocabulary alongside dictionary terms")
    func contextTermsMergeIntoVocabulary() {
        let settings = PipelineSettings(
            personalizer: Personalizer(dictionary: [DictionaryEntry(term: "Kubernetes")]),
            contextTerms: ["Siobhan"])
        let names = Set(settings.vocabulary.terms.map(\.text))
        #expect(names.contains("Kubernetes"))
        #expect(names.contains("Siobhan"))
    }

    @Test("a context term already present in the dictionary is not duplicated")
    func contextTermsDoNotDuplicateDictionary() {
        let settings = PipelineSettings(
            personalizer: Personalizer(dictionary: [DictionaryEntry(term: "Siobhan", soundsLike: ["Sioban"])]),
            contextTerms: ["siobhan"])
        let matches = settings.vocabulary.terms.filter { $0.text.lowercased() == "siobhan" }
        #expect(matches.count == 1)
        // The dictionary entry (with its soundsLike alias) wins over the plain context term.
        #expect(matches.first?.aliases == ["Sioban"])
    }

    @Test("a key-down warm-up is wanted only when the screen gave terms, and for exactly the release vocabulary")
    func contextWarmVocabulary() {
        let dictionary = Personalizer(dictionary: [DictionaryEntry(term: "Kubernetes")])
        #expect(PipelineSettings(personalizer: dictionary, contextTerms: []).contextWarmVocabulary == nil)
        let withTerms = PipelineSettings(personalizer: dictionary, contextTerms: ["Driftwatch"])
        #expect(withTerms.contextWarmVocabulary == withTerms.vocabulary)
        #expect(withTerms.contextWarmVocabulary?.terms.contains { $0.text == "Driftwatch" } == true)
        #expect(withTerms.contextWarmVocabulary != PipelineSettings(personalizer: dictionary).vocabulary)
    }

    @Test("empty contextTerms leaves vocabulary identical to dictionary-only")
    func emptyContextTermsNoOp() {
        let dictionaryOnly = PipelineSettings(personalizer: Personalizer(dictionary: [DictionaryEntry(term: "Kubernetes")]))
        let withEmptyContext = PipelineSettings(
            personalizer: Personalizer(dictionary: [DictionaryEntry(term: "Kubernetes")]), contextTerms: [])
        #expect(dictionaryOnly.vocabulary == withEmptyContext.vocabulary)
    }

    @Test("clean(_:settings:) reports usedContext when the spelling fixer changes the text")
    func cleanReportsUsedContextOnFix() async {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "unused"))
        let settings = PipelineSettings(contextTerms: ["Siobhan"])
        let result = await pipeline.clean("Send this to Sioban please.", settings: settings)
        #expect(result.text.contains("Siobhan"))
        #expect(result.usedContext)
    }

    @Test("clean(_:settings:) reports usedContext false when context terms make no difference")
    func cleanReportsNoContextWhenUnused() async {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "unused"))
        let settings = PipelineSettings(contextTerms: ["Kubernetes"])
        let result = await pipeline.clean("Let's grab lunch tomorrow.", settings: settings)
        #expect(!result.usedContext)
    }

    @Test("clean(_:settings:) reports usedContext false when contextTerms is empty")
    func cleanReportsNoContextWhenEmpty() async {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "unused"))
        let result = await pipeline.clean("Send this to Sioban please.", settings: PipelineSettings())
        #expect(!result.usedContext)
    }
}
