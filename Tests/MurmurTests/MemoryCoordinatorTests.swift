import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The shadow block around one dictation: prepared at key-down, finished after recognition,
/// never waited for. A folder of its own per test; every name is invented.
@MainActor
@Suite("Memory coordinator")
struct MemoryCoordinatorTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-memory-\(UUID())")
    private let app = "app.quillpad.mail"

    private func coordinator() async throws -> MemoryCoordinator {
        let memory = MemoryStore(root: root)
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria"))
        return MemoryCoordinator(memory: memory)
    }

    @Test("with no preparation there is no block, and the reason says nothing was prepared")
    func missedPrepare() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shadow = try await coordinator().finish(transcript: "ask Veloria")
        #expect(shadow.block == nil)
        #expect(!shadow.ready)
        #expect(shadow.reason == .notPrepared)
        #expect(shadow.prepareMs == 0)
    }

    @Test("a preparation still running when recognition ends is skipped as slow, and never reaches the next dictation")
    func slowPrepareIsSkipped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await coordinator()
        // The task cannot have run yet: this test holds the main actor until the next await.
        let task = coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true)
        let early = coordinator.finish(transcript: "ask Veloria")
        #expect(early.block == nil)
        #expect(!early.ready)
        #expect(early.reason == .slow)
        await task.value
        let late = coordinator.finish(transcript: "ask Veloria")
        #expect(late.block == nil)
        #expect(late.reason == .notPrepared)
    }

    @Test("a finished preparation gives the block once, and its lines are kept as the last used")
    func preparedBlockIsUsedOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await coordinator()
        #expect(coordinator.lastUsed == nil)
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true).value
        let shadow = coordinator.finish(transcript: "ask Veloria")
        #expect(shadow.ready)
        #expect(shadow.reason == .ok)
        #expect(shadow.block?.terms == ["Veloria"])
        #expect(shadow.block?.usedLines == 1)
        #expect(coordinator.lastUsed?.block.render() == "About this person\nWords they use: Veloria")
        // Kept in memory only: nothing about it is in the folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["terms.md"])
        let second = coordinator.finish(transcript: "ask Veloria")
        #expect(second.block == nil)
        #expect(coordinator.lastUsed == nil, "the last dictation used no lines")
    }

    @Test("cancel drops a finished preparation and one still running")
    func cancel() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await coordinator()
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true).value
        coordinator.cancel()
        #expect(!coordinator.finish(transcript: "ask Veloria").ready)
        let task = coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true)
        coordinator.cancel()
        await task.value
        #expect(coordinator.finish(transcript: "ask Veloria").reason == .notPrepared)
    }

    @Test("paused memory prepares but gives no block, and says paused")
    func paused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria"))
        try await memory.setPaused(true)
        let coordinator = MemoryCoordinator(memory: memory)
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true).value
        let shadow = coordinator.finish(transcript: "ask Veloria")
        #expect(shadow.ready)
        #expect(shadow.block == nil)
        #expect(shadow.reason == .paused)
        #expect(shadow.index == nil, "paused memory gives the pill's name offer nothing to go on")
    }

    @Test("the person's words go out with a prepared dictation for the pill's name offer, and not with a missed one")
    func wordsForTheNameOffer() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await coordinator()
        #expect(coordinator.finish(transcript: "ask Veloria").index == nil)
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true).value
        #expect(coordinator.finish(transcript: "ask Veloria").index?.terms.map(\.value) == ["Veloria"])
    }

    @Test("a folder that cannot be read is told apart from a slow preparation")
    func unreadableFolder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x2D, 0x20, 0xFF, 0xFE]).write(to: root.appendingPathComponent("terms.md"))
        let coordinator = MemoryCoordinator(memory: MemoryStore(root: root))
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true).value
        let shadow = coordinator.finish(transcript: "ask Veloria")
        #expect(!shadow.ready)
        #expect(shadow.block == nil)
        #expect(shadow.reason == .unreadable)
    }

    @Test("a failed copy of learned words is named, and what the folder holds is still read")
    func importFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // The folder's place is taken by a plain file, so nothing can be created inside it.
        try Data().write(to: root)
        let coordinator = MemoryCoordinator(memory: MemoryStore(root: root))
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: true).value
        let shadow = coordinator.finish(transcript: "ask Veloria")
        #expect(shadow.ready)
        #expect(shadow.reason == .importFailed)
        #expect(MemoryCoordinator.Reason.importFailed.rawValue == "import-failed")
    }

    @Test("old edits go at preparation only when the person chose a life for them, paused or not")
    func chosenLifePrunes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        let old = MemoryEntry(kind: .correction, value: "", appBundleID: app, createdAt: Date().addingTimeInterval(-40 * 86_400),
                              before: "meet at the gate on Friday", after: "meet at the gate on Monday")
        try await memory.add(old)
        try await memory.setPaused(true)
        let coordinator = MemoryCoordinator(memory: memory)
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: false).value
        #expect(try await memory.index().entries == [old])
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: false, editLife: .days90).value
        #expect(try await memory.index().entries == [old])
        await coordinator.prepare(app: app, history: try Store(), copiesLearnedWords: false, editLife: .days30).value
        #expect(try await memory.index().entries.isEmpty)
    }

    @Test("with Learn from my edits off a dictation writes nothing to the folder, and still reads it")
    func learningOffWritesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try Store()
        try await history.writer.write { db in
            var learned = LearnedItem(kind: .term, key: "nerula", value: "Nerula", status: .active)
            try learned.save(db)
        }
        let coordinator = MemoryCoordinator(memory: MemoryStore(root: root))
        await coordinator.prepare(app: app, history: history, copiesLearnedWords: false).value
        let off = coordinator.finish(transcript: "ask Nerula")
        #expect(off.ready)
        // Existing active terms are recalled directly without copying them into Memory.
        #expect(off.block?.terms == ["Nerula"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // On again, the one-time copy happens and the word is there.
        await coordinator.prepare(app: app, history: history, copiesLearnedWords: true).value
        #expect(coordinator.finish(transcript: "ask Nerula").block?.terms == ["Nerula"])
        // Off again, what is in the folder is still read: reading is the Pause switch's business.
        await coordinator.prepare(app: app, history: history, copiesLearnedWords: false).value
        #expect(coordinator.finish(transcript: "ask Nerula").block?.terms == ["Nerula"])
    }
}
