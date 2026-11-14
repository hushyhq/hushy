import Foundation
import Testing
import MurmurCore
@testable import Murmur

@Suite("Edit watcher lifecycle")
@MainActor
struct EditWatcherLifecycleTests {
    let inserted = "The draft is ready."

    @Test("the eight-second kept verdict is terminal")
    func laterEdit() async throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, durationSeconds: 1)).id)
        var reads = 0
        let task = EditWatcher.observe(inserted: inserted, dictationID: id, store: store, readField: {
            reads += 1
            return .init(fieldValue: reads == 1 ? inserted : "The draft is ready now.", coverage: .observed)
        }, sleep: { _ in })
        await task.value
        #expect(reads == 1)
        #expect(try store.editObservation(forDictation: id)?.verdict == .kept)
        #expect(try store.recentDictations().first?.editState == .kept)
    }

    @Test("the verdict handler hears kept, edited and unreadable exactly once, and not at all when the watcher is cancelled")
    func verdictHandlerOncePerDictation() async throws {
        let store = try Store()
        var heard: [String] = []
        let handler: EditWatcher.VerdictHandler = { verdict, coverage, _ in heard.append("\(verdict.rawValue)/\(coverage.rawValue)") }
        for field in [(inserted, DictationEditObservation.Coverage.observed), ("The draft is ready now, thanks.", .observed), ("", .fieldUnreadable)] {
            let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, durationSeconds: 1)).id)
            await EditWatcher.observe(inserted: inserted, dictationID: id, store: store, onVerdict: handler, readField: {
                .init(fieldValue: field.1 == .fieldUnreadable ? nil : field.0, coverage: field.1)
            }, sleep: { _ in }).value
        }
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, durationSeconds: 1)).id)
        await EditWatcher.observe(inserted: inserted, dictationID: id, store: store, onVerdict: handler,
            readField: { .init(fieldValue: inserted, coverage: .observed) }, sleep: { _ in throw CancellationError() }).value
        #expect(heard.count == 3)
        #expect(heard.first == "kept/observed")
        #expect(heard.last == "unknown/fieldUnreadable")
        #expect(!heard[1].hasPrefix("unknown"))
    }

    @Test("the verdict handler is told how many words an edit changed, and none for anything that was not an edit")
    func verdictHandlerHearsSize() async throws {
        let store = try Store()
        let text = "Please send me the report on Monday morning before the meeting starts."
        var heard: [String] = []
        let handler: EditWatcher.VerdictHandler = { verdict, _, size in heard.append("\(verdict.rawValue)/\(size.rawValue)") }
        let fields: [String?] = [
            text,                                                                                    // kept
            "Hi Sam, " + text.replacingOccurrences(of: "Monday", with: "Tuesday") + " Thanks",       // one word, in a longer field
            text.replacingOccurrences(of: "report on Monday morning", with: "slides this afternoon"), // a few words
            "",                                                                                      // field cleared
            nil,                                                                                     // unreadable
        ]
        for field in fields {
            let id = try #require(store.save(Dictation(rawText: text, text: text, durationSeconds: 1)).id)
            await EditWatcher.observe(inserted: text, dictationID: id, store: store, onVerdict: handler, readField: {
                .init(fieldValue: field, coverage: field == nil ? .fieldUnreadable : .observed)
            }, sleep: { _ in }).value
        }
        #expect(heard == ["kept/none", "edited/words1to2", "edited/words3to10", "unknown/none", "unknown/none"])
    }

    @Test("sending later cannot erase the observed kept verdict")
    func clearedField() async throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, durationSeconds: 1)).id)
        var reads = 0
        await EditWatcher.observe(inserted: inserted, dictationID: id, store: store, readField: {
            reads += 1
            return .init(fieldValue: reads == 1 ? inserted : "", coverage: .observed)
        }, sleep: { _ in }).value
        #expect(try store.editObservation(forDictation: id)?.coverage == .observed)
        #expect(try store.recentDictations().first?.editState == .kept)
    }

    @Test("unreadable observation is terminal and never reads unrelated later text")
    func recovery() async throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, durationSeconds: 1)).id)
        var reads = 0
        await EditWatcher.observe(inserted: inserted, dictationID: id, store: store, readField: {
            reads += 1
            return reads == 1 ? .init(fieldValue: nil, coverage: .fieldUnreadable)
                : .init(fieldValue: inserted, coverage: .observed)
        }, sleep: { _ in }).value
        #expect(try store.editObservation(forDictation: id)?.verdict == .unknown)
        #expect(reads == 1)
    }

    @Test("sleep cancellation and deleted records prevent a field read")
    func cancelledOrDeleted() async throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, durationSeconds: 1)).id)
        var reads = 0
        let read: @MainActor () -> EditWatcher.ReadResult = {
            reads += 1
            return .init(fieldValue: inserted, coverage: .observed)
        }
        await EditWatcher.observe(inserted: inserted, dictationID: id, store: store,
            readField: read, sleep: { _ in throw CancellationError() }).value
        try store.deleteDictation(id: id)
        await EditWatcher.observe(inserted: inserted, dictationID: id, store: store,
            readField: read, sleep: { _ in }).value
        #expect(reads == 0)
        #expect(try store.editObservation(forDictation: id) == nil)
    }
    @Test("same-text retry invalidates the sleeping watcher")
    func sameTextRetry() async throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, durationSeconds: 1)).id)
        var reads = 0
        await EditWatcher.observe(inserted: inserted, dictationID: id, store: store, readField: {
            reads += 1
            return .init(fieldValue: inserted, coverage: .observed)
        }, sleep: { _ in
            try store.updateTranscription(id: id, rawText: inserted, text: inserted, status: .inserted)
        }).value
        #expect(reads == 0)
        #expect(try store.editObservation(forDictation: id)?.coverage == .notAttempted)
    }

    @Test("unknown observations and revoked learning never create correction evidence")
    func learningRefusal() async throws {
        let store = try Store()
        let original = "Please call Pria today."
        for refuse in [true, false] {
            let id = try #require(store.save(Dictation(rawText: original, text: original, durationSeconds: 1)).id)
            let input = EditWatcher.LearningInput(raw: original, context: LearningContext(), isStillAllowed: { !refuse })
            await EditWatcher.observe(inserted: original, dictationID: id, store: store, learning: input, readField: {
                .init(fieldValue: refuse ? "Please call Priya today." : "", coverage: .observed)
            }, sleep: { _ in }).value
        }
        #expect(try store.learnedItems().isEmpty)
    }

    @Test("confident first edits still create local correction evidence")
    func learnsFirstEdit() async throws {
        let store = try Store()
        let original = "Please call Pria today."
        let id = try #require(store.save(Dictation(rawText: original, text: original, durationSeconds: 1)).id)
        await EditWatcher.observe(inserted: original, dictationID: id, store: store,
            learning: .init(raw: original, context: LearningContext()), readField: {
                .init(fieldValue: "Please call Priya today.", coverage: .observed)
            }, sleep: { _ in }).value
        #expect(try store.editObservation(forDictation: id)?.verdict == .edited)
        #expect(try store.learnedItems().count == 1)
    }

}
