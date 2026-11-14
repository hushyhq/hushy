import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Whose each entry is: what Hushy learned goes with "Delete learning data", what the person
/// typed or changed stays. Every word and sentence is invented.
@Suite("Person memory origins")
struct PersonMemoryOriginTests {
    private static let app = "app.quillpad.mail"
    private let context = LearningContext(appBundleID: PersonMemoryOriginTests.app)

    private func origins(_ memory: MemoryStore) async throws -> [String: MemoryEntry.Origin?] {
        Dictionary(uniqueKeysWithValues: try await memory.index().entries.map { ($0.value, $0.origin) })
    }

    @Test("what learning writes is marked learned, what the person adds or types is marked typed, and both survive the file")
    func originIsRecorded() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.learn(MemoryEntry(kind: .term, value: "Veloria"), context: context)
        try await memory.add(MemoryEntry(kind: .term, value: "Nerula"))
        try root.write(try root.text("terms.md").replacingOccurrences(of: "## Forgotten", with: "- Tavren Ridge\n\n## Forgotten"), to: "terms.md")
        let read = try await origins(MemoryStore(root: root.url))
        #expect(read == ["Veloria": .learned, "Nerula": .typed, "Tavren Ridge": .typed])
        let text = try root.text("terms.md")
        #expect(text.contains("- Veloria <!-- hushy:{\"created\":\""))
        #expect(text.components(separatedBy: "\n").first { $0.hasPrefix("- Veloria") }?.contains("\"origin\":\"learned\"} -->") == true)
        #expect(text.components(separatedBy: "\n").first { $0.hasPrefix("- Nerula") }?.hasSuffix("\"origin\":\"typed\"} -->") == true)
        #expect(text.components(separatedBy: "\n").first { $0.hasPrefix("- Tavren Ridge") }?.hasSuffix("\"origin\":\"typed\"} -->") == true)
        // A learned note and a learned pair are marked the same way.
        try await memory.learn(MemoryEntry(kind: .style, value: "lower case", appBundleID: Self.app), context: context)
        try await memory.learn(MemoryEntry(kind: .correction, value: "", appBundleID: Self.app, before: "meet at Tarrow Rij", after: "meet at Tavren Ridge"),
                               context: context)
        let entries = try await MemoryStore(root: root.url).index().entries
        #expect(entries.first { $0.kind == .style }?.origin == .learned)
        #expect(entries.first { $0.kind == .correction }?.origin == .learned)
    }

    @Test("a learned word the person retypes in the file is theirs from then on, and its text is left as typed")
    func retypedByHand() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.learn(MemoryEntry(kind: .term, value: "Veloria"), context: context)
        let id = try #require(try await memory.index().terms.first?.id)
        try root.write(try root.text("terms.md").replacingOccurrences(of: "- Veloria <!--", with: "- Velloria   <!--"), to: "terms.md")
        let retyped = try #require(try await memory.index().terms.first)
        #expect(retyped.value == "Velloria")
        #expect(retyped.origin == .typed)
        #expect(retyped.id == id)
        let line = try #require(try root.text("terms.md").components(separatedBy: "\n").first { $0.hasPrefix("- Velloria") })
        #expect(line.hasPrefix("- Velloria   <!-- hushy:{"))
        #expect(line.hasSuffix("\"origin\":\"typed\"} -->"))
        #expect(!line.contains("\"mark\""))
        // Typed back to what it was, it is still theirs.
        try root.write(try root.text("terms.md").replacingOccurrences(of: "- Velloria   <!--", with: "- Veloria <!--"), to: "terms.md")
        #expect(try await memory.index().terms.first?.origin == .typed)
    }

    @Test("an edit in the pane makes a learned entry the person's; learning a word again does not take it back")
    func editedInThePane() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.learn(MemoryEntry(kind: .term, value: "Veloria"), context: context)
        try await memory.learn(MemoryEntry(kind: .term, value: "Nerula"), context: context)
        try await memory.learn(MemoryEntry(kind: .term, value: "Savara"), context: context)
        // Learned again, with another hearing: still learned.
        #expect(try await memory.learn(MemoryEntry(kind: .term, value: "veloria", heardAs: ["valoria"]), context: context) == .kept(.merged))
        #expect(try await origins(memory)["veloria"] == .learned)
        // Edited in the pane, even without retyping the word: theirs.
        var nerula = try #require(try await memory.index().terms.first { $0.value == "Nerula" })
        nerula.heardAs = ["neroola"]
        nerula.origin = .learned
        try await memory.update(nerula)
        #expect(try await origins(memory)["Nerula"] == .typed)
        #expect(try await memory.learn(MemoryEntry(kind: .term, value: "Nerula"), context: context) == .kept(.merged))
        #expect(try await origins(memory)["Nerula"] == .typed)
        // Added by the person where Hushy had learned it: theirs.
        #expect(try await memory.add(MemoryEntry(kind: .term, value: "Savara")) == .merged)
        #expect(try await origins(memory)["Savara"] == .typed)
    }

    @Test("deleting learning data removes what was learned from every file and every pair, and keeps what was typed and the Forgotten list")
    func forgetLearned() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.learn(MemoryEntry(kind: .term, value: "Veloria"), context: context)
        try await memory.learn(MemoryEntry(kind: .profile, value: "learned: short sentences"), context: context)
        try await memory.learn(MemoryEntry(kind: .style, value: "learned: lower case", appBundleID: Self.app), context: context)
        try await memory.learn(MemoryEntry(kind: .correction, value: "", appBundleID: Self.app, before: "meet at Tarrow Rij", after: "meet at Tavren Ridge"),
                               context: context)
        try await memory.add(MemoryEntry(kind: .term, value: "Nerula"))
        try await memory.add(MemoryEntry(kind: .profile, value: "typed: no exclamation marks"))
        try await memory.add(MemoryEntry(kind: .style, value: "typed: one line", appBundleID: Self.app))
        let learnedThenForgotten = MemoryEntry(kind: .term, value: "Savara")
        try await memory.learn(learnedThenForgotten, context: context)
        try await memory.forget(id: learnedThenForgotten.id)
        try await memory.forgetLearned()
        let index = try await MemoryStore(root: root.url).index()
        #expect(Set(index.entries.map(\.value)) == ["Nerula", "typed: no exclamation marks", "typed: one line", "Savara"])
        #expect(index.forgottenKeys == ["savara"])
        #expect(try root.text("corrections.md") == MemoryFiles.starter(for: "corrections.md"))
        // Still forgotten: learning cannot bring the word back.
        #expect(try await memory.learn(MemoryEntry(kind: .term, value: "Savara"), context: context) == .kept(.forgotten))
    }

    @Test("an entry from before origins were recorded goes only if it is a copied learned word: same word, same date")
    func entriesWithoutAnOrigin() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let learnedAt = TemporaryMemoryRoot.today.addingTimeInterval(-86_400 * 3)
        let old = try Store()
        try await old.writer.write { db in
            var veloria = LearnedItem(kind: .term, key: "veloria", value: "Veloria", status: .active, createdAt: learnedAt, lastSeenAt: learnedAt)
            var nerula = LearnedItem(kind: .term, key: "nerula", value: "Nerula", status: .active, createdAt: learnedAt, lastSeenAt: learnedAt)
            try veloria.save(db)
            try nerula.save(db)
        }
        func line(_ word: String, _ date: String, _ id: Int) -> String {
            "- \(word) <!-- hushy:{\"created\":\"\(date)\",\"id\":\"00000000-0000-0000-0000-00000000000\(id)\"} -->"
        }
        // As the first copy wrote them, before origins: Veloria with the learned item's date.
        // Nerula is the same word but dated otherwise (typed by the person), Tavren Ridge is not in the database.
        try root.write([
            "## Words", line("Veloria", "2026-10-09T12:00:00Z", 1), line("Nerula", "2026-10-11T08:30:00Z", 2),
            line("Tavren Ridge", "2026-10-09T12:00:00Z", 3), "", "## Forgotten",
        ].joined(separator: "\n"), to: "terms.md")
        let memory = root.store()
        #expect(try await memory.index().terms.map(\.origin) == [nil, nil, nil])
        try await memory.forgetLearned(imported: try MemoryStore.importedWords(in: old))
        #expect(try await memory.index().terms.map(\.value) == ["Nerula", "Tavren Ridge"])
        // With nothing to compare against, an unmarked entry is taken to be the person's.
        try await memory.forgetLearned()
        #expect(try await memory.index().terms.map(\.value) == ["Nerula", "Tavren Ridge"])
    }

    @Test("the first copy marks its words learned, and nothing is copied back in after they are deleted")
    func importCannotBringWordsBack() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let old = try Store()
        try await old.writer.write { db in
            var active = LearnedItem(kind: .term, key: "veloria", value: "Veloria", heardAs: ["Valoria"], status: .active)
            var forgotten = LearnedItem(kind: .term, key: "savara", value: "Savara", status: .forgotten)
            try active.save(db)
            try forgotten.save(db)
        }
        let memory = root.store()
        try await memory.importLegacy(from: old)
        #expect(try await memory.index().terms.map(\.origin) == [.learned])
        try await memory.add(MemoryEntry(kind: .term, value: "Nerula"))
        // The rows are still in the database (as if deleting them had failed): the copy is one-time all the same.
        try await memory.forgetLearned(imported: try MemoryStore.importedWords(in: old))
        try await memory.importLegacy(from: old)
        let fresh = MemoryStore(root: root.url)
        try await fresh.importLegacy(from: old)
        #expect(try await fresh.index().terms.map(\.value) == ["Nerula"])
        #expect(try await fresh.index().forgottenKeys == ["savara"])
    }
}
