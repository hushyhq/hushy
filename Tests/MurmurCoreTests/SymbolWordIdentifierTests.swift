import Foundation
import Testing
@testable import MurmurCore

private struct StubTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float]) async throws -> String { text }
}

private struct StubModel: LanguageModel {
    let answer: String
    var identifier: String { "scripted-identifier" }
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

/// The whole-transcript (intent) model joins "node underscore env" into `NODE_ENV`. The word "underscore" is then spoken
/// material the answer holds as a character, not a word the model lost: no check may put it back as a word.
@Suite("Spoken symbol words inside identifiers")
struct SymbolWordIdentifierTests {
    private func run(_ raw: String, answer: String) async -> PipelineResult {
        let cleaner = SmartCleaner(model: StubModel(answer: answer), health: ModelHealth(), wholeTranscript: { true })
        let pipeline = DictationPipeline(transcriber: StubTranscriber(text: raw), cleaner: cleaner)
        return await pipeline.clean(raw, settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished)))
    }

    @Test("a joined identifier keeps its characters and gets no symbol word back",
          arguments: [
            ("Set node underscore env to production.", "Set NODE_ENV to production."),
            ("Add an index on user underscore id.", "Add an index on user_id."),
            ("Rename the variable to max underscore retries.", "Rename the variable to max_retries."),
            ("Set the cache underscore home variable.", "Set the CACHE_HOME variable."),
            ("The column is called created underscore at.", "The column is called created_at."),
            ("Pass the build dash id flag first.", "Pass the build-id flag first."),
          ])
    func joinedIdentifier(raw: String, answer: String) async {
        let result = await run(raw, answer: answer)
        #expect(result.text == answer, "rejection: \(String(describing: result.rejection))")
    }

    @Test("a word gap is still a hole, an identifier join is not")
    func gapVersusJoin() {
        let raw = "send the quarterly invoice to marta"
        #expect(!DroppedContent.lost(answer: "Send the invoice to Marta.", raw: raw).isEmpty)
        #expect(DroppedContent.lost(answer: "Set NODE_ENV now.", raw: "set node underscore env now").isEmpty)
    }

    @Test("the symbol word stays when the speaker means the word")
    func wordKept() async {
        for (raw, answer) in [
            ("Press the underscore key twice.", "Press the underscore key twice."),
            ("Add a dash of salt.", "Add a dash of salt."),
        ] {
            let result = await run(raw, answer: answer)
            #expect(result.text == answer, "rejection: \(String(describing: result.rejection))")
        }
    }
}
