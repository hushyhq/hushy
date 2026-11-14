import Foundation
import Testing
@testable import MurmurCore

@Suite("SpeakerColorAssignment")
struct SpeakerColorAssignmentTests {
    @Test("the same speakerId always maps to the same index")
    func stableForSameId() {
        let first = SpeakerColorAssignment.colorIndex(forSpeakerId: 42, paletteSize: 6)
        let second = SpeakerColorAssignment.colorIndex(forSpeakerId: 42, paletteSize: 6)
        #expect(first == second)
    }

    @Test("index is always within the palette bounds")
    func indexStaysInBounds() {
        for id: Int64 in [0, 1, 5, 6, 7, 100, 1_000_000] {
            let index = SpeakerColorAssignment.colorIndex(forSpeakerId: id, paletteSize: 6)
            #expect((0..<6).contains(index))
        }
    }

    @Test("negative ids still map to a valid, non-negative index")
    func negativeIdsStayInBounds() {
        let index = SpeakerColorAssignment.colorIndex(forSpeakerId: -7, paletteSize: 6)
        #expect((0..<6).contains(index))
    }

    @Test("a zero or negative palette size returns 0 rather than crashing")
    func degeneratePaletteSizeReturnsZero() {
        #expect(SpeakerColorAssignment.colorIndex(forSpeakerId: 5, paletteSize: 0) == 0)
        #expect(SpeakerColorAssignment.colorIndex(forSpeakerId: 5, paletteSize: -1) == 0)
    }
}
