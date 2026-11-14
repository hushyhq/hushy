import Foundation
import Testing
@testable import MurmurCore

/// Covers `SpeakerAlignment.align`, the pure words+turns→segments function
/// docs/research/speaker-labeling.md §2.2 specifies: midpoint assignment, merging consecutive
/// same-speaker words, gap handling (nearest turn), overlap handling (larger-overlap turn wins),
/// and the single-speaker fallback.
@Suite("Speaker alignment")
struct SpeakerAlignmentTests {
    @Test("merges consecutive same-speaker words into one segment")
    func mergesConsecutiveWords() {
        let words = [
            WordTiming(word: "hello", start: 0, end: 0.5),
            WordTiming(word: "there", start: 0.5, end: 1.0),
            WordTiming(word: "friend", start: 1.0, end: 1.5),
        ]
        let turns = [DiarizationTurn(speakerLabel: "S1", start: 0, end: 2)]
        let segments = SpeakerAlignment.align(words: words, turns: turns)
        #expect(segments.count == 1)
        #expect(segments[0].speakerLabel == "S1")
        #expect(segments[0].text == "hello there friend")
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 1.5)
    }

    @Test("splits into separate segments when the speaker turn changes")
    func splitsOnSpeakerChange() {
        let words = [
            WordTiming(word: "hi", start: 0, end: 0.5),
            WordTiming(word: "there", start: 0.5, end: 1.0),
            WordTiming(word: "hey", start: 3.0, end: 3.5),
            WordTiming(word: "back", start: 3.5, end: 4.0),
        ]
        let turns = [
            DiarizationTurn(speakerLabel: "S1", start: 0, end: 2),
            DiarizationTurn(speakerLabel: "S2", start: 2, end: 5),
        ]
        let segments = SpeakerAlignment.align(words: words, turns: turns)
        #expect(segments.count == 2)
        #expect(segments[0].speakerLabel == "S1")
        #expect(segments[0].text == "hi there")
        #expect(segments[1].speakerLabel == "S2")
        #expect(segments[1].text == "hey back")
    }

    @Test("a word whose midpoint falls in a gap is assigned to the nearest turn")
    func gapAssignsNearestTurn() {
        // Word at [2.25, 2.35] has midpoint 2.3, which falls in the gap between turns
        // [0, 1.8] and [2.4, 4]. It's closer to the second turn (distance 0.1 vs 0.5).
        let words = [WordTiming(word: "um", start: 2.25, end: 2.35)]
        let turns = [
            DiarizationTurn(speakerLabel: "S1", start: 0, end: 1.8),
            DiarizationTurn(speakerLabel: "S2", start: 2.4, end: 4),
        ]
        let segments = SpeakerAlignment.align(words: words, turns: turns)
        #expect(segments.count == 1)
        #expect(segments[0].speakerLabel == "S2")
    }

    @Test("a word in an overlap region is assigned to the turn with larger overlap")
    func overlapAssignsLargerOverlapTurn() {
        // Word [1.0, 2.0]: S1 covers [0, 1.8] (0.8s overlap), S2 covers [1.5, 3] (0.5s overlap).
        let words = [WordTiming(word: "cross", start: 1.0, end: 2.0)]
        let turns = [
            DiarizationTurn(speakerLabel: "S1", start: 0, end: 1.8),
            DiarizationTurn(speakerLabel: "S2", start: 1.5, end: 3),
        ]
        let segments = SpeakerAlignment.align(words: words, turns: turns)
        #expect(segments.count == 1)
        #expect(segments[0].speakerLabel == "S1")
    }

    @Test("empty turns falls back to a single speaker for every word")
    func emptyTurnsSingleSpeakerFallback() {
        let words = [
            WordTiming(word: "solo", start: 0, end: 0.5),
            WordTiming(word: "note", start: 0.5, end: 1.0),
        ]
        let segments = SpeakerAlignment.align(words: words, turns: [])
        #expect(segments.count == 1)
        #expect(segments[0].speakerLabel == "S1")
        #expect(segments[0].text == "solo note")
    }

    @Test("empty words produces no segments")
    func emptyWordsProducesNoSegments() {
        let segments = SpeakerAlignment.align(
            words: [], turns: [DiarizationTurn(speakerLabel: "S1", start: 0, end: 1)])
        #expect(segments.isEmpty)
    }

    @Test("a speaker returning later produces a new segment, not a merge with the earlier one")
    func returningsSpeakerIsNewSegment() {
        let words = [
            WordTiming(word: "a", start: 0, end: 0.5),
            WordTiming(word: "b", start: 1.5, end: 2.0),
            WordTiming(word: "c", start: 3.5, end: 4.0),
        ]
        let turns = [
            DiarizationTurn(speakerLabel: "S1", start: 0, end: 1),
            DiarizationTurn(speakerLabel: "S2", start: 1, end: 3),
            DiarizationTurn(speakerLabel: "S1", start: 3, end: 5),
        ]
        let segments = SpeakerAlignment.align(words: words, turns: turns)
        #expect(segments.map(\.speakerLabel) == ["S1", "S2", "S1"])
    }
}
