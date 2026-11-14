import Foundation
import GRDB
import Testing
@testable import MurmurCore

@Suite("Person memory store")
struct PersonMemoryStoreTests {
    private static let app = "app.quillpad.mail"

    @Test("lines typed by hand into the files are entries the next time memory is read")
    func handTypedLinesAreUsed() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria"))
        let typedWords = try root.text("terms.md").replacingOccurrences(of: "## Words", with: "## Words\n- Nerula\n- Tavren Ridge")
            + "\n- Savara"
        try root.write(typedWords, to: "terms.md")
        try root.write("My own heading\n- short sentences\n- no exclamation marks", to: "profile.md")
        try root.write("- lower case, one line", to: "style/app.quillpad.mail.md")
        let index = try await memory.index()
        #expect(Set(index.terms.map(\.value)) == ["Veloria", "Nerula", "Tavren Ridge"])
        #expect(index.forgottenKeys == ["savara"])
        #expect(index.entries.filter { $0.kind == .profile }.map(\.value) == ["short sentences", "no exclamation marks"])
        #expect(index.stylesByApp[Self.app]?.map(\.value) == ["lower case, one line"])
        let typed = index.entries.filter { $0.value != "Veloria" }
        #expect(typed.allSatisfy { $0.createdAt == TemporaryMemoryRoot.today && $0.heardAs.isEmpty })
        // What they typed is still there, word for word, and reads the same on the next day.
        #expect(try root.text("profile.md").hasPrefix("My own heading\n- short sentences <!-- hushy:"))
        #expect(try root.text("terms.md").contains("\n- Nerula <!-- hushy:"))
        let later = MemoryStore(root: root.url, now: { TemporaryMemoryRoot.today.addingTimeInterval(86_400) })
        #expect(try await later.index() == index)
        // And the block uses them.
        let prepared = PersonBlockAssembler.Prepared(index: index, app: Self.app, earlier: [], paused: false)
        #expect(PersonBlockAssembler.finish(prepared, transcript: "ask nerula")?.render() == """
        About this person
        How they write: short sentences; no exclamation marks; lower case, one line
        Words they use: Nerula
        """)
    }

    @Test("a word typed twice is one word, and one typed above a Forgotten line stays forgotten")
    func typedDuplicates() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        try root.write("- Veloria\n- veloria\n- Savara\n## Forgotten\n- savara", to: "terms.md")
        let index = try await root.store().index()
        #expect(index.terms.map(\.value) == ["Veloria"])
        #expect(index.forgottenKeys == ["savara"])
    }

    @Test("adding a word that is there, in any capitals, updates it instead of adding a second")
    func noDuplicateTerms() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let first = MemoryEntry(kind: .term, value: "veloria", heardAs: ["valoria"])
        #expect(try await memory.add(first) == .written)
        #expect(try await memory.add(MemoryEntry(kind: .term, value: "Veloria", heardAs: ["Valoria", "the loria"], appBundleID: Self.app)) == .merged)
        var terms = try await memory.index().terms
        #expect(terms.count == 1)
        #expect(terms.first?.id == first.id)
        #expect(terms.first?.value == "Veloria")
        #expect(terms.first?.heardAs == ["valoria", "the loria"])
        #expect(terms.first?.appBundleID == Self.app)
        // Renaming one word onto another folds the two together.
        var other = MemoryEntry(kind: .term, value: "Nerula", heardAs: ["neroola"])
        try await memory.add(other)
        other.value = "VELORIA"
        #expect(try await memory.update(other) == .merged)
        terms = try await memory.index().terms
        #expect(terms.map(\.value) == ["VELORIA"])
        #expect(terms.first?.heardAs == ["valoria", "the loria", "neroola"])
        #expect(try await memory.add(MemoryEntry(kind: .term, value: "  ")) == .empty)
    }

    @Test("a forgotten word cannot be added, renamed into or imported again; only Restore brings it back")
    func tombstoneAndRestore() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let first = MemoryEntry(kind: .term, value: "Veloria", heardAs: ["Valoria"])
        let other = MemoryEntry(kind: .term, value: "Nerula")
        try await memory.add(first)
        try await memory.add(other)
        try await memory.forget(id: first.id)
        #expect(try await memory.add(MemoryEntry(kind: .term, value: "veloria")) == .forgotten)
        var renamed = other
        renamed.value = "VELORIA"
        #expect(try await memory.update(renamed) == .forgotten)
        var index = try await memory.index()
        #expect(index.terms == [other])
        #expect(index.forgottenKeys == ["veloria"])
        // The tombstone is in the file, under its heading, so it outlives the index.
        #expect(try root.text("terms.md").contains("## Forgotten\n- Veloria <!--"))
        #expect(try await MemoryStore(root: root.url).index().forgottenKeys == ["veloria"])
        let tombstone = try #require(index.entries.first { $0.kind == .forgotten })
        #expect(try await memory.restore(id: tombstone.id) == .written)
        index = try await memory.index()
        #expect(index.forgottenKeys.isEmpty)
        #expect(index.terms.map(\.value) == ["Nerula", "Veloria"])
        #expect(try await memory.restore(id: tombstone.id) == .missing)
        #expect(try await memory.add(MemoryEntry(kind: .term, value: "veloria")) == .merged)
    }

    @Test("what is learned from edits is refused where learning is, and while paused; the person's own changes are not")
    func learningGate() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let word = MemoryEntry(kind: .term, value: "Veloria")
        let off = LearningContext(isEnabled: false, appBundleID: Self.app)
        let excluded = LearningContext(appBundleID: Self.app, excludedBundleIDs: [Self.app])
        #expect(try await memory.learn(word, context: off) == .refused(.disabled))
        #expect(try await memory.learn(word, context: excluded) == .refused(.excludedApp))
        #expect(try await memory.learn(word, context: LearningContext(isSecureField: true)) == .refused(.secureField))
        #expect(try await memory.learn(word, context: LearningContext(isCodeContext: true)) == .refused(.codeContext))
        #expect(!FileManager.default.fileExists(atPath: root.file("terms.md").path))
        try await memory.setPaused(true)
        #expect(try await memory.learn(word, context: LearningContext(appBundleID: Self.app)) == .paused)
        #expect(try await memory.index().terms.isEmpty)
        // Paused and with learning off, what the person does in the pane still happens.
        #expect(try await memory.add(MemoryEntry(kind: .term, value: "Nerula")) == .written)
        try await memory.setPaused(false)
        #expect(try await memory.learn(word, context: LearningContext(appBundleID: Self.app)) == .kept(.written))
        #expect(try await memory.learn(word, context: LearningContext(appBundleID: Self.app)) == .kept(.merged))
        #expect(try await memory.index().terms.map(\.value) == ["Nerula", "Veloria"])
    }

    @Test("the notes for every app stop at the cap, on add and on update")
    func profileCap() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        var first = MemoryEntry(kind: .profile, value: String(repeating: "a", count: 1_000))
        #expect(try await memory.add(first) == .written)
        #expect(try await memory.add(MemoryEntry(kind: .profile, value: String(repeating: "b", count: 1_600))) == .written)
        var notes = try await memory.index().entries
        #expect(notes.map(\.value.count) == [1_000, 500])
        #expect(try await memory.add(MemoryEntry(kind: .profile, value: "one more")) == .full)
        first.value = String(repeating: "c", count: 1_600)
        #expect(try await memory.update(first) == .written)
        notes = try await memory.index().entries
        #expect(notes.map(\.value.count) == [1_000, 500])
        #expect(notes.first?.value.first == "c")
        #expect(notes.reduce(0) { $0 + $1.value.count } == MemoryDocument.profileLimit)
    }

    @Test("a write replaces the file whole and leaves nothing else in the folder")
    func atomicWrite() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria"))
        let before = try fileNumber(root.file("terms.md"))
        try await memory.add(MemoryEntry(kind: .term, value: "Nerula"))
        // Written beside the file and renamed over it: a new file under the old name, never a
        // half-written one.
        #expect(try fileNumber(root.file("terms.md")) != before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path) == ["terms.md"])
        #expect(try await memory.index().terms.map(\.value) == ["Veloria", "Nerula"])
        // Writing the same entries again changes nothing in the file.
        let text = try root.text("terms.md")
        try await memory.update(try #require(try await memory.index().terms.first))
        #expect(try root.text("terms.md") == text)
    }

    @Test("erase all empties the folder and is not undone by the one-way import")
    func eraseAll() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let old = try Store()
        try await old.writer.write { db in
            var active = LearnedItem(kind: .term, key: "veloria", value: "Veloria", status: .active)
            try active.save(db)
        }
        let memory = root.store()
        try await memory.importLegacy(from: old)
        try await memory.add(MemoryEntry(kind: .profile, value: "short sentences"))
        try await memory.add(MemoryEntry(kind: .style, value: "brief replies", appBundleID: Self.app))
        let imported = try #require(try await memory.index().terms.first)
        try await memory.forget(id: imported.id)
        try await memory.eraseAll()
        #expect(try await memory.index().entries.isEmpty)
        #expect(try await memory.index().forgottenKeys.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path) == ["terms.md"])
        #expect(try root.text("terms.md") == MemoryFiles.starter(for: "terms.md"))
        try await memory.importLegacy(from: old)
        #expect(try await memory.index().entries.isEmpty)
        #expect(!(try await memory.isPaused()))
    }

    @Test("pause is kept in the folder and outlives erase all")
    func pause() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        #expect(!(try await memory.isPaused()))
        try await memory.setPaused(true)
        #expect(try await memory.isPaused())
        #expect(try await MemoryStore(root: root.url).isPaused())
        try await memory.eraseAll()
        #expect(try await memory.isPaused())
        try await memory.setPaused(false)
        #expect(!(try await memory.isPaused()))
    }

    @Test("an edit made outside the app is read on the next use")
    func outsideEdit() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria"))
        try await memory.add(MemoryEntry(kind: .style, value: "brief replies", appBundleID: Self.app))
        #expect(try await memory.index().terms.map(\.value) == ["Veloria"])
        var outside = MemoryDocument(try root.text("terms.md"), file: .terms)
        outside.append(MemoryEntry(kind: .term, value: "Nerula"))
        try root.write(outside.text.replacingOccurrences(of: "- Veloria <!--", with: "- Velorian <!--"), to: "terms.md")
        try FileManager.default.removeItem(at: root.file("style/app.quillpad.mail.md"))
        let index = try await memory.index()
        #expect(index.terms.map(\.value) == ["Velorian", "Nerula"])
        #expect(index.stylesByApp.isEmpty)
    }

    @Test("a file that cannot be read as text stops the change and is left as it was")
    func unreadableFileIsNotReplaced() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let bytes = Data([0x2D, 0x20, 0xFF, 0xFE, 0xFD])
        try bytes.write(to: root.file("terms.md"))
        let memory = root.store()
        await #expect(throws: (any Error).self) { try await memory.add(MemoryEntry(kind: .term, value: "Veloria")) }
        await #expect(throws: (any Error).self) { _ = try await memory.index() }
        #expect(try Data(contentsOf: root.file("terms.md")) == bytes)
    }

    @Test("an index rebuilt from the files equals the one kept up to date change by change")
    func rebuiltIndexEqualsIncremental() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let veloria = MemoryEntry(kind: .term, value: "Veloria", heardAs: ["Valoria"])
        var nerula = MemoryEntry(kind: .term, value: "Nerula")
        var style = MemoryEntry(kind: .style, value: "brief replies", appBundleID: Self.app)
        try await memory.add(MemoryEntry(kind: .profile, value: "short sentences"))
        try await memory.add(veloria)
        try await memory.add(nerula)
        try await memory.add(style)
        try await memory.add(MemoryEntry(kind: .correction, value: "", appBundleID: "app.lumen.notes",
                                         before: "tavren ridge", after: "Tavren Ridge"))
        nerula.heardAs = ["neroola"]
        try await memory.update(nerula)
        style.appBundleID = "app.lumen.notes"
        try await memory.update(style)
        try await memory.forget(id: veloria.id)
        let incremental = try await memory.index()
        #expect(try await MemoryStore(root: root.url).index() == incremental)
        #expect(MemoryIndex(entries: incremental.entries) == incremental)
        #expect(incremental.terms == [nerula])
        #expect(incremental.stylesByApp.keys.sorted() == ["app.lumen.notes"])
        #expect(incremental.stylesByApp["app.lumen.notes"] == [style])
        #expect(incremental.correctionsByApp["app.lumen.notes"]?.first?.after == "Tavren Ridge")
    }

    @Test("an edited entry keeps its place in the file")
    func updateKeepsOrder() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        var first = MemoryEntry(kind: .term, value: "Veloria")
        try await memory.add(first)
        try await memory.add(MemoryEntry(kind: .term, value: "Nerula"))
        first.heardAs = ["Valoria"]
        try await memory.update(first)
        #expect(try await memory.index().terms.map(\.value) == ["Veloria", "Nerula"])
        #expect(try await memory.index().terms.first?.heardAs == ["Valoria"])
    }

    @Test("the first import copies words in use and forgotten words; later ones change nothing")
    func legacyImportIsOneWay() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let old = try Store()
        try await old.writer.write { db in
            var active = LearnedItem(kind: .term, key: "veloria", value: "Veloria",
                                     heardAs: ["Valoria"], status: .active)
            var forgotten = LearnedItem(kind: .term, key: "nerula", value: "Nerula", status: .forgotten)
            var candidate = LearnedItem(kind: .term, key: "savara", value: "Savara")
            var habit = LearnedItem(kind: .styleSignal, key: "format:lowercased", value: "format:lowercased", status: .active)
            try active.save(db)
            try forgotten.save(db)
            try candidate.save(db)
            try habit.save(db)
        }
        let memory = root.store()
        try await memory.importLegacy(from: old)
        let index = try await memory.index()
        #expect(index.terms.map(\.value) == ["Veloria"])
        #expect(index.terms.first?.heardAs == ["Valoria"])
        #expect(index.forgottenKeys == ["nerula"])
        #expect(try root.text("terms.md").hasPrefix("# Words Hushy knows\n\n> "))
        #expect(try root.text("profile.md") == MemoryFiles.starter(for: "profile.md"))
        #expect(try root.text("corrections.md") == MemoryFiles.starter(for: "corrections.md"))
        try await memory.add(MemoryEntry(kind: .term, value: "Tavren Ridge"))
        #expect(try await memory.add(MemoryEntry(kind: .term, value: "Nerula")) == .forgotten)
        try await memory.importLegacy(from: old)
        #expect(try await memory.index().terms.map(\.value) == ["Veloria", "Tavren Ridge"])
    }

    @Test("a folder has one shared store, whoever asks and however its path is written")
    func oneStorePerFolder() throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let other = try TemporaryMemoryRoot()
        defer { other.remove() }
        let first = MemoryStore.shared(root: root.url)
        #expect(MemoryStore.shared(root: root.url) === first)
        #expect(MemoryStore.shared(root: root.url.appendingPathComponent("style/..")) === first)
        #expect(MemoryStore.shared(root: other.url) !== first)
        #expect(MemoryStore.shared() === MemoryStore.shared(root: AppPaths.memoryDirectory))
    }

    private func fileNumber(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? Int)
    }
}
