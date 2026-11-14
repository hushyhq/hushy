import Foundation
import Testing
@testable import MurmurCore

/// Covers `StreamInterleaver.interleave`, the pure function that builds the final two-channel
/// note transcript from independently-transcribed mic ("You") and system-audio (diarized) word
/// timings — see the task's contract: "build the note transcript by interleaving by word
/// timings," with mic words attributed to "You" and system words diarized into "Speaker N".
@Suite("Stream interleaver")
struct StreamInterleaverTests {
    @Test("interleaves mic and system words in time order")
    func interleavesInTimeOrder() {
        let mic = [
            WordTiming(word: "hi", start: 0, end: 0.4),
            WordTiming(word: "there", start: 0.4, end: 0.8),
        ]
        let system = [
            WordTiming(word: "hello", start: 1.0, end: 1.4),
            WordTiming(word: "back", start: 1.4, end: 1.8),
        ]
        let turns = [DiarizationTurn(speakerLabel: "S1", start: 0, end: 2)]
        let segments = StreamInterleaver.interleave(micWords: mic, systemWords: system, systemTurns: turns, youName: nil)
        #expect(segments.count == 2)
        #expect(segments[0].speaker == .you(name: nil))
        #expect(segments[0].text == "hi there")
        #expect(segments[1].speaker == .speaker(index: 1))
        #expect(segments[1].text == "hello back")
    }

    @Test("you segment uses the provided name")
    func usesProvidedYouName() {
        let mic = [WordTiming(word: "hi", start: 0, end: 0.4)]
        let segments = StreamInterleaver.interleave(micWords: mic, systemWords: [], systemTurns: [], youName: "Ada")
        #expect(segments.count == 1)
        #expect(segments[0].speaker.label == "Ada")
    }

    @Test("you segment falls back to the generic label when name is nil or empty")
    func fallsBackToGenericYouLabel() {
        let mic = [WordTiming(word: "hi", start: 0, end: 0.4)]
        #expect(StreamInterleaver.interleave(micWords: mic, systemWords: [], systemTurns: [], youName: nil)[0].speaker.label == "You")
        #expect(StreamInterleaver.interleave(micWords: mic, systemWords: [], systemTurns: [], youName: "")[0].speaker.label == "You")
    }

    @Test("multiple system speakers get distinct, first-appearance-ordered indices")
    func multipleSystemSpeakers() {
        let system = [
            WordTiming(word: "first", start: 0, end: 0.4),
            WordTiming(word: "second", start: 2.0, end: 2.4),
        ]
        let turns = [
            DiarizationTurn(speakerLabel: "S2", start: 0, end: 1),
            DiarizationTurn(speakerLabel: "S5", start: 1, end: 3),
        ]
        let segments = StreamInterleaver.interleave(micWords: [], systemWords: system, systemTurns: turns, youName: nil)
        #expect(segments.count == 2)
        #expect(segments[0].speaker == .speaker(index: 1))
        #expect(segments[1].speaker == .speaker(index: 2))
    }

    @Test("empty system turns fall back to a single generic speaker for all system words")
    func emptyTurnsFallBackToOneSpeaker() {
        let system = [
            WordTiming(word: "hello", start: 0, end: 0.4),
            WordTiming(word: "world", start: 0.4, end: 0.8),
        ]
        let segments = StreamInterleaver.interleave(micWords: [], systemWords: system, systemTurns: [], youName: nil)
        #expect(segments.count == 1)
        #expect(segments[0].speaker == .speaker(index: 1))
        #expect(segments[0].text == "hello world")
    }

    @Test("interleaves overlapping/interspersed turns from both streams by time")
    func interleavesOverlappingTurns() {
        // You: 0-0.5, Speaker: 0.6-1.0, You: 1.1-1.5
        let mic = [
            WordTiming(word: "one", start: 0, end: 0.5),
            WordTiming(word: "three", start: 1.1, end: 1.5),
        ]
        let system = [WordTiming(word: "two", start: 0.6, end: 1.0)]
        let turns = [DiarizationTurn(speakerLabel: "S1", start: 0, end: 2)]
        let segments = StreamInterleaver.interleave(micWords: mic, systemWords: system, systemTurns: turns, youName: nil)
        #expect(segments.count == 3)
        #expect(segments[0].text == "one")
        #expect(segments[0].speaker.label == "You")
        #expect(segments[1].text == "two")
        #expect(segments[1].speaker.label == "Speaker 1")
        #expect(segments[2].text == "three")
        #expect(segments[2].speaker.label == "You")
    }

    @Test("renderTranscript formats speaker-prefixed lines")
    func rendersTranscript() {
        let segments = [
            InterleavedSegment(speaker: .you(name: "Ada"), start: 0, end: 1, text: "hi there"),
            InterleavedSegment(speaker: .speaker(index: 1), start: 1, end: 2, text: "hello back"),
        ]
        let rendered = StreamInterleaver.renderTranscript(segments)
        #expect(rendered == "Ada: hi there\nSpeaker 1: hello back")
    }

    @Test("empty mic and system input produces no segments")
    func emptyInputsProduceNoSegments() {
        #expect(StreamInterleaver.interleave(micWords: [], systemWords: [], systemTurns: [], youName: nil).isEmpty)
    }
}
