import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// A memory folder of its own for one test, removed afterwards.
struct TemporaryMemoryRoot {
    let url: URL
    /// The date every store made by `store()` stamps on what it writes.
    static let today = Date(timeIntervalSince1970: 1_791_806_400)

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-memory-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func store() -> MemoryStore { MemoryStore(root: url, now: { Self.today }) }
    func file(_ path: String) -> URL { url.appendingPathComponent(path) }
    func text(_ path: String) throws -> String { try String(contentsOf: file(path), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(at: file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file(path), atomically: true, encoding: .utf8)
    }
}

@Suite("Person memory document")
struct PersonMemoryDocumentTests {
    private static let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()
    private static let noon = Date(timeIntervalSince1970: 1_791_806_400)

    @Test("every kind of entry survives serialise then parse, field for field")
    func roundTrip() {
        let files: [(MemoryDocument.File, [MemoryEntry])] = [
            (.profile, [MemoryEntry(kind: .profile, value: "Short sentences, no exclamation marks")]),
            (.terms, [MemoryEntry(kind: .term, value: "Veloria", heardAs: ["Valoria", "the loria"], appBundleID: "app.quillpad.mail"),
                      MemoryEntry(kind: .forgotten, value: "Savara")]),
            (.style(app: "app.quillpad.mail"), [MemoryEntry(kind: .style, value: "lower case, one line", appBundleID: "app.quillpad.mail")]),
            (.style(app: nil), [MemoryEntry(kind: .style, value: "long form", appBundleID: "../outside")]),
            (.corrections, [MemoryEntry(kind: .correction, value: "", appBundleID: "app.lumen.notes",
                                        before: "meet at the\nnerula office", after: "Meet at the Nerula office.")]),
        ]
        for (file, entries) in files {
            var document = MemoryDocument("# Title", file: file)
            for entry in entries { document.append(entry) }
            let restored = MemoryDocument(document.text, file: file)
            #expect(restored.entries == entries, "\(file)")
            #expect(restored.text == document.text)
        }
    }

    @Test("the hidden note has its keys in order and its date as text, and is the same every time")
    func noteIsStable() {
        let term = MemoryEntry(id: Self.id, kind: .term, value: "Veloria", heardAs: ["valoria"], appBundleID: "app.quillpad.mail",
                               createdAt: Self.noon)
        var document = MemoryDocument(file: .terms)
        document.append(term)
        let line = "- Veloria <!-- hushy:{\"app\":\"app.quillpad.mail\",\"created\":\"2026-10-12T12:00:00Z\","
            + "\"heardAs\":[\"valoria\"],\"id\":\"11111111-2222-3333-4444-555555555555\",\"origin\":\"typed\"} -->"
        #expect(document.text == line)
        document.replace(term)
        #expect(document.text == line)
        var style = MemoryDocument(file: .style(app: "app.quillpad.mail"))
        style.append(MemoryEntry(id: Self.id, kind: .style, value: "one line", appBundleID: "app.quillpad.mail", createdAt: Self.noon))
        #expect(style.text == "- one line <!-- hushy:{\"created\":\"2026-10-12T12:00:00Z\",\"id\":\"11111111-2222-3333-4444-555555555555\",\"origin\":\"typed\"} -->")
    }

    @Test("text that looks like the hidden note, in a value or in how it was heard, does not lose the entry")
    func markerInsideAnEntry() {
        let tricky = MemoryEntry(kind: .term, value: "Veloria <!-- hushy:{\"id\":1} --> Park",
                                 heardAs: ["a --> b", " <!-- hushy:{} -->", "x < y"])
        var document = MemoryDocument(file: .terms)
        document.append(tricky)
        document.append(MemoryEntry(kind: .term, value: "ends like a note -->"))
        #expect(MemoryDocument(document.text, file: .terms).entries.map(\.value) == [tricky.value, "ends like a note -->"])
        #expect(MemoryDocument(document.text, file: .terms).entries.first == tricky)
        #expect(document.lines.allSatisfy { $0.components(separatedBy: "-->").count <= 3 })
    }

    @Test("a line typed by hand becomes an entry once adopted, and what was typed is left alone")
    func typedLinesAreAdopted() {
        let typed = "# Words\n- Veloria\n* Nerula  \n-   Tavren Ridge\n- \n-not a line\n  - nor this\n## Forgotten\n- Savara"
        var document = MemoryDocument(typed, file: .terms)
        #expect(document.entries.isEmpty)
        let adopted = document.adopt(now: Self.noon)
        #expect(adopted)
        let entries = document.entries
        #expect(entries.map(\.value) == ["Veloria", "Nerula", "Tavren Ridge", "Savara"])
        #expect(entries.map(\.kind) == [.term, .term, .term, .forgotten])
        #expect(entries.allSatisfy { $0.createdAt == Self.noon && $0.heardAs.isEmpty && $0.appBundleID == nil })
        #expect(Set(entries.map(\.id)).count == 4)
        for (before, after) in zip(typed.components(separatedBy: "\n"), document.lines) {
            #expect(after.hasPrefix(before))
        }
        #expect(document.lines[4] == "- " && document.lines[5] == "-not a line" && document.lines[6] == "  - nor this")
        // Nothing is left to adopt, and the ids hold.
        let again = document.adopt(now: Self.noon.addingTimeInterval(86_400))
        #expect(!again)
        #expect(MemoryDocument(document.text, file: .terms).entries == entries)
    }

    @Test("a typed note takes its kind and app from the file it is in")
    func typedNotesByFile() {
        var profile = MemoryDocument("- short sentences", file: .profile)
        var style = MemoryDocument("- lower case", file: .style(app: "app.quillpad.mail"))
        var pairs = MemoryDocument("- \"nerula\" → \"Nerula\"", file: .corrections)
        _ = profile.adopt(now: Self.noon)
        _ = style.adopt(now: Self.noon)
        #expect(profile.entries.map(\.kind) == [.profile])
        #expect(style.entries.map(\.appBundleID) == ["app.quillpad.mail"])
        #expect(style.entries.map(\.kind) == [.style])
        // An edit is a pair with an app, which only the hidden note holds: a typed one is kept, not read.
        let adoptedPair = pairs.adopt(now: Self.noon)
        #expect(!adoptedPair)
        #expect(pairs.entries.isEmpty)
    }

    @Test("headings, prose, comments and a line with a damaged note stay byte for byte through app edits")
    func unknownAndMalformedLinesSurvive() {
        let term = MemoryEntry(kind: .term, value: "Veloria", heardAs: ["Valoria"])
        let foreign = "# Words\ncustom note\n> a quoted note\n<!--\n- inside a comment\n-->\n- Nerula <!-- hushy:{not json} -->\n- <!-- hushy:{} -->\n\n  indented"
        var document = MemoryDocument(foreign, file: .terms)
        let adopted = document.adopt(now: Self.noon)
        #expect(!adopted)
        #expect(document.entries.isEmpty)
        document.append(term)
        #expect(document.entries == [term])
        var renamed = term
        renamed.value = "Veloria Park"
        document.replace(renamed)
        #expect(document.entries == [renamed])
        document.setPaused(true)
        #expect(document.isPaused)
        document.setPaused(false)
        document.remove(id: term.id)
        #expect(document.text == foreign)
    }

    @Test("retyping an entry's words changes its value; moving it under Forgotten makes it forgotten")
    func handEditedLineIsRead() throws {
        let term = MemoryEntry(kind: .term, value: "Veloria", heardAs: ["valoria"])
        var document = MemoryDocument("## Words\n\n## Forgotten", file: .terms)
        document.append(term)
        let retyped = MemoryDocument(document.text.replacingOccurrences(of: "- Veloria <!--", with: "- Velorian <!--"), file: .terms)
        #expect(retyped.entries.map(\.value) == ["Velorian"])
        #expect(retyped.entries.first?.id == term.id)
        #expect(retyped.entries.first?.heardAs == ["valoria"])
        let line = try #require(document.lines.first { $0.hasPrefix("- Veloria") })
        let moved = MemoryDocument("## Words\n\n## Forgotten\n" + line, file: .terms)
        #expect(moved.entries.map(\.kind) == [.forgotten])
        // With its words deleted there is nothing to be an entry; the line stays for the person to fix.
        let emptied = MemoryDocument(document.text.replacingOccurrences(of: "- Veloria <!--", with: "- <!--"), file: .terms)
        #expect(emptied.entries.isEmpty)
        #expect(emptied.text.contains("- <!-- hushy:"))
    }

    @Test("a new word goes under Words and a forgotten one under Forgotten, which is made when missing")
    func entriesGoToTheirSection() {
        var document = MemoryDocument("# Title\n\n## Words\n\n## Forgotten\n\n## My own notes\nkeep", file: .terms)
        document.append(MemoryEntry(kind: .term, value: "Veloria"))
        document.append(MemoryEntry(kind: .forgotten, value: "Savara"))
        document.append(MemoryEntry(kind: .term, value: "Nerula"))
        let shape = document.lines.map { $0.hasPrefix("- ") ? String($0.prefix(while: { $0 != "<" })) : $0 }
        #expect(shape == ["# Title", "", "## Words", "- Veloria ", "- Nerula ", "", "## Forgotten", "- Savara ", "", "## My own notes", "keep"])
        var bare = MemoryDocument("- Veloria", file: .terms)
        bare.append(MemoryEntry(kind: .forgotten, value: "Savara"))
        #expect(bare.lines[1...2] == ["", "## Forgotten"])
        _ = bare.adopt(now: Self.noon)
        #expect(bare.entries.map(\.kind) == [.term, .forgotten])
    }

    @Test("an entry spoken over several lines is stored on one")
    func multiLineValueStaysOneLine() {
        var document = MemoryDocument(file: .profile)
        document.append(MemoryEntry(kind: .profile, value: "first line\nsecond line"))
        #expect(document.lines.count == 1)
        #expect(document.entries.map(\.value) == ["first line second line"])
    }
}

@Suite("Person memory files")
struct PersonMemoryFilesTests {
    @Test("every file Hushy creates opens with a note on how to edit it, and the note is not an entry")
    func startersExplainThemselves() {
        for path in ["terms.md", "profile.md", "corrections.md", "style/app.quillpad.mail.md"] {
            var document = MemoryDocument(MemoryFiles.starter(for: path), file: MemoryFiles.file(at: path))
            let adopted = document.adopt(now: Date())
            #expect(!adopted, "\(path)")
            #expect(document.entries.isEmpty)
            #expect(document.text.hasPrefix("# "))
            #expect(document.lines.contains { $0.hasPrefix("> ") })
        }
        #expect(MemoryFiles.starter(for: "terms.md").contains("starts with a dash and a space"))
        #expect(MemoryFiles.starter(for: "terms.md").contains("## Forgotten"))
        #expect(MemoryFiles.starter(for: "profile.md").contains("starts with a dash and a space"))
    }

    @Test("a style note is filed under its app, and an unsafe app name cannot leave the folder")
    func paths() {
        #expect(MemoryFiles.path(for: MemoryEntry(kind: .style, value: "x", appBundleID: "app.quillpad.mail")) == "style/app.quillpad.mail.md")
        #expect(MemoryFiles.path(for: MemoryEntry(kind: .style, value: "x", appBundleID: "../../outside")) == "style/unknown.md")
        #expect(MemoryFiles.path(for: MemoryEntry(kind: .style, value: "x")) == "style/unknown.md")
        #expect(MemoryFiles.file(at: "style/app.quillpad.mail.md") == .style(app: "app.quillpad.mail"))
        #expect(MemoryFiles.file(at: "style/unknown.md") == .style(app: nil))
        #expect(MemoryFiles.path(for: MemoryEntry(kind: .forgotten, value: "x")) == "terms.md")
    }
}

@Suite("Person memory flag and folder")
struct PersonMemoryGateTests {
    @Test("the flag is off unless a true is stored")
    func flagDefault() throws {
        let name = "app.hushy.test.person-memory.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        #expect(!FeatureFlags.isExplicitlyOn(FeatureFlags.personMemoryKey, in: suite))
        suite.set(false, forKey: FeatureFlags.personMemoryKey)
        #expect(!FeatureFlags.isExplicitlyOn(FeatureFlags.personMemoryKey, in: suite))
        suite.set("on", forKey: FeatureFlags.personMemoryKey)
        #expect(!FeatureFlags.isExplicitlyOn(FeatureFlags.personMemoryKey, in: suite))
        suite.set(true, forKey: FeatureFlags.personMemoryKey)
        #expect(FeatureFlags.isExplicitlyOn(FeatureFlags.personMemoryKey, in: suite))
        // No test stores this key, so whichever defaults the flags read just now, it is off.
        #expect(!FeatureFlags.personMemory)
    }

    @Test("the memory folder sits inside the data folder, so a temporary home holds it too")
    func folderFollowsTheHome() {
        #expect(AppPaths.memoryDirectory == AppPaths.supportDirectory.appendingPathComponent("Memory", isDirectory: true))
    }
}
