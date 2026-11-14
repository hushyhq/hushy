import Foundation
import Testing
import GRDB
@testable import MurmurCore

@Suite struct KeepHeardCoreTests {
    @Test func freshRevertReactivatesForgottenPair() throws {
        let store = try Store()
        let swap = VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)
        let revert = Revert(swap: swap, typed: "codec")
        let entry = try #require(store.recordReverts([revert], app: "app.mail").first)
        try store.forgetKeepHeard(id: #require(entry.id))
        let record = try store.reportCorrections(CorrectionCapture(dictationID: 2, appBundleID: "app.mail",
            capturedAt: Date(), events: [], reverts: [revert]))
        #expect(record.keptHeard == 1)
        #expect(record.reactivatedHeard == 1)
        let diagnosis = LearningDiagnosis(bundleID: "app.mail", outcome: .kept(items: record.keptHeard, reactivated: record.reactivatedHeard))
        #expect(diagnosis.line.contains("reactivated=1"))
        #expect(try store.keepHeardSet(for: "app.mail").blocks(heardKey: "codec", writtenKey: "codex"))
        #expect(try store.keepHeardEntries().first?.observations == 1)
    }

    @Test(arguments: [
        ("Ask Codex, then continue", "Ask codec, then continue"),
        ("Ask Codex.", "Ask codec."),
        ("Ask Codex?", "Ask codec?"),
        ("Ask “Codex” today", "Ask “codec” today"),
        ("Ask Codex’s owner", "Ask codec’s owner"),
        ("Ask Codex's owner", "Ask codec's owner"),
    ])
    func blockedSwapPreservesModelPunctuation(_ model: String, _ expected: String) {
        let keep = KeepHeardSet(swaps: [.init(heard: "codec", written: "Codex", source: .dictionaryAlias)])
        let result = VocabularySwaps.restore(from: "ask codec then continue", to: model, source: .dictionaryAlias, keeping: keep)
        #expect(result.text == expected)
    }

    @Test func releaseRestoresOnlyBlockedSwap() {
        let keep = KeepHeardSet(swaps: [VocabularySwap(heard: "text", written: "Next", source: .boost)])
        let result = ReleaseSwaps.apply(TranscriptionResult(text: "the Next field for Siobhan", unboosted: "the text field for Shivan"), keep: keep)
        #expect(result.text == "the text field for Siobhan")
        #expect(result.swaps.map(\.written) == ["Siobhan"])
        #expect(ReleaseSwaps.apply(TranscriptionResult(text: result.text), keep: keep).text == result.text)
    }

    @Test func unchangedTextKeepsWhitespaceAndLongRunsAreIgnored() {
        #expect(VocabularySwaps.restore(from: "hello  world\n", to: "hello  world\n", source: .boost, keeping: .empty).text == "hello  world\n")
        #expect(VocabularySwaps.diff(from: "one two three four", to: "five six seven eight", source: .boost).isEmpty)
    }

    @Test func revertSeparatesFromRewrite() {
        let swap = VocabularySwap(heard: "text", written: "Next", source: .boost)
        let alignment = CorrectionAlignment.align(inserted: ["paste", "the", "Next", "here"], edited: ["paste", "the", "text", "here"])
        let result = RevertDetector.split(alignment, swaps: [swap])
        #expect(result.reverts.map(\.swap) == [swap])
        #expect(result.rest.edits.isEmpty)
        #expect(RevertDetector.split(alignment, swaps: []).reverts.isEmpty)
    }

    @Test func addOnlyMigrationKeepsExistingRows() throws {
        let queue = try DatabaseQueue()
        try Store.migrator.migrate(queue, upTo: "v22-dictation-time-split")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dictation (createdAt, rawText, text, durationSeconds, wordCount, latencyMs, status)
                VALUES (?, 'hello team', 'Hello team', 1, 2, 10, 'inserted')
                """, arguments: [Date()])
        }
        try Store.migrator.migrate(queue)
        try queue.read { db in
            let hasTable = try db.tableExists("keepHeard")
            let dictations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictation")
            let entries = try KeepHeardEntry.fetchCount(db)
            #expect(hasTable)
            #expect(dictations == 1)
            #expect(entries == 0)
        }
    }

    @Test func appScopeForgetRestoreAndDelete() throws {
        let store = try Store()
        let swap = VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)
        let revert = Revert(swap: swap, typed: "codec")
        #expect(try store.recordReverts([revert], app: "app.mail").count == 1)
        #expect(try store.keepHeardSet(for: "app.mail").blocks(heardKey: "codec", writtenKey: "codex"))
        #expect(try !store.keepHeardSet(for: "app.chat").blocks(heardKey: "codec", writtenKey: "codex"))
        let entry = try #require(store.keepHeardEntries().first)
        let id = try #require(entry.id)
        try store.forgetKeepHeard(id: id)
        #expect(try store.recordReverts([revert], app: "app.mail").count == 1)
        try store.restoreKeepHeard(entry)
        #expect(try store.keepHeardSet(for: "app.mail").blocks(heardKey: "codec", writtenKey: "codex"))
        try store.deleteAllLearnedItems()
        #expect(try store.keepHeardEntries().isEmpty)
    }

    @Test func dictionaryAndScreenFixersRespectPairAndControls() async {
        let swap = VocabularySwap(heard: "vellics", written: "Vellix", source: .dictionaryName)
        let keep = KeepHeardSet(swaps: [swap])
        let settings = PipelineSettings(personalizer: Personalizer(dictionary: [DictionaryEntry(term: "Vellix")]),
            contextTerms: ["Vellix"], keepHeard: keep)
        #expect(DictionaryTermFixer.fixNames("ask vellics to review", settings: settings) == "ask vellics to review")
        let pipeline = DictationPipeline(transcriber: NoSpeech())
        let result = await pipeline.clean("ask vellics to review", settings: settings, strategy: .rules)
        #expect(!result.text.contains("Vellix"))
        #expect(result.vocabularySwaps.isEmpty)
        let control = "the build is green"
        let plain = await pipeline.clean(control, settings: PipelineSettings(), strategy: .rules)
        let blocked = await pipeline.clean(control, settings: settings, strategy: .rules)
        #expect(plain.text == blocked.text)
        let installed = PipelineSettings(installedApps: [InstalledAppInfo(bundleID: "example.assistant", name: "Claude", declaredCategory: nil)],
            keepHeard: KeepHeardSet(swaps: [VocabularySwap(heard: "cloud", written: "Claude", source: .installedName)]))
        #expect(InstalledNameFixer.fix("ask cloud to summarize", settings: installed) == "ask cloud to summarize")
    }

    private struct NoSpeech: Transcriber {
        func transcribe(_ samples: [Float]) async throws -> String { "" }
    }

    @Test func modelCannotReintroduceRejectedVocabulary() async {
        let swap = VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: .polished),
            personalizer: Personalizer(dictionary: [DictionaryEntry(term: "Codex", soundsLike: ["codec"])]),
            keepHeard: KeepHeardSet(swaps: [swap]))
        let pipeline = DictationPipeline(transcriber: NoSpeech(), cleaner: SmartCleaner(model: ReintroducingModel()))
        let result = await pipeline.clean("Please ask codec to review the draft today.", settings: settings)
        #expect(result.usedModel)
        #expect(result.text.contains("codec"))
        #expect(!result.text.contains("Codex"))
    }

    private struct ReintroducingModel: LanguageModel {
        var identifier: String { "keep-heard-test" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec,
                     options: LanguageModelOptions) async throws -> String {
            "{\"text\":\"Please ask Codex to review the draft today.\"}"
        }
    }

    @Test func aliasRespectsBlockedPair() {
        let swap = VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "Codex", soundsLike: ["codec"])], keep: KeepHeardSet(swaps: [swap]))
        #expect(personalizer.apply("ask codec to refactor this").text == "ask codec to refactor this")
        #expect(personalizer.aliasSwaps(in: "ask codec to refactor this").isEmpty)
    }
}
