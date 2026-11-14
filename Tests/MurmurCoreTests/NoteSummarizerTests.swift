import Foundation
import Synchronization
import Testing
@testable import MurmurCore

@Suite("Transcript chunker")
struct TranscriptChunkerTests {
    static func meeting(turns: Int, wordsPerTurn: Int = 20) -> String {
        (0..<turns).map { turn in
            let speaker = ["Priya", "Speaker 2", "You"][turn % 3]
            let words = (0..<wordsPerTurn).map { "t\(turn)w\($0)" }.joined(separator: " ")
            return "\(speaker): \(words)."
        }.joined(separator: "\n")
    }

    @Test("a transcript that fits is one piece, unchanged")
    func fits() {
        let text = Self.meeting(turns: 3)
        #expect(TranscriptChunker.chunks(text, maxWords: 100) == [text])
    }

    @Test("pieces cut at turn starts, keep labels, and overlap")
    func turnsAndOverlap() {
        let text = Self.meeting(turns: 30)  // 600 words
        let pieces = TranscriptChunker.chunks(text, maxWords: 200, overlapWords: 50)
        #expect(pieces.count >= 3)
        for piece in pieces {
            #expect(TextStats.wordCount(piece.replacingOccurrences(of: "Speaker 2:", with: "S2:")) <= 200 + 20)
            // Every line keeps a speaker label, even when a piece starts mid-turn.
            #expect(piece.split(separator: "\n").allSatisfy { $0.hasPrefix("Priya: ") || $0.hasPrefix("Speaker 2: ") || $0.hasPrefix("You: ") })
        }
        // Consecutive pieces share words (the overlap) and together cover every word.
        let first = Set(pieces[0].split(separator: " ")), second = Set(pieces[1].split(separator: " "))
        #expect(!first.intersection(second).filter { $0.hasPrefix("t") }.isEmpty)
        let covered = Set(pieces.flatMap { $0.split(whereSeparator: \.isWhitespace) })
        #expect(covered.contains("t29w19."))
        #expect(covered.contains("t0w0"))
    }

    @Test("plain text without labels is split at sentence ends")
    func plain() {
        let text = (0..<60).map { "Sentence number \($0) has six words." }.joined(separator: " ")
        let pieces = TranscriptChunker.chunks(text, maxWords: 100, overlapWords: 0)
        #expect(pieces.count == 4)
        #expect(pieces.allSatisfy { $0.hasSuffix(".") })
    }

    @Test("label parsing: names, speaker numbers, You; ordinary colons are not labels")
    func labels() {
        #expect(TranscriptChunker.split("Speaker 12: hi there").speaker == "Speaker 12")
        #expect(TranscriptChunker.split("You: okay").speaker == "You")
        #expect(TranscriptChunker.split("Dr. Patel: fine").speaker == "Dr. Patel")
        #expect(TranscriptChunker.split("the ratio is 3:1 today").speaker == nil)
        #expect(TranscriptChunker.split("we said this and that and more: yes").speaker == nil)
    }
}

@Suite("Note digest merge")
struct NoteDigestMergeTests {
    @Test("action items render as 'Owner: Task — due', without placeholder owners")
    func render() {
        #expect(NoteDigestMerge.render(DigestActionItem(owner: "Priya", task: "send the deck to legal.", due: "Friday")) == "Priya: Send the deck to legal — Friday")
        #expect(NoteDigestMerge.render(DigestActionItem(owner: "Unassigned", task: "Book the room", due: "")) == "Book the room")
        #expect(NoteDigestMerge.render(DigestActionItem(owner: "Marcus", task: "Fix it by Wednesday", due: "Wednesday")) == "Marcus: Fix it by Wednesday")
    }

    @Test("the summary lists key points, then decisions")
    func output() {
        let digest = MeetingDigest(
            title: "Sprint planning.", keyPoints: ["Crash rate dropped"], decisions: ["Release moves to the 19th"],
            actionItems: [DigestActionItem(owner: "Leo", task: "Write the test plan", due: "")])
        let output = NoteDigestMerge.output(digest, fallbackTitle: "Note")
        #expect(output.title == "Sprint planning")
        #expect(output.summary == "- Crash rate dropped\n- Decided: Release moves to the 19th")
        #expect(output.actionItems == ["Leo: Write the test plan"])
    }

    @Test("items repeated by the overlap are dropped from the later piece")
    func overlap() {
        let item = DigestActionItem(owner: "Dana", task: "Send the onboarding mockups to Marcus", due: "Friday")
        let parts = [
            MeetingPartNotes(decisions: ["Three-screen onboarding"], actionItems: [item], changes: [], keyPoints: []),
            MeetingPartNotes(decisions: ["Three-screen onboarding"], actionItems: [item, DigestActionItem(owner: "Leo", task: "Write the test plan", due: "")], changes: [], keyPoints: []),
        ]
        let deduped = NoteDigestMerge.dedupedAcrossOverlap(parts)
        #expect(deduped[1].actionItems.map(\.owner) == ["Leo"])
        #expect(deduped[1].decisions.isEmpty)
    }

    @Test("the deterministic merge keeps the later version of a task and every part's key points")
    func deterministic() {
        let parts = [
            MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "Kenji", task: "Inventory the legacy cron jobs", due: "Friday")], changes: [], keyPoints: ["a1", "a2", "a3"]),
            MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "Samir", task: "Inventory the legacy cron jobs", due: "Monday")], changes: [], keyPoints: ["b1"]),
        ]
        let merged = NoteDigestMerge.merge(parts)
        #expect(merged.actionItems == [DigestActionItem(owner: "Samir", task: "Inventory the legacy cron jobs", due: "Monday")])
        #expect(merged.keyPoints.prefix(2) == ["a1", "b1"])
    }

    @Test("merge input lists every part in order with its changes")
    func mergeInput() {
        let text = NoteDigestMerge.render([
            MeetingPartNotes(decisions: ["Use Toast"], actionItems: [], changes: [], keyPoints: ["POS options"]),
            MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "", task: "Get heater quote", due: "")], changes: ["Sidewalk permit cancelled"], keyPoints: []),
        ])
        #expect(text.contains("Part 1 of 2:\nDecisions:\n- Use Toast"))
        #expect(text.contains("Part 2 of 2:\nChanges:\n- Sidewalk permit cancelled"))
        #expect(text.hasSuffix("Action items noted during the meeting, in order:\n1. (no owner): Get heater quote [part 2]"))
    }

    @Test("the merge answer drops (with evidence) and updates numbered items; everything else stays")
    func applyMerge() {
        let parts = [
            MeetingPartNotes(decisions: [], actionItems: [
                DigestActionItem(owner: "Omar", task: "Pull the sync error logs", due: "tomorrow"),
                DigestActionItem(owner: "Hannah", task: "Draft the apology email", due: "Thursday"),
            ], changes: [], keyPoints: []),
            MeetingPartNotes(decisions: [], actionItems: [DigestActionItem(owner: "Leo", task: "Set up the Slack alert", due: "")], changes: ["Log pull cancelled", "Alert goes to Marcus"], keyPoints: []),
        ]
        let merge = MeetingMerge(title: "Sync", keyPoints: ["k"], decisions: ["d"], dropItems: [1, 2, 9],
                                 updates: [DigestItemUpdate(item: 3, owner: "Marcus", due: "tomorrow"), DigestItemUpdate(item: 7, owner: "X", due: "")])
        let digest = NoteDigestMerge.apply(merge, to: parts)
        #expect(digest.actionItems == [
            DigestActionItem(owner: "Hannah", task: "Draft the apology email", due: "Thursday"),
            DigestActionItem(owner: "Marcus", task: "Set up the Slack alert", due: "tomorrow"),
        ])
    }

    @Test("numbered labels take the name most pieces gave them; clashes stay labels")
    func speakerNames() {
        let parts = [
            MeetingPartNotes(speakers: [SpeakerName(label: "Speaker 2", name: "Ben"), SpeakerName(label: "Speaker 3", name: "Aisha")],
                             decisions: [], actionItems: [DigestActionItem(owner: "Speaker 2", task: "Draft the pairing exercise", due: "")], changes: [], keyPoints: []),
            MeetingPartNotes(speakers: [SpeakerName(label: "Speaker 2", name: "Ben"), SpeakerName(label: "Speaker 1", name: "Aisha"), SpeakerName(label: "Priya", name: "Priya")],
                             decisions: [], actionItems: [], changes: [], keyPoints: []),
        ]
        #expect(NoteDigestMerge.speakerNames(parts) == ["Speaker 2": "Ben"])
        #expect(NoteDigestMerge.namingOwners(parts)[0].actionItems[0].owner == "Ben")
    }
}

@Suite("Note summarizer")
struct NoteSummarizerTests {
    static let longTranscript = TranscriptChunkerTests.meeting(turns: 200)  // 4,000 words

    @Test("a small window maps every piece, then merges once")
    func mapReduce() async {
        let model = ScriptedDigestModel(contextTokens: 4_096)
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(report.strategy == .mapReduce)
        #expect(report.pieces == 3)
        #expect(model.schemas == ["MeetingPartNotes", "MeetingPartNotes", "MeetingPartNotes", "MeetingMerge"])
        #expect(output.title == "Merged")
        // The merge saw the last piece's notes, not only the first's.
        #expect(model.prompts.last?.contains("Part 3 of 3:") == true)
        #expect(model.options.allSatisfy { $0 == .greedy })
    }

    @Test("a failed call is retried with sampling, not greedy again")
    func retrySamples() async {
        let model = ScriptedDigestModel(contextTokens: 4_096, failPiece: 2)
        _ = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(model.options.filter { $0 == .systemDefault }.count == 1)
    }

    @Test("a large window maps bigger pieces instead of one call over the whole meeting")
    func largeWindowPieces() async {
        let model = ScriptedDigestModel(contextTokens: 262_144)
        let (_, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(report.strategy == .mapReduce)
        #expect(report.pieces == 2)
        #expect(NoteSummarizer.pieceWords(contextTokens: 4_096) == 1_500)
        #expect(NoteSummarizer.pieceWords(contextTokens: 262_144) == 3_000)
    }

    @Test("a short note, or a forced single pass, is one call")
    func singlePass() async {
        let short = TranscriptChunkerTests.meeting(turns: 40)  // 800 words
        let model = ScriptedDigestModel(contextTokens: 4_096)
        let (_, report) = await NoteSummarizer.summarize(short, fallbackTitle: "Note", model: model)
        #expect(report.strategy == .singlePass)
        #expect(model.schemas == ["MeetingDigest"])
        var forced = NoteSummarizer.Configuration()
        forced.strategy = .singlePass
        let big = ScriptedDigestModel(contextTokens: 262_144)
        _ = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: big, configuration: forced)
        #expect(big.schemas == ["MeetingDigest"])
    }

    @Test("the summary's owner and due date reach the note as fields, line for line, in both strategies")
    func fieldsReachTheNote() async {
        for tokens in [4_096, 262_144] {
            let model = ScriptedDigestModel(contextTokens: tokens)
            let transcript = tokens > 100_000 ? TranscriptChunkerTests.meeting(turns: 40) : Self.longTranscript
            let (output, _) = await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model)
            var note = Note(title: "t", status: .ready)
            note.setActionItems(from: output)
            #expect(!note.actionItems.isEmpty)
            #expect(note.actionItemDetails?.count == note.actionItems.count)
            #expect(note.actionItemDetails?.allSatisfy { $0.owner == "Priya" } == true)
            #expect(note.actionItemDetails?.map(\.line) == note.actionItems)
        }
    }

    @Test("a failed piece is retried once, then summarized extractively; the rest still count")
    func failedPiece() async {
        let model = ScriptedDigestModel(contextTokens: 4_096, failPiece: 2)
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(report.retries == 1)
        #expect(report.extractivePieces == 1)
        #expect(output.title == "Merged")
    }

    @Test("a failed merge falls back to the deterministic merge")
    func failedMerge() async {
        let model = ScriptedDigestModel(contextTokens: 4_096, failMerge: true)
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(report.deterministicMerge)
        #expect(output.actionItems.contains("Priya: Task from piece 3"))
    }

    @Test("a failed single pass on auto falls back to map-reduce")
    func singlePassFallsBack() async {
        let short = TranscriptChunkerTests.meeting(turns: 40)
        let model = ScriptedDigestModel(contextTokens: 4_096, failSinglePass: true)
        let (_, report) = await NoteSummarizer.summarize(short, fallbackTitle: "Note", model: model)
        #expect(report.singlePassFellBack)
        #expect(report.strategy == .mapReduce)
        #expect(model.schemas.suffix(2) == ["MeetingPartNotes", "MeetingMerge"])
    }

    @Test("no model: the extractive summary")
    func noModel() async {
        let (_, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: NullLanguageModel())
        #expect(report.extractiveOnly)
    }
}

/// Answers `MeetingPartNotes` with one action item per piece ("Task from piece N") and
/// `MeetingDigest` with title "Merged"; can fail a piece, the merge, or the single pass.
private final class ScriptedDigestModel: LanguageModel {
    let contextTokens: Int
    let failPiece: Int?
    let failMerge: Bool
    let failSinglePass: Bool
    private let log = Mutex<[(schema: String, prompt: String, options: LanguageModelOptions)]>([])

    init(contextTokens: Int, failPiece: Int? = nil, failMerge: Bool = false, failSinglePass: Bool = false) {
        self.contextTokens = contextTokens
        self.failPiece = failPiece
        self.failMerge = failMerge
        self.failSinglePass = failSinglePass
    }

    var schemas: [String] { log.withLock { $0.map(\.schema) } }
    var prompts: [String] { log.withLock { $0.map(\.prompt) } }
    var options: [LanguageModelOptions] { log.withLock { $0.map(\.options) } }

    var identifier: String { "scripted" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        log.withLock { $0.append((schema.name, prompt, options)) }
        if schema.name == "MeetingPartNotes" {
            let piece = Int(prompt.split(separator: " ")[1]) ?? 0
            if piece == failPiece { throw LanguageModelError.busy("scripted") }
            return #"{"speakers":[],"decisions":[],"actionItems":[{"owner":"Priya","task":"Task from piece \#(piece)","due":""}],"changes":[],"keyPoints":["Point \#(piece)"]}"#
        }
        if schema.name == "MeetingMerge" {
            if failMerge { throw LanguageModelError.malformedOutput("scripted") }
            return #"{"title":"Merged","keyPoints":["All"],"decisions":[],"dropItems":[],"updates":[]}"#
        }
        if failSinglePass { throw LanguageModelError.malformedOutput("scripted") }
        return #"{"title":"Merged","keyPoints":["All"],"decisions":[],"actionItems":[{"owner":"Priya","task":"Task","due":""}]}"#
    }
}

@Suite("Speaker name inference")
struct SpeakerNameInferenceTests {
    @Test("a numbered speaker answering to a name twice gets that name")
    func vocatives() {
        let transcript = """
            Speaker 1: Ben, can you write up your notes today?
            Speaker 2: Yes, this afternoon.
            Speaker 1: Okay. And the pairing exercise, Ben?
            Speaker 2: Sure, by Monday.
            Speaker 3: I'm Aisha, by the way, from recruiting.
            Speaker 1: Right, so, Aisha, the offer letter?
            Speaker 3: Thursday.
            """
        #expect(SpeakerNameInference.names(in: transcript) == ["Speaker 2": "Ben", "Speaker 3": "Aisha"])
    }

    @Test("one mention, ambiguous answers, named labels and filler words give nothing")
    func conservative() {
        let transcript = """
            Speaker 1: Okay, so where are we?
            Speaker 2: Right, the launch.
            Speaker 1: Ben, thoughts?
            Speaker 2: Fine.
            Priya: Marcus, can you take it?
            Speaker 3: Sure.
            """
        #expect(SpeakerNameInference.names(in: transcript).isEmpty)
        #expect(SpeakerNameInference.names(in: "Priya: Marcus, go.\nMarcus: Yes.").isEmpty)
    }

    @Test("an owner given as a numbered label is renamed in the digest")
    func renamesOwners() async {
        let transcript = (0..<6).map { i in
            "Speaker 1: Ben, point \(i) of the plan is due soon, can you check the figures one more time please?\nSpeaker 2: Yes, I can do that one."
        }.joined(separator: "\n")
        let model = OwnerModel()
        let output = await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model).output
        #expect(output.actionItems == ["Ben: Check the figures"])
    }
}

private struct OwnerModel: LanguageModel {
    var identifier: String { "owner" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        #"{"title":"Plan","keyPoints":[],"decisions":[],"actionItems":[{"owner":"Speaker 2","task":"Check the figures","due":""}]}"#
    }
}
