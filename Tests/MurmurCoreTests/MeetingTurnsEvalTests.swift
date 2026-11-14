import Foundation
import Testing
@testable import MurmurCore

/// The decision #2 gate "transcript words equal turn words in 100% of eval meetings", over the meetings
/// eval set (`Evals/meeting-eval/golden.json`, 12 invented meetings, 20 to 70 minutes). Each meeting is
/// played through the shipping store path: 30 s capture parts written as turns while "recording", then
/// the assembling step (`TurnAssembler` + `Store.replaceAssembly`) with diarization turns that match
/// the golden speakers. Two-channel meetings put "You" on the mic and everyone else on the call, with
/// some call words bleeding into the mic. Checked per meeting:
/// - the cache is the rendered turns, and holds every turn word (`TranscriptInvariant`), during
///   capture and after assembly;
/// - assembly keeps every recognised word, echo included, exactly once;
/// - both sides reach the cache, search, Markdown and MCP `get_note`.
/// What it measures: the store and assembly path given correct words and turns. It does not measure
/// recognition or diarization accuracy.
@Suite("Meetings eval: turns are the only transcript")
struct MeetingTurnsEvalTests {
    struct Golden: Decodable {
        struct Meeting: Decodable { let id: String; let style: String; let transcript: String }
        let meetings: [Meeting]
    }

    static let wordSeconds = 0.35
    static let lineGap = 0.6
    static let partSeconds = 30.0

    struct Spoken { var label: String; var word: WordTiming }

    /// The golden lines as timed words, one speaker label each.
    static func spoken(_ transcript: String) -> [Spoken] {
        var clock = 0.0
        var result: [Spoken] = []
        for line in transcript.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon])
            for word in line[line.index(after: colon)...].split(separator: " ") {
                result.append(Spoken(label: label, word: WordTiming(word: String(word), start: clock, end: clock + wordSeconds * 0.8)))
                clock += wordSeconds
            }
            clock += lineGap
        }
        return result
    }

    /// Diarization turns that follow the golden speakers: one per run of a label.
    static func diarization(_ spoken: [Spoken]) -> [DiarizationTurn] {
        var turns: [DiarizationTurn] = []
        for item in spoken {
            if let last = turns.last, last.speakerLabel == item.label {
                turns[turns.count - 1] = DiarizationTurn(speakerLabel: item.label, start: last.start, end: item.word.end)
            } else {
                turns.append(DiarizationTurn(speakerLabel: item.label, start: item.word.start, end: item.word.end))
            }
        }
        return turns
    }

    static func part(_ words: [WordTiming], seq: Int, stream: NoteTurn.Stream, clean: (String) -> String) -> NoteTurn? {
        let start = Double(seq) * partSeconds
        let inPart = words.filter { $0.start >= start && $0.start < start + partSeconds }
        let relative = inPart.map { WordTiming(word: $0.word, start: $0.start - start, end: $0.end - start) }
        return NoteTurn.captured(
            stream: stream, seq: seq, start: start, duration: partSeconds, text: clean(inPart.map(\.word).joined(separator: " ")),
            timings: relative)
    }

    struct Outcome { var id: String; var passed: Bool; var failures: [String] }

    static func run(_ meeting: Golden.Meeting) throws -> Outcome {
        let cleaner = TextCleaner(options: CleanupOptions(level: .clean, voiceCommandsEnabled: false))
        let clean: (String) -> String = { $0.isEmpty ? "" : cleaner.clean($0).text }
        let spoken = spoken(meeting.transcript)
        let twoChannel = meeting.style == "two-channel"
        var mic = spoken.filter { !twoChannel || $0.label == "You" }.map(\.word)
        let system = twoChannel ? spoken.filter { $0.label != "You" }.map(\.word) : []
        // Bleed: every 25th call word is also heard by the mic, at the same moment.
        if twoChannel { mic = (mic + system.enumerated().filter { $0.offset % 25 == 0 }.map(\.element)).sorted { $0.start < $1.start } }
        // A word only someone other than the owner (or the first speaker in a room) said.
        let owner = twoChannel ? "You" : (spoken.first?.label ?? "")
        func letters(_ item: Spoken) -> String { item.word.word.lowercased().filter(\.isLetter) }
        let otherSide = Set(spoken.filter { $0.label != owner }.map(letters))
            .subtracting(spoken.filter { $0.label == owner }.map(letters))
        let probe = otherSide.filter { $0.count >= 8 }.sorted().first ?? ""

        let store = try Store()
        let id = try #require(try store.save(Note(title: meeting.id, status: .recording)).id)
        var failures: [String] = []
        let end = (spoken.last?.word.end ?? 0) + 1
        for seq in 0..<Int((end / partSeconds).rounded(.up)) {
            let turns = [part(mic, seq: seq, stream: .mic, clean: clean), twoChannel ? part(system, seq: seq, stream: .system, clean: clean) : nil]
            let live = try #require(try store.appendTurns(noteId: id, turns: turns.compactMap { $0 }))
            let cache = try #require(try store.note(id: id)).transcript
            if !TranscriptInvariant.check(cache: cache, transcript: live).holds { failures.append("capture part \(seq)") }
        }

        let assembly = TurnAssembler.assemble(
            mic: mic, system: system, isTwoChannel: twoChannel,
            micTurns: twoChannel ? [] : diarization(spoken), systemTurns: twoChannel ? diarization(spoken.filter { $0.label != "You" }) : [],
            ownerName: "", clean: clean)
        guard try store.replaceAssembly(noteId: id, assembly: assembly) else { return Outcome(id: meeting.id, passed: false, failures: ["not saved"]) }
        var note = try #require(try store.note(id: id))
        note.status = .ready
        note = try #require(try store.update(note))
        let transcript = try store.transcript(noteId: id)
        let check = TranscriptInvariant.check(cache: note.transcript, transcript: transcript)
        if !check.holds { failures.append("assembled: cache \(check.cacheMatches), words \(check.transcriptWords)/\(check.turnWords)") }
        let stored = try store.turns(noteId: id).flatMap { $0.words ?? [] }.map(\.w).sorted()
        if stored != (mic + system).map(\.word).sorted() { failures.append("words in \(mic.count + system.count), stored \(stored.count)") }
        let labels = Set(transcript.lines.compactMap(\.label))
        if twoChannel, !(labels.contains("You") && labels.contains { $0.hasPrefix("Speaker") }) { failures.append("sides \(labels.sorted())") }
        if !twoChannel, labels.count < 2 { failures.append("speakers \(labels.sorted())") }
        if !probe.isEmpty {
            if try !store.searchNotes(probe).contains(where: { $0.id == id }) { failures.append("search \(probe)") }
            if !MarkdownExporter.markdown(for: note, transcript: transcript).lowercased().contains(probe) { failures.append("markdown") }
            let server = MCPServer(reader: store.writer, scope: .notes, now: { Date() })
            let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_note","arguments":{"id":\#(id)}}}"#
            if server.handle(line: call)?.lowercased().contains(probe) != true { failures.append("mcp") }
        }
        return Outcome(id: meeting.id, passed: failures.isEmpty, failures: failures)
    }

    @Test("every eval meeting: transcript words equal turn words, every word kept, both sides everywhere",
          .enabled(if: PrivateFiles.present("Evals/meeting-eval/golden.json"), "needs a private file: Evals/meeting-eval/golden.json"))
    func evalMeetings() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Evals/meeting-eval/golden.json")
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        #expect(golden.meetings.count == 12)
        let outcomes = try golden.meetings.map(Self.run)
        let passed = outcomes.filter(\.passed).count
        print("meeting turns eval: \(passed)/\(outcomes.count) meetings hold (transcript words == turn words, every word kept, both sides)")
        for outcome in outcomes where !outcome.passed { print("  \(outcome.id): \(outcome.failures.joined(separator: "; "))") }
        #expect(passed == outcomes.count)
    }
}
