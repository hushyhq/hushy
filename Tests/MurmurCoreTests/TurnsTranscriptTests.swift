import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Turns are the only transcript (meetings schema freeze section 4, notes audit B2): the cache is the
/// rendered turns, both sides of a call reach search, export, recap and MCP, and names follow the rule.
@Suite("Turns are the only transcript")
struct TurnsTranscriptTests {
    func turn(_ stream: NoteTurn.Stream, _ text: String, at t0: Double, speaker: Int64? = nil) -> NoteTurn {
        NoteTurn(noteId: 0, ordinal: 0, stream: stream, speakerId: speaker, t0: t0, t1: t0 + 5, text: text, origin: .capture)
    }

    /// A ready two-channel note: the owner on the mic, one other person on the call.
    func twoChannelNote(_ store: Store) throws -> Int64 {
        let id = try #require(try store.save(Note(title: "Pricing call", status: .ready)).id)
        try store.appendTurns(noteId: id, turns: [
            turn(.mic, "Can you send the contract today?", at: 0),
            turn(.system, "Yes, the procurement team signs it by Thursday.", at: 6),
            turn(.mic, "Great, thanks.", at: 12),
        ])
        return id
    }

    @Test("one voice reads as plain text; several voices read as labelled lines, consecutive turns merged")
    func rendering() {
        let memo = NoteTranscript(turns: [turn(.mic, "First part.", at: 0), turn(.mic, "Second part.", at: 30)])
        #expect(memo.rendered == "First part. Second part.")
        #expect(!memo.hasSeveralVoices)
        let call = NoteTranscript(turns: [
            turn(.mic, "Hello.", at: 0), turn(.mic, "Can you hear me?", at: 2), turn(.system, "Yes.", at: 4),
            turn(.mic, "", at: 6),
        ])
        #expect(call.rendered == "You: Hello. Can you hear me?\nSpeaker 1: Yes.")
        #expect(call.plainText == "Hello. Can you hear me? Yes.")
    }

    @Test("names: the person's own name, then the mic owner, then a guess at 0.8 or more, else the label")
    func nameRule() {
        let speaker = NoteSpeaker(id: 7, noteId: 1, label: "Speaker 2")
        func assignment(_ name: String, _ source: SpeakerAssignment.Source, _ confidence: Double) -> SpeakerAssignment {
            SpeakerAssignment(speakerId: 7, noteId: 1, name: name, source: source, confidence: confidence)
        }
        #expect(SpeakerNameRule.name(for: speaker, assignments: []) == "Speaker 2")
        #expect(SpeakerNameRule.name(for: speaker, assignments: [assignment("Dana", .ax, 0.7)]) == "Speaker 2")
        #expect(SpeakerNameRule.name(for: speaker, assignments: [assignment("Dana", .ax, 0.7), assignment("Lee", .calendar, 0.9)]) == "Lee")
        #expect(SpeakerNameRule.name(for: speaker, assignments: [assignment("Lee", .calendar, 0.9), assignment("Sam", .micChannel, 1)]) == "Sam")
        var named = speaker
        named.displayName = "Priya"
        #expect(SpeakerNameRule.name(for: named, assignments: [assignment("Sam", .micChannel, 1)]) == "Priya")
    }

    @Test("saving a stored note never writes its transcript; a new note's text becomes one legacy turn")
    func saveLeavesTheCache() throws {
        let store = try Store()
        let id = try twoChannelNote(store)
        let cache = try #require(try store.note(id: id)).transcript
        var stale = try #require(try store.note(id: id))
        stale = stale.caching(NoteTranscript(turns: [turn(.mic, "stale words", at: 0)]))
        stale.title = "Renamed"
        let saved = try store.save(stale)
        #expect(saved.transcript == cache)
        #expect(try store.note(id: id)?.transcript == cache)
        #expect(try store.update(stale)?.transcript == cache)

        let fresh = try store.save(Note(title: "Imported", transcript: "Typed words."))
        let turns = try store.turns(noteId: try #require(fresh.id))
        #expect(turns.map(\.origin) == [.legacy])
        #expect(turns.first?.text == "Typed words.")
        #expect(fresh.transcript == "Typed words.")
    }

    @Test("both sides of a call are in the cache, search, Markdown, Apple-Notes-style recap and MCP get_note")
    func bothSidesEverywhere() throws {
        let store = try Store()
        let id = try twoChannelNote(store)
        let note = try #require(try store.note(id: id))
        let transcript = try store.transcript(noteId: id)
        #expect(note.transcript == transcript.rendered)
        #expect(note.transcript.contains("Speaker 1: Yes, the procurement team signs it by Thursday."))
        #expect(TranscriptInvariant.check(cache: note.transcript, transcript: transcript).holds)

        #expect(try store.searchNotes("procurement").map(\.id) == [id])
        #expect(MarkdownExporter.markdown(for: note, transcript: transcript).contains("procurement team"))
        let recap = try #require(MeetingRecap.make(from: note, turns: transcript, includeTranscript: true))
        #expect(recap.transcript?.contains("procurement team") == true)

        let server = MCPServer(reader: store.writer, scope: .notes, now: { Date() })
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_note","arguments":{"id":\#(id)}}}"#
        let line = try #require(server.handle(line: json))
        #expect(line.contains("procurement team") && line.contains("contract today"))

        let rows = transcript.timedRows(noteId: id)
        #expect(Set(rows.compactMap(\.speaker?.label)) == ["You", "Speaker 1"])
        #expect(SubtitleFormatter.srt(cues: SubtitleFormatter.cues(from: rows)).contains("procurement"))
    }

    @Test("a turn found only by its own index still finds the note")
    func turnIndexFindsTheNote() throws {
        let store = try Store()
        let id = try twoChannelNote(store)
        // Simulate a cache that lags its turns: the turn index alone must answer.
        try store.writer.write { db in try db.execute(sql: "UPDATE note SET transcript = '' WHERE id = ?", arguments: [id]) }
        #expect(try store.searchNotes("procurement").map(\.id) == [id])
    }

    @Test("renaming and merging speakers rewrite the cache in the same transaction")
    func speakerChangesFollow() throws {
        let store = try Store()
        let id = try #require(try store.save(Note(title: "Room", status: .ready)).id)
        let speakers = try store.replaceSpeakerSegments(
            noteId: id, speakers: [NoteSpeaker(noteId: id, label: "Speaker 1"), NoteSpeaker(noteId: id, label: "Speaker 2")],
            segments: [])
        let (a, b) = (try #require(speakers[0].id), try #require(speakers[1].id))
        try store.replaceTurns(noteId: id, turns: [
            turn(.mic, "Budget is fine.", at: 0, speaker: a), turn(.mic, "Then ship it.", at: 5, speaker: b),
        ])
        #expect(try store.note(id: id)?.transcript == "Speaker 1: Budget is fine.\nSpeaker 2: Then ship it.")
        try store.renameSpeakerUpdatingDigest(id: b, to: "Marcus")
        #expect(try store.note(id: id)?.transcript == "Speaker 1: Budget is fine.\nMarcus: Then ship it.")
        try store.mergeSpeakersUpdatingDigest(sourceId: a, intoTargetId: b)
        #expect(try store.note(id: id)?.transcript == "Budget is fine. Then ship it.")
        #expect(try store.turns(noteId: id).map(\.speakerId) == [b, b])
    }

    @Test("an assembly replaces speakers, segments and turns, and names the mic owner")
    func replaceAssembly() throws {
        let store = try Store()
        let id = try #require(try store.save(Note(title: "Call", status: .ready)).id)
        let assembly = TurnAssembler.assemble(
            mic: [WordTiming(word: "hello", start: 0, end: 0.4), WordTiming(word: "there", start: 0.5, end: 0.9)],
            system: [WordTiming(word: "hi", start: 1.2, end: 1.5)], isTwoChannel: true, ownerName: "Sam")
        #expect(try store.replaceAssembly(noteId: id, assembly: assembly))
        #expect(try store.note(id: id)?.transcript == "Sam: hello there\nSpeaker 1: hi")
        #expect(try store.noteSegments(noteId: id).map(\.segment.text) == ["hello there", "hi"])
        #expect(try !store.replaceAssembly(noteId: 9_999, assembly: assembly))
    }

    @Test("a 1:1 call names the other voice after the one other attendee; a group call does not guess")
    func oneToOneFromCalendar() throws {
        let store = try Store()
        let id = try #require(try store.save(Note(title: "1:1", status: .ready)).id)
        try store.writer.write { db in
            try NoteAttendee(noteId: id, ordinal: 0, name: "Sam Lee", companyDomain: nil, isSelf: true).insert(db)
            try NoteAttendee(noteId: id, ordinal: 1, name: "Priya Shah", companyDomain: nil, isSelf: false).insert(db)
        }
        let call = TurnAssembler.assemble(
            mic: [WordTiming(word: "ready?", start: 0, end: 0.4)], system: [WordTiming(word: "yes", start: 1, end: 1.3)],
            isTwoChannel: true, ownerName: "Sam")
        try store.replaceAssembly(noteId: id, assembly: call)
        #expect(try store.note(id: id)?.transcript == "Sam: ready?\nPriya Shah: yes")

        let group = TurnAssembler.assemble(
            mic: [WordTiming(word: "ready?", start: 0, end: 0.4)],
            system: [WordTiming(word: "yes", start: 1, end: 1.3), WordTiming(word: "no", start: 5, end: 5.3)],
            isTwoChannel: true, systemTurns: [DiarizationTurn(speakerLabel: "A", start: 0.9, end: 1.4), DiarizationTurn(speakerLabel: "B", start: 4.9, end: 5.4)],
            ownerName: "Sam")
        try store.replaceAssembly(noteId: id, assembly: group)
        #expect(try store.note(id: id)?.transcript == "Sam: ready?\nSpeaker 1: yes\nSpeaker 2: no")
    }

    @Test("a silent part is a gap, never a failure; a part with speech and no words is (notes audit B1)")
    func silentPartsAreGaps() {
        #expect(!NoteTurn.isFailedPart(text: "", otherStreamPresent: false, hasSpeech: false))
        #expect(NoteTurn.isFailedPart(text: " ", otherStreamPresent: false, hasSpeech: true))
        #expect(!NoteTurn.isFailedPart(text: "", otherStreamPresent: true, hasSpeech: true))
        #expect(!NoteTurn.isFailedPart(text: "words", otherStreamPresent: false, hasSpeech: true))
        // A quiet tail of room noise, as the gate sees it.
        let roomNoise = (0..<16_000).map { Float(sin(Double($0))) * 0.0002 }
        #expect(!SpeechGate.evaluate(roomNoise).hasSpeech)
        // A listen-only call (the mic said nothing) still finishes ready from the other side's words.
        #expect(Note.finalizedStatus(transcript: "Speaker 1: we sign Thursday", chunkFailed: false, persistenceFailed: false) == .ready)
    }

    @Test("no code writes note.transcript except the materializer, the insert of a new note and the in-memory cache copy")
    func singleWriter() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let allowed: Set<String> = ["Store.swift", "Models.swift", "Store+Transcript.swift"]
        var writers: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !allowed.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: #"\b(note|copy|updated|writing|stale|row|saved)\.transcript\s*(\+)?=[^=]"#, options: .regularExpression) != nil
                || line.contains("SET transcript") {
                writers.append("\(url.lastPathComponent):\(number + 1)")
            }
        }
        #expect(writers.isEmpty, "other writers of the transcript cache: \(writers)")
    }
}
