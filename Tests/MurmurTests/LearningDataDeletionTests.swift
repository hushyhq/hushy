import Foundation
import GRDB
import MurmurCore
import Testing
@testable import Murmur

/// "Delete learning data", from the button's own call down to the database and the memory
/// folder. The database is in memory and the folder temporary; every word is invented.
@Suite("Delete learning data")
@MainActor
struct LearningDataDeletionTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-memory-\(UUID())")
    private let app = "app.quillpad.mail"

    @Test("the button removes every learned word, note and pair, keeps what the person typed and the Forgotten list, and nothing comes back")
    func wholePath() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store()
        try await store.writer.write { db in
            var veloria = LearnedItem(kind: .term, key: "veloria", value: "Veloria", heardAs: ["Valoria"], status: .active)
            var savara = LearnedItem(kind: .term, key: "savara", value: "Savara", status: .forgotten)
            var habit = LearnedItem(kind: .styleSignal, key: "format:lowercased", value: "format:lowercased", status: .active)
            try veloria.save(db)
            try savara.save(db)
            try habit.save(db)
        }
        let memory = MemoryStore(root: root)
        let context = LearningContext(appBundleID: app)
        // The folder as a build with memory leaves it: the copied words, things learned since, and the person's own.
        try await memory.importLegacy(from: store)
        try await memory.learn(MemoryEntry(kind: .term, value: "Tavren Ridge"), context: context)
        try await memory.learn(MemoryEntry(kind: .style, value: "learned: lower case", appBundleID: app), context: context)
        try await memory.learn(MemoryEntry(kind: .correction, value: "", appBundleID: app, before: "meet at Tarrow Rij", after: "meet at Tavren Ridge"),
                               context: context)
        try await memory.add(MemoryEntry(kind: .term, value: "Nerula"))
        try await memory.add(MemoryEntry(kind: .profile, value: "typed: short sentences"))
        #expect(try await memory.index().entries.count == 7)

        let library = Library(store: store)
        let review = LearnedReview(actions: .live(library, memory: memory))
        // What both "Delete learning data" buttons call.
        review.deleteAllLearningData()
        await library.learningDeletion?.value

        #expect(try store.learnedItems().isEmpty)
        var index = try await memory.index()
        #expect(index.entries.map(\.value).sorted() == ["Nerula", "Savara", "typed: short sentences"])
        #expect(index.terms.map(\.value) == ["Nerula"])
        #expect(index.forgottenKeys == ["savara"])
        #expect(index.correctionsByApp.isEmpty)
        let files = try ["terms.md", "corrections.md", "style/\(app).md"].map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        for word in ["Veloria", "Valoria", "Tavren", "Tarrow", "lower case"] {
            #expect(!files.contains { $0.contains(word) })
        }

        // The next dictation reads memory with the copy of learned words allowed: nothing returns.
        let coordinator = MemoryCoordinator(memory: memory)
        await coordinator.prepare(app: app, history: store, copiesLearnedWords: true).value
        #expect(coordinator.finish(transcript: "ask Veloria about Tavren Ridge and Nerula").block?.terms == ["Nerula"])
        index = try await MemoryStore(root: root).index()
        #expect(index.entries.map(\.value).sorted() == ["Nerula", "Savara", "typed: short sentences"])
    }

    @Test("with no memory folder the button makes none, so the first copy of learned words can still happen later")
    func noFolder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(store: try Store())
        await library.deleteAllLearningData(memory: MemoryStore(root: root)).value
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
