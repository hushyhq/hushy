import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("NOTSOFAR reference turns")
struct NotsofarReferenceTests {
    private func utterances(_ json: String) throws -> [NotsofarDownloader.Utterance] {
        try JSONDecoder().decode([NotsofarDownloader.Utterance].self, from: Data(json.utf8))
    }

    @Test func wordsCloserThanTheGapJoinAndAPauseSplits() throws {
        let gt = try utterances("""
            [{"speaker_id": "Ron", "start_time": 1.0, "end_time": 9.0,
              "word_timing": [["we", 1.0, 1.4], ["should", 1.5, 2.0], ["list", 6.0, 6.5]]}]
            """)
        let turns = NotsofarDownloader.referenceTurns(gt)
        #expect(turns == [
            DERSegment(speaker: "Ron", start: 1.0, end: 2.0),
            DERSegment(speaker: "Ron", start: 6.0, end: 6.5),
        ])
    }

    @Test func overlappingSpeakersStaySeparateAndUntimedUtterancesKeepTheirBounds() throws {
        let gt = try utterances("""
            [{"speaker_id": "Ron", "start_time": 0.0, "end_time": 3.0, "word_timing": [["yes", 0.0, 3.0]]},
             {"speaker_id": "Sarah", "start_time": 2.0, "end_time": 4.0, "word_timing": []}]
            """)
        let turns = NotsofarDownloader.referenceTurns(gt)
        #expect(turns == [
            DERSegment(speaker: "Ron", start: 0.0, end: 3.0),
            DERSegment(speaker: "Sarah", start: 2.0, end: 4.0),
        ])
    }
}
