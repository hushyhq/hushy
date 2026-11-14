import Testing
@testable import MurmurCore

@Suite("VocabularyContext")
struct VocabularyContextTests {
    @Test("builds terms from dictionary entries with sounds-like as aliases")
    func buildsFromDictionary() {
        let entries = [
            DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties", "cooper nettys"]),
            DictionaryEntry(term: "Priya", soundsLike: ["pria"]),
        ]
        let vocabulary = VocabularyContext.from(dictionary: entries)
        #expect(vocabulary.terms.count == 2)
        #expect(vocabulary.terms[0].text == "Kubernetes")
        #expect(vocabulary.terms[0].aliases == ["cooper netties", "cooper nettys"])
        #expect(!vocabulary.isEmpty)
    }

    @Test("skips entries with an empty term")
    func skipsEmptyTerms() {
        let entries = [DictionaryEntry(term: "   ", soundsLike: ["x"]), DictionaryEntry(term: "Figma")]
        let vocabulary = VocabularyContext.from(dictionary: entries)
        #expect(vocabulary.terms.count == 1)
        #expect(vocabulary.terms[0].text == "Figma")
    }

    @Test("empty dictionary produces an empty vocabulary")
    func emptyDictionaryIsEmpty() {
        #expect(VocabularyContext.from(dictionary: []).isEmpty)
        #expect(VocabularyContext.empty.isEmpty)
    }

    @Test("built-in brand terms are appended after user terms at ASR assembly")
    func builtInsAfterUserTerms() {
        let settings = PipelineSettings(personalizer: Personalizer(dictionary: [DictionaryEntry(term: "Priya")]))
        #expect(settings.vocabulary.terms.map(\.text) == ["Priya", "Hushy", "tryhushy.com"])
        #expect(settings.vocabulary.terms[1].aliases == ["Hushi", "Husshy", "Hashi"])
    }

    @Test("trims whitespace from terms and aliases")
    func trimsWhitespace() {
        let entries = [DictionaryEntry(term: "  Figma  ", soundsLike: [" fig ma ", ""])]
        let vocabulary = VocabularyContext.from(dictionary: entries)
        #expect(vocabulary.terms[0].text == "Figma")
        #expect(vocabulary.terms[0].aliases == ["fig ma"])
    }
}

@Suite("VocabularyBoostingLatency")
struct VocabularyBoostingLatencyTests {
    @Test("reports the difference between boosted and base timing")
    func reportsAddedTime() {
        let latency = VocabularyBoostingLatency(baseMs: 100, boostedMs: 140)
        #expect(latency.addedMs == 40)
    }

    @Test("never reports a negative added time from timer noise")
    func clampsNegative() {
        let latency = VocabularyBoostingLatency(baseMs: 140, boostedMs: 138)
        #expect(latency.addedMs == 0)
    }
}

@Suite("Transcriber default vocabulary conformance")
struct TranscriberDefaultVocabularyTests {
    private struct PlainTranscriber: Transcriber {
        func transcribe(_ samples: [Float]) async throws -> String { "plain" }
    }

    @Test("falls back to the non-vocabulary overload when a conformer doesn't override it")
    func fallsBackToPlain() async throws {
        let transcriber = PlainTranscriber()
        let text = try await transcriber.transcribe([0, 0, 0], vocabulary: .from(dictionary: [DictionaryEntry(term: "X")]))
        #expect(text == "plain")
    }
}

/// Actor-backed capture box so the capturing transcriber below stays `Sendable` under Swift 6
/// strict concurrency (a plain `var` captured by a `@Sendable` closure is rejected).
private actor VocabularyBox {
    private(set) var value: VocabularyContext?
    func record(_ vocabulary: VocabularyContext) { value = vocabulary }
}

@Suite("DictationPipeline vocabulary wiring")
struct DictationPipelineVocabularyTests {
    private struct CapturingTranscriber: Transcriber {
        let box: VocabularyBox
        func transcribe(_ samples: [Float]) async throws -> String { "hello" }
        func transcribe(_ samples: [Float], vocabulary: VocabularyContext) async throws -> String {
            await box.record(vocabulary)
            return "hello"
        }
    }

    @Test("run() passes the personalizer's dictionary as vocabulary")
    func passesVocabularyFromPersonalizer() async throws {
        let box = VocabularyBox()
        let pipeline = DictationPipeline(transcriber: CapturingTranscriber(box: box))
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "Priya")])
        _ = try await pipeline.run(samples: [Float](repeating: 0, count: 16_000), settings: PipelineSettings(personalizer: personalizer))
        let seen = await box.value
        #expect(seen?.terms.map(\.text) == ["Priya", "Hushy", "tryhushy.com"])
    }

    @Test("transcribeRaw defaults to an empty vocabulary")
    func transcribeRawDefaultsEmpty() async throws {
        let box = VocabularyBox()
        let pipeline = DictationPipeline(transcriber: CapturingTranscriber(box: box))
        _ = try await pipeline.transcribeRaw([Float](repeating: 0, count: 16_000))
        let seen = await box.value
        #expect(seen?.isEmpty == true)
    }

    @Test("transcribeRaw forwards an explicit vocabulary")
    func transcribeRawForwardsVocabulary() async throws {
        let box = VocabularyBox()
        let pipeline = DictationPipeline(transcriber: CapturingTranscriber(box: box))
        let vocabulary = VocabularyContext.from(dictionary: [DictionaryEntry(term: "Kubernetes")])
        _ = try await pipeline.transcribeRaw([Float](repeating: 0, count: 16_000), vocabulary: vocabulary)
        let seen = await box.value
        #expect(seen?.terms.map(\.text) == ["Kubernetes"])
    }
}
