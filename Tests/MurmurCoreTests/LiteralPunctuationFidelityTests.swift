import Testing
@testable import MurmurCore

@Suite("Literal punctuation fidelity")
struct LiteralPunctuationFidelityTests {
    @Test func proseKeepsClauseAndFieldSemicolons() {
        #expect(Punctuation.tidy("we checked the logs; nothing changed.") == "We checked the logs; nothing changed.")
        #expect(Punctuation.tidy("Owner: Maya; status: queued; priority: low.") == "Owner: Maya; status: queued; priority: low.")
    }

    @Test func finalTidyingKeepsEllipsesAndBacktickBytes() {
        #expect(Punctuation.tidy("maybe later...") == "Maybe later...")
        #expect(Punctuation.tidy("use `value  =  1;` here") == "Use `value  =  1;` here")
    }

    @Test func correctionCuesSupportDashSeparatorsWithoutChangingLiteralDashes() {
        #expect(SelfCorrection.apply("The visit is on Monday—actually, Tuesday.").text == "The visit is on Tuesday.")
        #expect(SelfCorrection.apply("Set it to 8—no, 9.").text == "Set it to 9.")
        #expect(SelfCorrection.apply("The booking is on Wednesday—sorry, I mean Saturday.").text == "The booking is on Saturday.")
        #expect(SelfCorrection.apply("The plan—actually quite useful—stays unchanged.").text == "The plan—actually quite useful—stays unchanged.")
    }

    @Test func codeFormattingDoesNotTreatSyntaxAsSentencePunctuation() {
        for text in ["let value = 7;", "UPDATE queue SET ready = 1;", "call(a, b); next();", "value ?? fallback", "    return value;  ", #"pattern = /\d+/;"#] {
            #expect(Punctuation.tidy(text, capitalize: false, preserveSyntax: true) == text)
            let result = TextCleaner(options: CleanupOptions(level: .verbatim, voiceCommandsEnabled: false, isCodeContext: true)).clean(text)
            #expect(result.text == text)
        }
    }

    @Test func codeStringLiteralsKeepTheirContentsDuringOrdinaryCleanup() {
        for raw in [#"let message = "one two";"#, #"let filler = "um";"#, #"let pattern = /\d+/;"#] {
            let result = TextCleaner(options: CleanupOptions(level: .clean, voiceCommandsEnabled: false, isCodeContext: true)).clean(raw)
            #expect(result.text == raw)
        }
    }

    @Test func codeFallbackKeepsSyntaxCasingAndWhitespace() {
        let draft = "    return value;  "
        for reason in ["timeout", "changed code-context text", "dropped content words"] {
            #expect(SmartCleaner.rulesFallback(reason: reason, draft: draft, preserveSyntax: true) == draft)
        }
    }

    @Test func finalPipelineDoesNotStyleCodeEvenIfCallerSuppliesStyle() async {
        let raw = "let value = 7;"
        let cleaner = SmartCleaner(model: CodeRewriteModel(), health: ModelHealth())
        let pipeline = DictationPipeline(transcriber: CodeNoAudioTranscriber(), cleaner: cleaner)
        let result = await pipeline.clean(raw, settings: PipelineSettings(
            cleanupOptions: CleanupOptions(level: .clean, voiceCommandsEnabled: false, isCodeContext: true),
            style: (context: .other, style: .formal)), strategy: .rules)
        #expect(result.text == raw)
    }

    @Test func modelCannotRewriteCodeContextDraft() async {
        let cleaner = SmartCleaner(model: CodeRewriteModel(), health: ModelHealth())
        let output = await cleaner.clean("let value = 7;",
            options: CleanupOptions(level: .clean, voiceCommandsEnabled: false, isCodeContext: true),
            strategy: .model, incremental: false)
        #expect(!output.usedModel)
        #expect(output.rejection == "changed code-context text")
        #expect(output.text == "let value = 7;")
    }
}

private struct CodeRewriteModel: LanguageModel {
    var identifier: String { "synthetic-code-rewrite" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        #"{"text":"let value = 7,"}"#
    }
}

private struct CodeNoAudioTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}
