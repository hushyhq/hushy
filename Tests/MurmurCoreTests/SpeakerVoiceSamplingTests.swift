import Testing
@testable import MurmurCore

@Suite("Speaker voice sampling")
struct SpeakerVoiceSamplingTests {
    private func range(_ start: Double, _ end: Double) -> SpeechRange { SpeechRange(start: start, end: end) }

    private func ready(_ selection: SpeakerVoiceSampling.Selection) -> [SpeechRange] {
        if case .ready(let ranges, _) = selection { return ranges }
        return []
    }

    @Test("a long clean turn is trimmed at the edges and capped per turn")
    func capsLongTurns() {
        let selection = SpeakerVoiceSampling.select(own: [range(0, 40)], others: [])
        let ranges = ready(selection)
        #expect(ranges.count == 1)
        #expect(abs(ranges[0].duration - SpeakerVoiceSampling.maximumTurnSeconds) < 1e-9)
        #expect(ranges[0].start == SpeakerVoiceSampling.edgeMarginSeconds)
    }

    @Test("turns that are too short to carry a voice are dropped")
    func dropsShortTurns() {
        let selection = SpeakerVoiceSampling.select(own: [range(0, 1), range(5, 6.5), range(10, 22)], others: [])
        let ranges = ready(selection)
        #expect(ranges.count == 1)
        #expect(ranges[0].start >= 10)
    }

    @Test("speech that overlaps another speaker is cut out, never included")
    func removesOverlapWithOtherSpeakers() {
        let others = [range(8, 12)]
        let selection = SpeakerVoiceSampling.select(own: [range(0, 20)], others: others)
        let ranges = ready(selection)
        #expect(ranges.count == 2)
        for piece in ranges {
            for other in others { #expect(piece.end <= other.start || piece.start >= other.end) }
        }
    }

    @Test("below the minimum total the selection declines and reports what was available")
    func declinesBelowMinimum() {
        let selection = SpeakerVoiceSampling.select(own: [range(0, 4), range(10, 15)], others: [])
        guard case .tooLittle(let available) = selection else {
            Issue.record("expected tooLittle, got \(selection)")
            return
        }
        #expect(available > 6 && available < 9)
    }

    @Test("no speech at all declines with zero available")
    func declinesWhenEmpty() {
        #expect(SpeakerVoiceSampling.select(own: [], others: [range(0, 5)]) == .tooLittle(availableSeconds: 0))
    }

    @Test("the longest turns are chosen and the total stays under the cap")
    func prefersLongestUnderTotalCap() {
        let own = (0..<8).map { range(Double($0) * 30, Double($0) * 30 + 12 + Double($0)) }
        let selection = SpeakerVoiceSampling.select(own: own, others: [])
        guard case .ready(let ranges, let total) = selection else {
            Issue.record("expected ready")
            return
        }
        #expect(total <= SpeakerVoiceSampling.maximumTotalSeconds + 1e-6)
        #expect(abs(total - ranges.reduce(0) { $0 + $1.duration }) < 1e-6)
        // Turns 0-3 are shorter than the per-turn cap, so the cap-length ones (4-7) win; returned in time order.
        #expect(ranges == ranges.sorted { $0.start < $1.start })
        #expect(!ranges.contains { $0.start < 4 * 30 })
        #expect(ranges.count == 3)
    }

    @Test("a range that sits entirely inside another speaker's speech disappears")
    func fullyOverlappedTurnVanishes() {
        let selection = SpeakerVoiceSampling.select(own: [range(5, 9), range(20, 40)], others: [range(0, 10)])
        let ranges = ready(selection)
        #expect(ranges.count == 1)
        #expect(ranges[0].start >= 20)
    }
}
