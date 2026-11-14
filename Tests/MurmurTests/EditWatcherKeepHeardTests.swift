import Foundation
import MurmurCore
import Testing
@testable import Murmur

@Suite("Edit watcher keeps heard words")
@MainActor
struct EditWatcherKeepHeardTests {
    @Test func revertStopsSwapAndDoesNotLearnBackwards() async throws {
        let suite = "job125-keep-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = LearningPolicy(autoActivateTerms: defaults.object(forKey: "feature.autoActivateLearnedTerms") as? Bool ?? true)
        let store = try Store()
        let pasted = "please ask Codex to check the build"
        let typed = "please ask codec to check the build"
        let app = "app.quillpad.mail"
        let id = try #require(store.save(Dictation(rawText: pasted, text: pasted, appBundleID: app, durationSeconds: 1)).id)
        var diagnoses: [LearningDiagnosis] = []
        let input = EditWatcher.LearningInput(raw: pasted, context: LearningContext(appBundleID: app),
                                             swaps: [.init(heard: "codec", written: "Codex", source: .dictionaryAlias)], policy: policy)
        await EditWatcher.observe(inserted: pasted, dictationID: id, store: store, learning: input,
                                  report: { diagnoses.append($0) },
                                  readField: { .init(fieldValue: typed, coverage: .observed) }, sleep: { _ in }).value
        #expect(try store.learnedItems().isEmpty)
        #expect(try store.keepHeardSet(for: app).blocks(heardKey: "codec", writtenKey: "codex"))
        #expect(try !store.keepHeardSet(for: "app.quillpad.chat").blocks(heardKey: "codec", writtenKey: "codex"))
        #expect(diagnoses.first?.line.contains("result=kept-heard items=1") == true)
        #expect(diagnoses.first?.line.contains("codec") == false)
        let dictionary = [DictionaryEntry(term: "Codex", soundsLike: ["codec"])]
        let here = Personalizer(dictionary: dictionary, keep: try store.keepHeardSet(for: app))
        let elsewhere = Personalizer(dictionary: dictionary, keep: try store.keepHeardSet(for: "app.quillpad.chat"))
        #expect(here.apply("please ask codec for help").text == "please ask codec for help")
        #expect(elsewhere.apply("please ask codec for help").text == "please ask Codex for help")

    }

    @Test func unrelatedRewriteTeachesNothing() async throws {
        let suite = "job125-keep-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = LearningPolicy(autoActivateTerms: defaults.object(forKey: "feature.autoActivateLearnedTerms") as? Bool ?? true)
        let store = try Store()
        let pasted = "please send the report before noon today"
        let id = try #require(store.save(Dictation(rawText: pasted, text: pasted, durationSeconds: 1)).id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("job125-rewrite-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        let input = EditWatcher.LearningInput(raw: pasted, context: LearningContext(appBundleID: "app.quillpad.mail"),
                                             swaps: [.init(heard: "codec", written: "Codex", source: .dictionaryAlias)], policy: policy)
        var looks = 0
        await EditWatcher.observe(inserted: pasted, dictationID: id, store: store, learning: input, memory: memory,
                                  report: { _ in }, readField: {
            looks += 1
            return .init(fieldValue: looks <= 2 ? pasted : "please send the report before noon tomorrow", coverage: .observed)
        }, sleep: { _ in }).value
        #expect(try store.learnedItems().isEmpty)
        #expect(try store.keepHeardEntries().isEmpty)
        #expect(try await memory.index().entries.isEmpty)
    }
}

@Suite("Learning snapshots for retry")
@MainActor
struct EditLearningPreparationTests {
    @Test func keyDownReturnsBeforeDatabaseSnapshotIsReady() async throws {
        let store = try Store()
        let swap = VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)
        try store.recordReverts([Revert(swap: swap, typed: "codec")], app: "app.mail")
        let prepared = EditLearningPreparation.capture(store: store, app: "app.mail")
        #expect(prepared.keep.isEmpty)
        #expect(prepared.learned == nil)
        await prepared.task?.value
        #expect(prepared.keep.blocks(heardKey: "codec", writtenKey: "codex"))
        #expect(prepared.learned != nil)
    }

    @Test func retryUsesSavedAppRatherThanCurrentApp() throws {
        let rig = try DictationRecoveryControllerTests.Harness()
        let swap = VocabularySwap(heard: "codec", written: "Codex", source: .dictionaryAlias)
        try rig.store.recordReverts([Revert(swap: swap, typed: "codec")], app: "app.quillpad.mail")
        let saved = Dictation(rawText: "ask codec", text: "ask codec", appBundleID: "app.quillpad.mail", durationSeconds: 1)
        let retry = rig.controller.retrySettings(for: saved)
        #expect(retry.keepHeard.blocks(heardKey: "codec", writtenKey: "codex"))
        #expect(retry.personalizer.keep.blocks(heardKey: "codec", writtenKey: "codex"))
        let other = Dictation(rawText: "ask codec", text: "ask codec", appBundleID: "app.quillpad.chat", durationSeconds: 1)
        #expect(!rig.controller.retrySettings(for: other).keepHeard.blocks(heardKey: "codec", writtenKey: "codex"))
    }

    @Test func snapshotContainsLearnedOnlyContext() async throws {
        let store = try Store()
        try store.recordCorrections(CorrectionCapture(dictationID: 1, appBundleID: "app.quillpad.mail", capturedAt: Date(),
            events: [CorrectionEvent(kind: .asrTerm, before: "Velorria", after: "Veloria")], supportedKeys: ["veloria"]))
        let prepared = EditLearningPreparation.capture(store: store, app: "app.quillpad.mail")
        await prepared.task?.value
        let block = PersonBlockAssembler.finish(prepared.learned, transcript: "ask Velorria about the build")
        #expect(block?.terms == ["Veloria"])
        #expect(block?.profile == nil)
        #expect(block?.earlier.isEmpty != false)
        #expect(block?.edits.isEmpty != false)
    }
}
