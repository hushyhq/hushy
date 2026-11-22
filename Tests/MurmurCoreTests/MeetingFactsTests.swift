import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing
@testable import MurmurCore

/// Meeting facts with evidence (task T4): the ported extract prompt, the grounder's quote, owner and due rules, the
/// extractor's chunking and dictation yield, and the store keeping facts tied to turns and the legacy columns in step.
@Suite("Meeting facts", .timeLimit(.minutes(1)))
struct MeetingFactsTests {
    // MARK: Prompt port

    @Test("the system text is the training SYSTEM byte for byte (sha256 from build_sft.py and the SFT manifest)")
    func systemMatchesPython() {
        let digest = SHA256.hash(data: Data(MeetingExtractPrompt.system.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "3923ac147593f177d58342797fd9be2e8e7f5a1e6857694ffe73c3f0dc9d2d0a")
    }

    @Test("the user turn matches build_sft.user_turn, with and without speakers")
    func userTurnMatchesPython() {
        let labelled = MeetingExtractPrompt.userTurn(
            title: "Pilot review", kind: "call", speakers: ["Speaker 1", "You"], chunk: "1 of 2",
            transcript: "[00:05] You: We ship Friday.\n[00:09] Speaker 1: I will send the deck.")
        #expect(labelled == "Meeting: Pilot review (call)\nSpeakers: Speaker 1, You\nChunk: 1 of 2\n\nTranscript:\n[00:05] You: We ship Friday.\n[00:09] Speaker 1: I will send the deck.\n\nExtract the records.")
        let plain = MeetingExtractPrompt.userTurn(title: "T", kind: "meeting", speakers: [], chunk: "1 of 1", transcript: "hello there")
        #expect(plain == "Meeting: T (meeting)\nSpeakers: not labelled\nChunk: 1 of 1\n\nTranscript:\nhello there\n\nExtract the records.")
        #expect(MeetingExtractPrompt.stamp(3_725) == "[1:02:05] ")
        #expect(MeetingExtractPrompt.stamp(nil) == "")
    }

    @Test("chunks close at about 1,800 words on a line boundary; a short tail joins the previous chunk")
    func chunking() {
        let line = MeetingExtractPrompt.Line(speaker: "You", start: 0, text: Array(repeating: "word", count: 100).joined(separator: " "))
        let chunks = MeetingExtractPrompt.chunks(Array(repeating: line, count: 41))
        #expect(chunks.map(\.count) == [18, 23])   // 18 lines reach 1,800; the 500-word tail (< 600) joins chunk 2
        #expect(MeetingExtractPrompt.chunks(Array(repeating: line, count: 10)).count == 1)
    }

    // MARK: Grounding

    static func transcript() -> NoteTranscript {
        let turns = [
            NoteTurn(id: 11, noteId: 1, ordinal: 0, stream: .mic, speakerId: 1, t0: 10, t1: 14,
                     text: "Priya, can you send the revised deck by Friday?",
                     words: "Priya can you send the revised deck by Friday".split(separator: " ").enumerated().map {
                         NoteTurn.Word(w: String($0.element), start: 10 + Double($0.offset) * 0.4, end: 10.3 + Double($0.offset) * 0.4, conf: 1)
                     }, origin: .capture),
            NoteTurn(id: 12, noteId: 1, ordinal: 1, stream: .system, speakerId: 2, t0: 14, t1: 16, text: "Sure, I will do that.", origin: .capture),
            NoteTurn(id: 13, noteId: 1, ordinal: 2, stream: .mic, speakerId: 1, t0: 16, t1: 20, text: "Great. We ship the pilot on Monday.", origin: .capture),
        ]
        return NoteTranscript(turns: turns, names: [1: "You", 2: "Speaker 1"])
    }

    static func facts(_ records: [MeetingExtractAnswer.Record]) -> [MeetingFact] {
        let transcript = transcript()
        return MeetingFactGrounder.facts(
            records, chunk: MeetingExtractPrompt.lines(of: transcript), speakers: MeetingFactExtractor.speakers(of: transcript),
            noteId: 1, extractor: "test")
    }

    @Test("a copied quote ties the fact to its turn, its UTF-16 span and the words' times")
    func quoteEvidence() throws {
        let fact = try #require(Self.facts([.init(kind: "action", text: "Send the revised deck.", owner: "Speaker 1", due: "by Friday",
                                                 quote: "send the revised deck by Friday")]).first)
        #expect(fact.grounding == .verified)
        #expect(fact.evidenceTurnId == 11)
        #expect(fact.evidenceStart == 15)
        #expect(fact.evidenceEnd == 46)
        #expect(fact.t0 == 11.2)          // "send" is the 4th recognised word
        #expect(fact.t1.map { abs($0 - 13.5) < 0.001 } == true)
        #expect(fact.ownerText == "Speaker 1")
        #expect(fact.ownerSpeakerId == 2)
        #expect(fact.due == "by Friday")
        #expect(fact.isVisible)
    }

    @Test("a quote the turns never said is stored unsupported and hidden")
    func unsupportedQuote() throws {
        let fact = try #require(Self.facts([.init(kind: "decision", text: "Ship in March.", quote: "we ship in March")]).first)
        #expect(fact.grounding == .unsupported)
        #expect(fact.evidenceTurnId == nil)
        #expect(!fact.isVisible)
    }

    @Test("a fact whose quote is about something else keeps the quote but is hidden; digits, number words and spelled acronyms meet")
    func statementSupport() throws {
        let worded = try #require(Self.facts([.init(kind: "decision", text: "Ship the pilot Monday.", quote: "We ship the pilot on Monday")]).first)
        #expect(worded.grounding == .verified)
        let elsewhere = try #require(Self.facts([.init(kind: "decision", text: "The budget is twelve thousand euros.", quote: "Sure, I will do that.")]).first)
        #expect(elsewhere.grounding == .unsupported)
        #expect(elsewhere.quote == "Sure, I will do that.")
        #expect(!elsewhere.isVisible)
        let neighbour = try #require(Self.facts([.init(kind: "action", text: "Send the revised deck.", quote: "Sure, I will do that.")]).first)
        #expect(neighbour.grounding == .verified)   // the deck was named one turn before the quote

        let said = NoteTranscript(turns: [
            NoteTurn(id: 21, noteId: 1, ordinal: 0, stream: .mic, speakerId: 1, t0: 0, t1: 4,
                     text: "It sells for twenty five euros, and no L_C_D_.", origin: .capture),
        ], names: [1: "You"])
        let chunk = MeetingExtractPrompt.lines(of: said)
        #expect(MeetingFactGrounder.statementSupport("Sells for 25 euros, no LCD.", line: 0, in: chunk) == 1)
        #expect(MeetingFactGrounder.statementSupport("Sells for 30 euros, no LCD.", line: 0, in: chunk) < 1)
    }

    @Test("owners: a speaker label is kept, a name given the task in the turns is kept by name, anything else is blank")
    func ownerGrounding() {
        let quote = "Sure, I will do that."
        let byName = Self.facts([.init(kind: "action", text: "Send the deck.", owner: "Priya", quote: quote)])[0]
        #expect(byName.ownerText == "Priya")
        #expect(byName.ownerSpeakerId == nil)
        let invented = Self.facts([.init(kind: "action", text: "Send the deck.", owner: "Marcus", quote: quote)])[0]
        #expect(invented.ownerText == nil)
        #expect(invented.ownerClaim == "Marcus")
        let you = Self.facts([.init(kind: "action", text: "Ship it.", owner: "you", quote: "We ship the pilot on Monday")])[0]
        #expect(you.ownerText == "You")
        #expect(you.ownerSpeakerId == 1)
        let decision = Self.facts([.init(kind: "decision", text: "Ship Monday.", owner: "You", quote: "We ship the pilot on Monday")])[0]
        #expect(decision.ownerText == nil)
    }

    @Test("a due the chunk never says is dropped; repeats of one quote or one wording are kept once, in transcript order")
    func dueAndOrder() {
        let facts = Self.facts([
            .init(kind: "decision", text: "Ship Monday.", due: "next quarter", quote: "We ship the pilot on Monday"),
            .init(kind: "action", text: "Send the deck.", quote: "send the revised deck by Friday"),
            .init(kind: "decision", text: "Ship on Monday.", quote: "we ship the pilot on monday"),
            .init(kind: "decision", text: "Ship Monday.", quote: "Great."),
        ])
        #expect(facts[0].due == nil)
        let ordered = MeetingFactGrounder.ordered(facts)
        #expect(ordered.map(\.kind) == [.action, .decision])
        #expect(ordered.map(\.ordinal) == [0, 1])
    }

    // MARK: Extractor

    final class Scripted: LanguageModel, @unchecked Sendable {
        let answers: Mutex<[Result<String, any Error>]>
        let prompts = Mutex<[String]>([])
        init(_ answers: [Result<String, any Error>]) { self.answers = Mutex(answers) }
        var identifier: String { "scripted" }
        var availability: LanguageModelAvailability { .available }
        var contextTokens: Int { 32_768 }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
            prompts.withLock { $0.append(prompt) }
            #expect(schema.name == MeetingExtractPrompt.schemaName)
            #expect(instructions == MeetingExtractPrompt.instructions)
            return try answers.withLock { $0.isEmpty ? .success(#"{"records":[]}"#) : $0.removeFirst() }.get()
        }
    }

    @Test("a call a dictation cut short is asked again, not counted as failed")
    func preemptedCallRetries() async {
        let answer = #"{"records":[{"kind":"decision","text":"Ship Monday.","owner":null,"due":null,"quote":"We ship the pilot on Monday"}]}"#
        let model = Scripted([.failure(ForegroundPreempted()), .success(answer)])
        let (facts, report) = await MeetingFactExtractor(model: model).extract(Self.transcript(), noteId: 1, title: "Pilot", kind: "call")
        #expect(report.preempted == 1)
        #expect(report.failedChunks == 0)
        #expect(facts.map(\.text) == ["Ship Monday."])
        #expect(facts.first?.extractor == "scripted/extract-p1")
        let prompt = model.prompts.withLock { $0.last } ?? ""
        #expect(prompt.hasPrefix("Meeting: Pilot (call)\nSpeakers: Speaker 1, You\nChunk: 1 of 1\n\nTranscript:\n[00:10] You: Priya, can you"))
    }

    @Test("the Run A adapter on the 4B is named for the scorecard")
    func extractorName() {
        final class Named: LanguageModel, @unchecked Sendable {
            var identifier: String { "meeting>mlx:hushy-cleanup-4b-r10d-6bit+lora:meeting-extract-v1c" }
            var availability: LanguageModelAvailability { .available }
            func supportsLanguage(_ languageCode: String) -> Bool { true }
            func prewarm(instructions: String) {}
            func prefixCache(instructions: String) async {}
            func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String { "" }
        }
        #expect(MeetingFactExtractor.extractorName(for: Named()) == "r10d+meeting-extract-v1c/p1")
        #expect(MeetingExtractAdapter.fits(entryID: ModelRegistry.hushyCleanup4B))
        #expect(!MeetingExtractAdapter.fits(entryID: ModelRegistry.hushyCleanup2BIntent))
    }

    // MARK: Store

    private func meeting(_ store: Store) throws -> Int64 {
        let id = try store.save(Note(title: "Pilot", transcript: "", status: .ready)).id!
        try store.replaceTurns(noteId: id, turns: Self.transcript().turns.map {
            var turn = $0
            turn.speakerId = nil
            return turn
        })
        return id
    }

    private func extracted(_ store: Store, noteId: Int64) throws -> [MeetingFact] {
        let transcript = try store.transcript(noteId: noteId)
        let facts = MeetingFactGrounder.ordered(MeetingFactGrounder.facts([
            .init(kind: "action", text: "Send the revised deck.", owner: "Speaker 1", due: "by Friday", quote: "send the revised deck by Friday"),
            .init(kind: "decision", text: "Ship the pilot on Monday.", quote: "We ship the pilot on Monday"),
        ], chunk: MeetingExtractPrompt.lines(of: transcript), speakers: MeetingFactExtractor.speakers(of: transcript), noteId: noteId,
           extractor: "test"))
        return try store.replaceModelFactsAndCache(noteId: noteId, extractor: "test", facts: facts)
    }

    @Test("an extraction rewrites the legacy columns from the visible actions, and check-offs stay in step both ways")
    func legacyColumnsFollowFacts() throws {
        let store = try Store()
        let id = try meeting(store)
        let inserted = try extracted(store, noteId: id)
        #expect(try store.note(id: id)?.actionItems == ["Speaker 1: Send the revised deck — by Friday"])
        let action = try #require(inserted.first { $0.kind == .action })
        #expect(try store.setActionFactDone(uuid: action.uuid, isDone: true))
        #expect(try store.doneActionItemIndexes(noteId: id) == [0])
        try store.setActionItemDone(noteId: id, itemIndex: 0, isDone: false)
        #expect(try store.facts(noteId: id).first { $0.kind == .action }?.status == .open)
    }

    @Test("re-assembly gives every turn a new id; facts find their quote again and never point at a wrong turn")
    func reresolveAfterReassembly() throws {
        let store = try Store()
        let id = try meeting(store)
        _ = try extracted(store, noteId: id)
        let before = try store.facts(noteId: id)
        // A retry rebuilt the turns: same words, new rows, and the decision's turn now says something else.
        var turns = try store.turns(noteId: id)
        turns[2].text = "Great. Let's decide the date later."
        try store.replaceTurns(noteId: id, turns: turns)
        let after = try store.facts(noteId: id)
        let newIds = Set(try store.turns(noteId: id).compactMap(\.id))
        let action = try #require(after.first { $0.kind == .action })
        #expect(action.evidenceTurnId.map(newIds.contains) == true)
        #expect(action.evidenceTurnId != before.first { $0.kind == .action }?.evidenceTurnId)
        #expect(action.evidenceStart == 15)
        let decision = try #require(after.first { $0.kind == .decision })
        #expect(decision.evidenceTurnId == nil)
        #expect(decision.t0 == before.first { $0.kind == .decision }?.t0)
    }

    @Test("Markdown, MCP get_note and the recap show visible facts with [mm:ss] links and quotes; no Decided lines")
    func readersShowFacts() throws {
        let store = try Store()
        let id = try meeting(store)
        var note = try #require(try store.note(id: id))
        note.summary = "- Pilot scope\n- Decided: an old decision line"
        _ = try store.update(note)
        _ = try extracted(store, noteId: id)
        note = try #require(try store.note(id: id))
        let markdown = MarkdownExporter.markdown(for: note, transcript: try store.transcript(noteId: id), facts: try store.facts(noteId: id))
        #expect(markdown.contains("## Decisions\n\n- Ship the pilot on Monday [00:16](hushy://note/\(id)?t=16)\n  > We ship the pilot on Monday"))
        #expect(markdown.contains("## Action items\n\n- [ ] Speaker 1: Send the revised deck — by Friday [00:11](hushy://note/\(id)?t=11)"))
        #expect(!markdown.contains("Decided:"))
        #expect(markdown.contains("- Pilot scope"))
        let server = MCPServer(reader: store.writer, scope: .notes, now: { Date() })
        let line = try #require(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_note","arguments":{"id":\#(id)}}}"#))
        #expect(line.contains("hushy://note/\(id)?t=16"))
        let recap = try #require(MeetingRecap.make(from: note, facts: try store.facts(noteId: id)))
        #expect(recap.decisions == ["Ship the pilot on Monday (00:16)"])
        #expect(recap.plainText.contains("Decisions\n- Ship the pilot on Monday (00:16)"))
        let record = try #require(try store.meetingRecords().first { $0.noteId == id })
        #expect(record.decisions == ["Ship the pilot on Monday."])
        #expect(record.keyPoints == ["Pilot scope"])
        #expect(record.actionItems.map(\.owner) == ["Speaker 1"])
    }

    @Test("renaming a speaker renames the owner of their facts")
    func renameFollows() throws {
        let store = try Store()
        let id = try store.save(Note(title: "Pilot", transcript: "", status: .ready)).id!
        let assembly = TurnAssembler.assemble(
            mic: [WordTiming(word: "Reply?", start: 0, end: 0.5)], system: [WordTiming(word: "Sure", start: 1, end: 1.5)],
            isTwoChannel: true, micTurns: [], systemTurns: [], ownerName: nil, clean: { $0 })
        _ = try store.replaceAssembly(noteId: id, assembly: assembly)
        let transcript = try store.transcript(noteId: id)
        let other = try #require(MeetingFactExtractor.speakers(of: transcript).first { $0.label == "Speaker 1" })
        let facts = MeetingFactGrounder.facts([.init(kind: "action", text: "Reply.", owner: "Speaker 1", quote: "Sure")],
                                              chunk: MeetingExtractPrompt.lines(of: transcript), speakers: [other], noteId: id, extractor: "test")
        try store.replaceModelFactsAndCache(noteId: id, extractor: "test", facts: facts)
        try store.renameSpeakerUpdatingDigest(id: try #require(other.speakerId), to: "Priya")
        #expect(try store.facts(noteId: id).first?.ownerText == "Priya")
        #expect(try store.note(id: id)?.actionItems == ["Priya: Reply"])
    }
}
