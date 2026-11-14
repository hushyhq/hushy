import Foundation
import Testing
@testable import MurmurCore

/// The person's changes in `corrections.md`: kept until deleted, never twice, and never where
/// learning is refused. Every sentence is invented.
@Suite("Person memory changes")
struct PersonMemoryChangesTests {
    private static let app = "app.quillpad.mail"
    private static let day: TimeInterval = 86_400

    private func change(_ before: String = "meet at Tarrow Rij on Friday", _ after: String = "meet at Tavren Ridge on Friday",
                        app: String? = PersonMemoryChangesTests.app, daysAgo: Double = 0) -> MemoryEntry {
        MemoryEntry(kind: .correction, value: "", appBundleID: app,
                    createdAt: TemporaryMemoryRoot.today.addingTimeInterval(-daysAgo * Self.day), before: before, after: after)
    }

    @Test("a pair survives the file: both sides, the app and the date, on one readable line")
    func roundTrip() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        var pair = change("she said \"noon\" <b>sharp</b>", "She said \"noon\", sharp --> maybe")
        #expect(try await root.store().learn(pair, context: LearningContext(appBundleID: Self.app)) == .kept(.written))
        // What learning keeps is marked as learned.
        pair.origin = .learned
        let read = try await MemoryStore(root: root.url).index().entries.filter { $0.kind == .correction }
        #expect(read == [pair])
        let line = try #require(try root.text("corrections.md").components(separatedBy: "\n").last)
        #expect(line.hasPrefix("- \"she said \"noon\" <b>sharp</b>\" → \"She said \"noon\", sharp --> maybe\" <!-- hushy:{"))
        #expect(line.contains("\"app\":\"app.quillpad.mail\""))
        #expect(line.contains("\"created\":\"2026-10-12T12:00:00Z\""))
    }

    @Test("the same change made again is one line with the later date; the same change in another app is its own")
    func noDuplicates() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let first = change(daysAgo: 5)
        #expect(try await memory.add(first) == .written)
        #expect(try await memory.learn(change(), context: LearningContext(appBundleID: Self.app)) == .kept(.merged))
        var kept = try await memory.index().entries.filter { $0.kind == .correction }
        #expect(kept.count == 1)
        #expect(kept.first?.id == first.id)
        #expect(kept.first?.createdAt == TemporaryMemoryRoot.today)
        #expect(try await memory.add(change(app: "app.lumen.notes")) == .written)
        #expect(try await memory.add(change("meet at Tarrow Rij on Friday", "meet at Tarrow Ridge on Friday")) == .written)
        kept = try await memory.index().entries.filter { $0.kind == .correction }
        #expect(kept.count == 3)
    }

    @Test("a secure field, an excluded app, a password manager, code, another language and learning off each write nothing")
    func refusalsWriteNothing() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let refused: [(LearningContext, LearningRefusal)] = [
            (LearningContext(isSecureField: true), .secureField),
            (LearningContext(appBundleID: Self.app, excludedBundleIDs: [Self.app]), .excludedApp),
            (LearningContext(isDenylistedApp: true), .denylistedApp),
            (LearningContext(isCodeContext: true), .codeContext),
            (LearningContext(detectedLanguage: "fr"), .nonEnglish),
            (LearningContext(isEnabled: false), .disabled),
        ]
        for (context, reason) in refused {
            #expect(try await memory.learn(change(), context: context) == .refused(reason))
        }
        #expect(!FileManager.default.fileExists(atPath: root.file("corrections.md").path))
    }

    @Test("while memory is paused a change is not kept")
    func pausedWritesNothing() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.setPaused(true)
        #expect(try await memory.learn(change(), context: LearningContext(appBundleID: Self.app)) == .paused)
        #expect(!FileManager.default.fileExists(atPath: root.file("corrections.md").path))
        try await memory.setPaused(false)
        #expect(try await memory.learn(change(), context: LearningContext(appBundleID: Self.app)) == .kept(.written))
    }

    @Test("nothing expires by itself: only a chosen life removes changes, and only those older than it")
    func pruning() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        for (index, age) in [0.0, 29, 31, 89, 91, 400].enumerated() {
            try await memory.add(change("meet at gate \(index) on Friday", "meet at gate \(index) on Monday", daysAgo: age))
        }
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria", createdAt: TemporaryMemoryRoot.today.addingTimeInterval(-900 * Self.day)))
        let before = try root.text("corrections.md")
        #expect(MemoryLife(rawValue: 0) == .never)
        #expect(try await memory.prune(.never) == 0)
        #expect(try root.text("corrections.md") == before)
        #expect(try await memory.prune(.days90) == 2)
        #expect(try await memory.index().entries.filter { $0.kind == .correction }.count == 4)
        #expect(try await memory.prune(.days90) == 0)
        #expect(try await memory.prune(.days30) == 2)
        let left = try await memory.index()
        #expect(left.entries.filter { $0.kind == .correction }.compactMap(\.before).sorted() == ["meet at gate 0 on Friday", "meet at gate 1 on Friday"])
        // A word is not a change: no life removes it.
        #expect(left.terms.map(\.value) == ["Veloria"])
    }

    @Test("deleting one change removes its line and nothing else; deleting learning data removes them all and keeps typed words")
    func deleting() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let first = change(), second = change("send it by end of day", "send it by noon")
        try await memory.add(first)
        try await memory.add(second)
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria"))
        try await memory.forget(id: first.id)
        let text = try root.text("corrections.md")
        #expect(!text.contains("Tarrow") && !text.contains("Tavren"))
        #expect(text.contains("send it by noon"))
        #expect(try await memory.index().entries.filter { $0.kind == .correction } == [second])
        try await memory.forgetLearned()
        #expect(try root.text("corrections.md") == MemoryFiles.starter(for: "corrections.md"))
        #expect(try await memory.index().terms.map(\.value) == ["Veloria"])
    }

    @Test("erase all removes every change, and deleting learning data with no file makes none")
    func erasing() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.forgetLearned()
        #expect(!FileManager.default.fileExists(atPath: root.file("corrections.md").path))
        try await memory.add(change())
        try await memory.eraseAll()
        #expect(try await memory.index().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.file("corrections.md").path))
    }

    @Test("the block's edits are this app's three most recent, oldest first")
    func blockOrderAndCaps() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let history = try Store()
        func edits() async throws -> [String] {
            let prepared = try await PersonBlockAssembler.prepare(memory: memory, history: history, app: Self.app)
            return PersonBlockAssembler.finish(prepared, transcript: "hello")?.edits.map(\.after) ?? []
        }
        #expect(try await edits().isEmpty)
        try await memory.add(change("one a", "one", daysAgo: 4))
        #expect(try await edits() == ["one"])
        try await memory.add(change("three a", "three", daysAgo: 2))
        #expect(try await edits() == ["one", "three"])
        try await memory.add(change("two a", "two", daysAgo: 3))
        try await memory.add(change("four a", "four", daysAgo: 1))
        try await memory.add(change("elsewhere a", "elsewhere", app: "app.lumen.notes"))
        #expect(try await edits() == ["two", "three", "four"])
        // Two from one dictation carry the same second: the later line is the more recent.
        try await memory.add(change("five a", "five"))
        try await memory.add(change("six a", "six"))
        #expect(try await edits() == ["four", "five", "six"])
        let prepared = try await PersonBlockAssembler.prepare(memory: memory, history: history, app: Self.app)
        #expect(PersonBlockAssembler.finish(prepared, transcript: "hello")?.render() == """
        About this person
        Their edits: "four a" -> "four" / "five a" -> "five" / "six a" -> "six"
        """)
    }
}
