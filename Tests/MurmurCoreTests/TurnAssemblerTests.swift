import Foundation
import Testing
@testable import MurmurCore

@Suite("Turn assembler")
struct TurnAssemblerTests {
    func words(_ text: String, from start: Double, step: Double = 0.4) -> [WordTiming] {
        text.split(separator: " ").enumerated().map { index, word in
            WordTiming(word: String(word), start: start + Double(index) * step, end: start + Double(index) * step + 0.3)
        }
    }

    func all(_ assembly: TurnAssembler.Assembly) -> [String] { assembly.turns.flatMap { $0.words.map(\.w) } }

    @Test("two channels: the owner and the call's speakers interleave by time, and every word is kept once")
    func twoChannel() {
        let mic = words("can you send it today", from: 0)
        let system = words("yes by thursday", from: 3) + words("and the deck too", from: 8)
        let turns = [DiarizationTurn(speakerLabel: "S7", start: 2.5, end: 5), DiarizationTurn(speakerLabel: "S3", start: 7.5, end: 10)]
        let assembly = TurnAssembler.assemble(mic: mic, system: system, isTwoChannel: true, systemTurns: turns, ownerName: "")
        #expect(assembly.speakers.map(\.label) == ["You", "Speaker 1", "Speaker 2"])
        #expect(assembly.ownerName == "You")
        #expect(assembly.turns.map(\.text) == ["can you send it today", "yes by thursday", "and the deck too"])
        #expect(assembly.turns.map(\.stream) == [.mic, .system, .system])
        #expect(all(assembly).sorted() == (mic + system).map(\.word).sorted())
    }

    @Test("mic words that are the call heard again stay in their turn, flagged, and out of its text")
    func echoIsKeptButNotShown() {
        let system = words("the budget is approved", from: 1)
        let mic = [WordTiming(word: "budget", start: 1.4, end: 1.7)] + words("great news", from: 6)
        let assembly = TurnAssembler.assemble(mic: mic, system: system, isTwoChannel: true)
        let echo = assembly.turns.flatMap(\.words).filter { $0.flags & NoteTurn.Word.echo != 0 }
        #expect(echo.map(\.w) == ["budget"])
        #expect(!assembly.turns.filter { $0.stream == .mic }.map(\.text).joined().contains("budget"))
        #expect(assembly.wordCount == mic.count + system.count)
    }

    @Test("with no diarization the call side is one Speaker 1; a long pause starts a new turn")
    func fallbackAndPauses() {
        let system = words("first point", from: 0) + words("second point", from: 10)
        let assembly = TurnAssembler.assemble(mic: [], system: system, isTwoChannel: true)
        #expect(assembly.speakers.map(\.label) == ["Speaker 1"])
        #expect(assembly.turns.map(\.text) == ["first point", "second point"])
        #expect(assembly.ownerName == nil)
    }

    @Test("a mic-only room is split by diarization, and the cleaner runs on each turn's words")
    func room() {
        let mic = words("um so we ship friday", from: 0) + words("agreed", from: 3)
        let turns = [DiarizationTurn(speakerLabel: "A", start: 0, end: 2.4), DiarizationTurn(speakerLabel: "B", start: 2.9, end: 4)]
        let assembly = TurnAssembler.assemble(
            mic: mic, system: [], isTwoChannel: false, micTurns: turns, clean: { $0.replacingOccurrences(of: "um ", with: "") })
        #expect(assembly.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(assembly.turns.map(\.text) == ["so we ship friday", "agreed"])
        #expect(assembly.turns.first?.words.first?.w == "um")
    }
}
