import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// What the Memory sheet lists and says. Every entry is invented.
@MainActor
@Suite("Memory pane")
struct MemoryPaneTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_791_806_400 + seconds) }

    @Test("entries are grouped; the notes for every app keep the file's order, the rest run newest first")
    func sections() {
        let entries = [
            MemoryEntry(kind: .profile, value: "short sentences", createdAt: at(0)),
            MemoryEntry(kind: .profile, value: "typed today", createdAt: at(500)),
            MemoryEntry(kind: .term, value: "Veloria", createdAt: at(10)),
            MemoryEntry(kind: .term, value: "Nerula", createdAt: at(20)),
            MemoryEntry(kind: .forgotten, value: "Savara", createdAt: at(30)),
            MemoryEntry(kind: .style, value: "lower case", appBundleID: "app.quillpad.mail", createdAt: at(40)),
            MemoryEntry(kind: .correction, value: "", appBundleID: "app.quillpad.mail", createdAt: at(50), before: "a", after: "b"),
        ]
        let sections = MemoryPaneSections(entries: entries)
        #expect(sections.writing.map(\.value) == ["short sentences", "typed today", "lower case"])
        #expect(sections.words.map(\.value) == ["Nerula", "Veloria"])
        #expect(sections.forgotten.map(\.value) == ["Savara"])
        #expect(sections.edits.count == 1)
        #expect(!sections.isEmpty)
        #expect(MemoryPaneSections(entries: []).isEmpty)
    }

    @Test("a line typed by hand into the folder is listed like any other")
    func typedLinesAreListed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("style"), withIntermediateDirectories: true)
        try "- Veloria\n## Forgotten\n- Savara".write(to: root.appendingPathComponent("terms.md"), atomically: true, encoding: .utf8)
        try "- short sentences".write(to: root.appendingPathComponent("profile.md"), atomically: true, encoding: .utf8)
        try "- lower case".write(to: root.appendingPathComponent("style/app.quillpad.mail.md"), atomically: true, encoding: .utf8)
        let sections = MemoryPaneSections(entries: try await MemoryStore(root: root).index().entries)
        #expect(sections.writing.map(\.value) == ["short sentences", "lower case"])
        #expect(sections.words.map(\.value) == ["Veloria"])
        #expect(sections.forgotten.map(\.value) == ["Savara"])
        let style = try #require(sections.writing.last)
        #expect(MemoryPaneCopy.detail(style, appName: { _ in "Quillpad" }).hasSuffix(" · Quillpad"))
    }

    @Test("a row says what was heard, when, and where; a forgotten word says it stays forgotten")
    func detail() {
        let word = MemoryEntry(kind: .term, value: "Veloria", heardAs: ["valoria", "the loria"], appBundleID: "app.quillpad.mail", createdAt: at(0))
        let line = MemoryPaneCopy.detail(word, appName: { _ in "Quillpad" })
        #expect(line.hasPrefix("Heard as “valoria”, “the loria” · "))
        #expect(line.hasSuffix(" · Quillpad"))
        #expect(MemoryPaneCopy.detail(MemoryEntry(kind: .term, value: "Nerula", createdAt: at(0)), appName: { $0 }).hasSuffix(" · All apps"))
        #expect(MemoryPaneCopy.detail(MemoryEntry(kind: .forgotten, value: "Savara", createdAt: at(0)), appName: { $0 }).hasPrefix("Never learned again · "))
    }

    @Test("a change that was not made as asked says why; one that was says nothing")
    func messages() {
        #expect(MemoryPaneCopy.message(for: .written, value: "Veloria") == nil)
        #expect(MemoryPaneCopy.message(for: .merged, value: "Veloria") == nil)
        #expect(MemoryPaneCopy.message(for: .forgotten, value: "Veloria")?.contains("“Veloria” is under Forgotten") == true)
        #expect(MemoryPaneCopy.message(for: .full, value: "x")?.contains("1,500") == true)
    }

    @Test("the pane and a dictation hold the same store for the folder")
    func sharedStore() {
        #expect(MemoryStore.shared() === MemoryStore.shared(root: AppPaths.memoryDirectory))
    }

    @Test("the stills cover every state by name, with a 600-character note")
    func stillFixtures() {
        #expect(MemorySnapshotFixtures.states().map(\.0) == [
            "empty", "filled", "paused", "long-profile", "long-profile-open", "edits", "edits-long", "edits-open",
        ])
        #expect(MemorySnapshotFixtures.edits().map(\.0) == ["word", "note"])
        #expect(MemorySnapshotFixtures.longProfile.first?.value.count == 600)
        #expect(MemorySnapshotFixtures.pairs.count == 5)
        #expect(MemorySnapshotFixtures.manyPairs.count == 300)
    }

    // MARK: The person's edits

    private func pair(_ index: Int, app: String = "app.quillpad.mail") -> MemoryEntry {
        MemoryEntry(kind: .correction, value: "", appBundleID: app, createdAt: at(Double(index) * 60),
                    before: "meet at gate \(index) on Friday", after: "meet at gate \(index) on Monday")
    }

    @Test("edits list newest first; a long list opens on the newest five and says how many there are")
    func longListOfEdits() {
        let edits = MemoryPaneSections(entries: (0..<300).map { pair($0) }.shuffled()).edits
        #expect(edits.first?.before == "meet at gate 299 on Friday")
        #expect(edits.last?.before == "meet at gate 0 on Friday")
        let closed = MemoryPaneCopy.shownEdits(edits, isOpen: false)
        #expect(closed.map(\.before) == (295...299).reversed().map { "meet at gate \($0) on Friday" })
        #expect(MemoryPaneCopy.editCount(shown: closed.count, of: edits.count) == "The newest 5 of 300")
        let open = MemoryPaneCopy.shownEdits(edits, isOpen: true)
        #expect(open.count == 300)
        #expect(MemoryPaneCopy.editCount(shown: open.count, of: edits.count) == "All 300, newest first")
        #expect(MemoryPaneCopy.shownEdits(Array(edits.prefix(3)), isOpen: false).count == 3)
    }

    @Test("an edit's row says the app and the date, marks the changed words, and reads aloud as before then after")
    func editRow() {
        let entry = MemoryEntry(kind: .correction, value: "", appBundleID: "app.quillpad.mail", createdAt: at(0),
                                before: "meet at Tarrow Rij on Friday", after: "meet at Tavren Ridge on Friday")
        let detail = MemoryPaneCopy.detail(entry, appName: { _ in "Quillpad" })
        #expect(detail.hasSuffix(" · Quillpad"))
        #expect(detail.contains("2026"))
        #expect(MemoryPaneCopy.spoken(entry, detail: detail)
            == "Hushy wrote: meet at Tarrow Rij on Friday. You changed it to: meet at Tavren Ridge on Friday. \(detail)")
        let words = EditPair(before: entry.before ?? "", after: entry.after ?? "").words
        let before = MemoryPairRow.line(words.before, isBefore: true), after = MemoryPairRow.line(words.after, isBefore: false)
        #expect(String(before.characters) == entry.before)
        #expect(String(after.characters) == entry.after)
        #expect(before.runs.filter { $0.swiftUI.strikethroughStyle != nil }.map { String(before[$0.range].characters) } == ["Tarrow", "Rij"])
        #expect(after.runs.filter { $0.swiftUI.font != nil }.map { String(after[$0.range].characters) } == ["Tavren", "Ridge"])
    }

    @Test("Delete on an edit's row removes that pair from the file and leaves the others")
    func deleteOneEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(root: root)
        for index in 0..<3 { try await memory.add(pair(index)) }
        let listed = MemoryPaneSections(entries: try await memory.index().entries).edits
        // What the row's Delete does (`MemoryPane`'s `remove`).
        try await memory.forget(id: listed[1].id)
        let text = try String(contentsOf: root.appendingPathComponent("corrections.md"), encoding: .utf8)
        #expect(!text.contains("gate 1 "))
        #expect(text.contains("gate 0 ") && text.contains("gate 2 "))
        #expect(MemoryPaneSections(entries: try await memory.index().entries).edits.map(\.before)
            == ["meet at gate 2 on Friday", "meet at gate 0 on Friday"])
    }

    // MARK: Settings

    @Test("the life of an edit is never unless the person chooses, and a choice persists")
    func editLifeSetting() {
        let name = "hushy-test-memory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.memoryEditLife == .never)
        settings.memoryEditLife = .days30
        #expect(AppSettings(defaults: defaults).memoryEditLife == .days30)
        settings.memoryEditLife = .days90
        #expect(AppSettings(defaults: defaults).memoryEditLife == .days90)
        defaults.set(7, forKey: "memoryEditLife")
        #expect(AppSettings(defaults: defaults).memoryEditLife == .never)
    }

    @Test("with memory in the build the Privacy wording says the before-and-after is kept until deleted; without it nothing changes")
    func privacyWording() {
        let proposed = LearningCopy.detail(keepsChanges: true)
        #expect(proposed.contains("keeps what it wrote and what you changed it to"))
        #expect(proposed.contains("stays on this Mac until you delete it"))
        #expect(proposed.contains("never what else is in the field"))
        #expect(proposed.contains("never reads password fields, password managers or code editors"))
        let today = LearningCopy.detail(keepsChanges: false)
        #expect(today.hasPrefix("When you fix a word right after dictating, Hushy remembers the fix on this Mac"))
        #expect(today.contains("never reads password fields"))
        #expect(today.count <= 140, "two lines in a Settings row")
        #expect(LearningCopy.deleteDetail(keepsChanges: false) == "Removes every word and habit Hushy learned from your edits.")
        #expect(LearningCopy.deleteDetail(keepsChanges: true).contains("every before-and-after it kept"))
        #expect(!LearningCopy.deleteConfirmation(keepsChanges: false).contains("Memory"))
        #expect(LearningCopy.deleteConfirmation(keepsChanges: true).contains("what you typed or changed there yourself stays"))
        // The shorter alternative says the same four things: what is kept, where, until when, what is never read.
        let shorter = MemorySnapshotFixtures.shorterWording
        for part in ["what it wrote and what you changed it to", "on this Mac", "until you delete it", "never reads password fields"] {
            #expect(shorter.contains(part))
        }
        // Three lines at the pane's width is about 300 characters.
        #expect(shorter.count < 300)
    }
}
