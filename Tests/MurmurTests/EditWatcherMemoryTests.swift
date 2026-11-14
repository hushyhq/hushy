import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The edit watcher keeping the person's changes in memory: a pair when everything allows it,
/// nothing wherever learning is refused. Every sentence is invented; the folder is temporary.
@Suite("Edit watcher memory")
@MainActor
struct EditWatcherMemoryTests {
    private let app = "app.quillpad.mail"
    private let inserted = "we can meet at Tavren Rij on Friday after the review"
    private let fixed = "we can meet at Tavren Ridge on Friday after the review"
    private let around = (before: "Note for the Veloria crew:\n", after: "\nSigned, the Nerula desk")
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-memory-\(UUID())")

    private var file: URL { root.appendingPathComponent("corrections.md") }

    /// Watches one pasted dictation: the first two looks see it as pasted, the rest see `later`.
    @discardableResult
    private func watch(
        memory: MemoryStore?, context: LearningContext? = nil, later: String? = nil,
        coverage: DictationEditObservation.Coverage = .observed, store: Store? = nil,
        isStillAllowed: @escaping @MainActor () -> Bool = { true }, onLook: @escaping @MainActor (Int, Int64) -> Void = { _, _ in }
    ) async throws -> Store {
        let suite = "job125-memory-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = LearningPolicy(autoActivateTerms: defaults.object(forKey: "feature.autoActivateLearnedTerms") as? Bool ?? true)
        let store = try store ?? Store()
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, appBundleID: app, durationSeconds: 1)).id)
        let pasted = around.before + inserted + around.after
        let edited = later ?? around.before + fixed + around.after
        var looks = 0
        let input = EditWatcher.LearningInput(raw: inserted, context: context ?? LearningContext(appBundleID: app),
                                              evidence: TermEvidence(dictionary: [], screenTerms: ["Ridge"], appNames: []),
                                              isStillAllowed: isStillAllowed, policy: policy)
        await EditWatcher.observe(inserted: inserted, dictationID: id, store: store, learning: input, memory: memory, readField: {
            looks += 1
            onLook(looks, id)
            // `coverage` is what the third look says of the field's security; a look that is not `.observed` reads no text.
            guard looks != 3 || coverage == .observed else { return .init(fieldValue: nil, coverage: coverage) }
            return .init(fieldValue: looks <= 2 ? pasted : edited, coverage: .observed)
        }, sleep: { _ in }).value
        return store
    }

    private func kept(_ memory: MemoryStore) async throws -> [MemoryEntry] {
        try await memory.index().entries.filter { $0.kind == .correction }
    }

    @Test("a changed dictation is kept as a pair with its app and date, and nothing else from the field")
    func keepsThePair() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        let began = Date().addingTimeInterval(-1)
        try await watch(memory: memory)
        let pairs = try await kept(memory)
        let pair = try #require(pairs.first)
        #expect(pairs.count == 1)
        #expect(pair.before == "meet at Tavren Rij on Friday after")
        #expect(pair.after == "meet at Tavren Ridge on Friday after")
        #expect(pair.appBundleID == app)
        #expect(pair.createdAt >= began && pair.createdAt <= Date())
        let text = try String(contentsOf: file, encoding: .utf8)
        for word in ["Note", "Veloria", "crew", "Signed", "Nerula", "desk"] { #expect(!text.contains(word)) }
    }

    @Test("a mixed term fix and change of mind never teaches the meaning change")
    func ignoresMixedRewrite() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        try await watch(memory: memory, later: around.before + fixed.replacingOccurrences(of: "Friday", with: "Saturday") + around.after)
        #expect(try await kept(memory).isEmpty)
    }

    @Test("with the memory flag off there is no store, and no file is made")
    func flagOff() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let without = try await watch(memory: nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // The learned-item path takes the same from an edit with memory there or not.
        let with = try await watch(memory: MemoryStore(root: root))
        #expect(try with.learnedItems().map(\.key) == without.learnedItems().map(\.key))
        #expect(try with.editObservation(forDictation: 1)?.verdict == .edited)
    }

    @Test("a secure field, an excluded app, code, and learning off each keep nothing")
    func refusals() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        try await watch(memory: memory, coverage: .secure)
        try await watch(memory: memory, context: LearningContext(appBundleID: app, excludedBundleIDs: [app]))
        try await watch(memory: memory, context: LearningContext(appBundleID: app, isCodeContext: true))
        try await watch(memory: memory, context: LearningContext(isEnabled: false, appBundleID: app))
        // Switched off while the watcher was waiting.
        try await watch(memory: memory, isStillAllowed: { false })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("while memory is paused nothing is kept")
    func paused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        try await memory.setPaused(true)
        try await watch(memory: memory)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("the same change to two dictations is kept once")
    func keptOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        try await watch(memory: memory)
        try await watch(memory: memory)
        #expect(try await kept(memory).count == 1)
    }

    @Test("a dictation deleted from History while it was watched leaves no pair")
    func deletedDictation() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        let store = try Store()
        try await watch(memory: memory, store: store, onLook: { look, _ in
            if look == 10 { try? store.deleteAllDictations() }
        })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("once the person has dictated again, later looks are not read as their change")
    func dictatedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        let store = try Store()
        // The next dictation lands before any look, so every look may hold its text.
        _ = try await watch(memory: memory, store: store, onLook: { look, _ in
            guard look == 1 else { return }
            _ = try? store.save(Dictation(createdAt: Date().addingTimeInterval(-60), rawText: "next", text: "next",
                                          appBundleID: "app.quillpad.mail", durationSeconds: 1))
        })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
