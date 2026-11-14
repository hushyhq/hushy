import Foundation
import Testing
@testable import MurmurCore

/// The block's shape is the user turn the rewrite model was trained on
/// (`Evals/finetune-prompts/intent-call-system-v3.txt` on the retrain branch). All text is invented.
@Suite("Person block")
struct PersonBlockTests {
    @Test("every line known: the heading, then the five lines in the trained order")
    func fullBlockMatchesTrainingShape() {
        let block = PersonBlock(
            profile: "short sentences", style: "friendly", terms: ["Veloria", "Nerula", "Tarrow Ridge"],
            earlier: ["Meet at noon", "Bring the map"], edits: [("Hello.", "Hello!"), ("nerula", "Nerula")],
            screen: "Quillpad - Reply to the Veloria team\nThanks for the update.\nSee you on the ridge.")
        #expect(block.render() == """
        About this person
        How they write: short sentences; friendly
        Words they use: Veloria; Nerula; Tarrow Ridge
        Just before, in this app: "Meet at noon" / "Bring the map"
        Their edits: "Hello." -> "Hello!" / "nerula" -> "Nerula"
        On screen: Quillpad - Reply to the Veloria team
        Thanks for the update.
        See you on the ridge.
        """)
        #expect(block.usedLines == 5)
    }

    @Test("nothing known, or only blank text: no block at all")
    func nilWhenEmpty() {
        #expect(PersonBlock().render() == nil)
        #expect(PersonBlock().usedLines == 0)
        #expect(PersonBlock(profile: " ", style: "\n", terms: ["", "  "], earlier: [" "],
                            edits: [("", "Hello!"), ("Hello.", " ")], screen: " \n ").render() == nil)
    }

    @Test("each line is left out when its part is unknown")
    func linesOmittedWhenUnknown() {
        #expect(PersonBlock(profile: "short sentences").render() == "About this person\nHow they write: short sentences")
        #expect(PersonBlock(style: "friendly").render() == "About this person\nHow they write: friendly")
        #expect(PersonBlock(terms: ["Veloria"]).render() == "About this person\nWords they use: Veloria")
        #expect(PersonBlock(earlier: ["Meet at noon"]).render() == "About this person\nJust before, in this app: \"Meet at noon\"")
        #expect(PersonBlock(edits: [("Hello.", "Hello!")]).render() == "About this person\nTheir edits: \"Hello.\" -> \"Hello!\"")
        #expect(PersonBlock(screen: "window and nearby text").render() == "About this person\nOn screen: window and nearby text")
        let partial = PersonBlock(terms: ["Veloria"], edits: [("Hello.", "Hello!")])
        #expect(partial.render() == "About this person\nWords they use: Veloria\nTheir edits: \"Hello.\" -> \"Hello!\"")
        #expect(partial.usedLines == 2)
    }

    @Test("the trained limits hold: 11 words, 3 earlier dictations, 3 edits")
    func limits() throws {
        let block = PersonBlock(terms: (1...14).map { "Veloria\($0)" },
                                earlier: (1...5).map { "Meet at \($0)" },
                                edits: (1...5).map { ("Hello \($0).", "Hello \($0)!") })
        let lines = try #require(block.render()).components(separatedBy: "\n")
        #expect(lines[1].components(separatedBy: "; ").count == 11)
        #expect(lines[1].hasSuffix("Veloria11"))
        // Earlier dictations run oldest first, so the three kept are the last three.
        #expect(lines[2] == "Just before, in this app: \"Meet at 3\" / \"Meet at 4\" / \"Meet at 5\"")
        #expect(lines[3] == "Their edits: \"Hello 3.\" -> \"Hello 3!\" / \"Hello 4.\" -> \"Hello 4!\" / \"Hello 5.\" -> \"Hello 5!\"")
    }

    @Test("quoted parts cannot close their own quotes; other lines and the screen text keep theirs")
    func whitespaceAndQuotes() {
        let block = PersonBlock(profile: "writes \"ok\"\n in quotes", terms: ["the \"Veloria\" plan"],
                                earlier: ["She said \"noon\"\nthen left"], edits: [("say \"hi\"", "Say \"hi\".")],
                                screen: "  Quillpad  \"Drafts\" \n\n  first   line\r\nsecond \"line\"  ")
        #expect(block.render() == """
        About this person
        How they write: writes "ok" in quotes
        Words they use: the "Veloria" plan
        Just before, in this app: "She said 'noon' then left"
        Their edits: "say 'hi'" -> "Say 'hi'."
        On screen: Quillpad  "Drafts"
        first   line
        second "line"
        """)
        #expect(block.usedLines == 5)
    }
}

@Suite("Person block assembly")
struct PersonBlockAssemblerTests {
    private static let app = "app.quillpad.mail"
    private static let noon = Date(timeIntervalSince1970: 1_778_587_200)

    @Test("a missed or paused preparation yields no block")
    func missedOrPausedPrepare() {
        let index = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "Veloria")])
        let ready = PersonBlockAssembler.Prepared(index: index, app: Self.app, earlier: [], paused: false)
        let paused = PersonBlockAssembler.Prepared(index: index, app: Self.app, earlier: [], paused: true)
        #expect(PersonBlockAssembler.finish(nil, transcript: "Veloria") == nil)
        #expect(PersonBlockAssembler.finish(paused, transcript: "Veloria") == nil)
        #expect(PersonBlockAssembler.finish(ready, transcript: "Veloria")?.terms == ["Veloria"])
    }

    @Test("nothing recalled and nothing stored: no block")
    func nothingKnown() {
        let index = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "Veloria")])
        let prepared = PersonBlockAssembler.Prepared(index: index, app: Self.app, earlier: [], paused: false)
        #expect(PersonBlockAssembler.finish(prepared, transcript: "see you at noon") == nil)
    }

    @Test("the block is built from the folder and today's dictations in this app only")
    func assembledFromStoreAndHistory() async throws {
        let root = try TemporaryMemoryRoot()
        defer { root.remove() }
        let memory = root.store()
        let history = try Store()
        try await seed(memory)
        for (offset, app, text) in [(-900.0, Self.app, "Too long ago"), (-600.0, Self.app, "Pack a coat"),
                                    (-300.0, Self.app, "Meet at noon"), (-60.0, Self.app, "Bring the map"),
                                    (-30.0, "app.lumen.notes", "Somewhere else")] {
            _ = try history.save(Dictation(createdAt: Self.noon.addingTimeInterval(offset), rawText: text, text: text,
                                           appBundleID: app, durationSeconds: 1, status: .inserted))
        }
        let prepared = try await PersonBlockAssembler.prepare(memory: memory, history: history, app: Self.app, now: Self.noon)
        #expect(prepared.earlier == ["Pack a coat", "Meet at noon", "Bring the map"])
        let block = try #require(PersonBlockAssembler.finish(prepared, transcript: "tell the valoria team about nerula"))
        // Earlier dictations oldest first: the newest is nearest the transcript.
        #expect(block.render() == """
        About this person
        How they write: short sentences; no exclamation marks; lower case, one line
        Words they use: Veloria; Nerula
        Just before, in this app: "Pack a coat" / "Meet at noon" / "Bring the map"
        Their edits: "hello." -> "Hello!"
        """)
    }

    private func seed(_ memory: MemoryStore) async throws {
        let old = Self.noon.addingTimeInterval(-86_400)
        try await memory.add(MemoryEntry(kind: .profile, value: "short sentences"))
        try await memory.add(MemoryEntry(kind: .profile, value: "no exclamation marks"))
        try await memory.add(MemoryEntry(kind: .style, value: "lower case, one line", appBundleID: Self.app))
        try await memory.add(MemoryEntry(kind: .style, value: "long paragraphs", appBundleID: "app.lumen.notes"))
        try await memory.add(MemoryEntry(kind: .term, value: "Veloria", heardAs: ["Valoria"], createdAt: old))
        try await memory.add(MemoryEntry(kind: .term, value: "Nerula", createdAt: old))
        try await memory.add(MemoryEntry(kind: .term, value: "Tavren Ridge", createdAt: old))
        try await memory.add(MemoryEntry(kind: .correction, value: "", appBundleID: Self.app, before: "hello.", after: "Hello!"))
        try await memory.add(MemoryEntry(kind: .correction, value: "", appBundleID: "app.lumen.notes",
                                         before: "tavren", after: "Tavren"))
    }
}

@Suite("Earlier dictations in this app")
struct RecentInAppTests {
    @Test("same app, same local day, inserted, not later than now, newest first, three at most")
    func sameAppSameDayInsertedOnly() throws {
        let history = try Store()
        let calendar = Calendar(identifier: .gregorian)
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12)))
        let rows: [(TimeInterval, String, Dictation.Status, String)] = [
            (-10, "app.quillpad.mail", .inserted, "newest"), (-20, "app.quillpad.mail", .cancelled, "cancelled"),
            (-30, "app.quillpad.mail", .failed, "failed"), (-40, "app.quillpad.mail", .notInserted, "not pasted"),
            (-50, "app.lumen.notes", .inserted, "other app"), (3_600, "app.quillpad.mail", .inserted, "later today"),
            (-86_400, "app.quillpad.mail", .inserted, "yesterday"), (86_400, "app.quillpad.mail", .inserted, "tomorrow"),
            (-60, "app.quillpad.mail", .inserted, "second"), (-70, "app.quillpad.mail", .inserted, "third"),
            (-80, "app.quillpad.mail", .inserted, "fourth"),
        ]
        for (offset, app, status, text) in rows {
            _ = try history.save(Dictation(createdAt: noon.addingTimeInterval(offset), rawText: text, text: text,
                                           appBundleID: app, durationSeconds: 1, status: status))
        }
        let recent = try history.recentInApp("app.quillpad.mail", on: noon, calendar: calendar)
        #expect(recent.map(\.text) == ["newest", "second", "third"])
        #expect(try history.recentInApp("app.quillpad.mail", on: noon, limit: 1, calendar: calendar).map(\.text) == ["newest"])
        #expect(try history.recentInApp("app.quillpad.mail", on: noon, limit: 9, calendar: calendar).count == 3)
        #expect(try history.recentInApp("app.quillpad.mail", on: noon, limit: 0, calendar: calendar).isEmpty)
        #expect(try history.recentInApp("app.unknown", on: noon, calendar: calendar).isEmpty)
    }
}
