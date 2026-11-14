import Foundation
import Testing
@testable import MurmurCore

/// A dictation that is only an address stays as an address is written: lower case, no full stop, in every context and
/// whatever stage touched it last. Invented addresses only.
@Suite("Lone address", .timeLimit(.minutes(1)))
struct LoneAddressTests {
    private static let lone: [(String, String)] = [
        ("Jimmylord.com.", "jimmylord.com"),
        ("jimmylord.com", "jimmylord.com"),
        ("Jimmylord.com!", "jimmylord.com"),
        ("Mail.example.org.", "mail.example.org"),
        ("Example.com/pricing.", "example.com/pricing"),
        ("Www.miraholt.com", "www.miraholt.com"),
        ("https://Example.com/docs.", "https://example.com/docs"),
        ("Jordan@example.com.", "jordan@example.com"),
    ]

    @Test("an address on its own loses the capital and the full stop", arguments: lone.indices)
    func settlesALoneAddress(index: Int) {
        let (written, expected) = Self.lone[index]
        #expect(LoneAddress.settle(written) == expected)
    }

    @Test("an address with other words around it is left to the other stages")
    func otherTextIsUntouched() {
        for text in ["Go to example.com.", "Example.com is down.", "Send it to jordan@example.com please.",
                     "Jimmy lord.", "Version 1.5.", "Okay.", "", "example.com and example.org"] {
            #expect(LoneAddress.settle(text) == text, "\(text)")
        }
    }

    @Test("capitals inside an address, and a spelling the person's Dictionary has, are kept")
    func spellingIsKept() {
        #expect(LoneAddress.settle("GitHub.com.") == "GitHub.com")
        #expect(LoneAddress.settle("Hushy.app.", keepingSpellingOf: ["Hushy.app"]) == "Hushy.app")
        #expect(LoneAddress.settle("Hushy.app.") == "hushy.app")
    }

    @Test("what the rules and the model write is settled at both levels", arguments: [CleanupLevel.clean, .polished])
    func throughTheCleaner(level: CleanupLevel) async {
        for (spoken, answer, expected) in [
            ("jimmylord dot com", "Jimmylord.com.", "jimmylord.com"),
            ("mail dot example dot org", "Mail.example.org.", "mail.example.org"),
            ("example dot com slash pricing", "Example.com/pricing.", "example.com/pricing"),
            ("go to example dot com", "Go to example.com.", "Go to example.com."),
        ] {
            let model = FixedAnswer(json: "{\"text\": \"\(answer)\"}")
            let output = await SmartCleaner(model: model, health: ModelHealth()).clean(spoken, options: CleanupOptions(level: level))
            #expect(output.text == expected, "\(spoken) -> \(output.text)")
        }
    }

    @Test("the rules alone settle it too")
    func rulesOnly() async {
        let output = await SmartCleaner(model: NullLanguageModel(), health: ModelHealth())
            .clean("Jimmylord.com.", options: CleanupOptions(level: .clean), strategy: .rules)
        #expect(output.text == "jimmylord.com")
    }

    @Test("a tone and layout step cannot put the capital or the full stop back", arguments: [StyleContext.email, .workMessages, .other])
    func styleCannotUndoIt(context: StyleContext) async {
        for (spoken, answer, expected) in [
            ("jimmylord dot com", "Jimmylord.com.", "jimmylord.com"),
            ("mail dot example dot org slash pricing", "Mail.example.org/pricing.", "mail.example.org/pricing"),
        ] {
            let model = FixedAnswer(json: "{\"text\": \"\(answer)\"}")
            let pipeline = DictationPipeline(transcriber: NoSpeech(), cleaner: SmartCleaner(model: model, health: ModelHealth()))
            let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: .polished), style: (context, .formal), tone: .professional)
            let result = await pipeline.clean(spoken, settings: settings)
            #expect(result.text == expected, "\(context): \(spoken) -> \(result.text)")
        }
    }

    @Test("as spoken keeps what was heard")
    func verbatimIsLeftAlone() async {
        let output = await SmartCleaner(model: NullLanguageModel(), health: ModelHealth())
            .clean("Jimmylord.com.", options: CleanupOptions(level: .verbatim), strategy: .rules)
        #expect(output.text.hasSuffix("."))
    }
}

private final class FixedAnswer: LanguageModel {
    private let json: String
    init(json: String) { self.json = json }
    var identifier: String { "fixed" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String { json }
}

private struct NoSpeech: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}
