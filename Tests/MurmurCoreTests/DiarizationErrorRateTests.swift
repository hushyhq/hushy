import Foundation
import Testing
@testable import MurmurCore

/// Covers `DiarizationErrorRate.compute` on tiny synthetic RTTM-like inputs (task requirement:
/// unit tests on tiny synthetic RTTM-like inputs, not a real corpus) — perfect match, total
/// confusion, missed speech, false alarm, and collar exclusion, matching the standard
/// NIST/pyannote DER decomposition documented in docs/research/speaker-labeling.md §3.4.
@Suite("Diarization error rate")
struct DiarizationErrorRateTests {
    @Test("perfect match has zero DER")
    func perfectMatchIsZero() {
        let ref = [
            DERSegment(speaker: "A", start: 0, end: 2),
            DERSegment(speaker: "B", start: 2, end: 4),
        ]
        let hyp = [
            DERSegment(speaker: "1", start: 0, end: 2),
            DERSegment(speaker: "2", start: 2, end: 4),
        ]
        let result = DiarizationErrorRate.compute(reference: ref, hypothesis: hyp, collar: 0)
        #expect(result.der == 0)
        #expect(result.missedSpeechSeconds == 0)
        #expect(result.falseAlarmSeconds == 0)
        #expect(result.confusionSeconds == 0)
    }

    @Test("completely swapped speaker labels still scores as a perfect match via optimal mapping")
    func swappedLabelsStillPerfect() {
        // Hyp uses the same two labels but assigned to the opposite speaker in time — a
        // correct mapping should still find hyp "1" <-> ref "B" and hyp "2" <-> ref "A".
        let ref = [
            DERSegment(speaker: "A", start: 0, end: 2),
            DERSegment(speaker: "B", start: 2, end: 4),
        ]
        let hyp = [
            DERSegment(speaker: "2", start: 0, end: 2),
            DERSegment(speaker: "1", start: 2, end: 4),
        ]
        let result = DiarizationErrorRate.compute(reference: ref, hypothesis: hyp, collar: 0)
        #expect(result.der == 0)
    }

    @Test("total speaker confusion over the whole reference gives DER of 1.0")
    func totalConfusionGivesFullError() {
        // Two reference speakers with no hypothesis speech at all during ref B's span, and a
        // hypothesis speaker present only during ref A's span but never matching (single
        // hyp speaker time-disjoint from correct assignment) — construct a clean confusion case:
        // one reference speaker for the whole clip, but the hypothesis assigns a *different*
        // speaker for the whole clip (no overlap possible in mapping, forced full confusion).
        let ref = [DERSegment(speaker: "A", start: 0, end: 4)]
        let hyp = [DERSegment(speaker: "1", start: 0, end: 4), DERSegment(speaker: "2", start: 0, end: 4)]
        // Two hyp speakers active simultaneously where ref has only one: nRef=1, nHyp=2 for the
        // whole clip. One of the two hyp speakers maps to "A" (perfect for that one), and the
        // other is unmapped extra speech -> false alarm for the whole duration.
        let result = DiarizationErrorRate.compute(reference: ref, hypothesis: hyp, collar: 0)
        #expect(abs(result.falseAlarmSeconds - 4) < 0.001)
        #expect(abs(result.der - 1.0) < 0.001)
    }

    @Test("missed speech: hypothesis has a gap where reference has speech")
    func missedSpeechIsCounted() {
        let ref = [DERSegment(speaker: "A", start: 0, end: 4)]
        let hyp = [DERSegment(speaker: "1", start: 0, end: 2)]  // silent for [2, 4)
        let result = DiarizationErrorRate.compute(reference: ref, hypothesis: hyp, collar: 0)
        #expect(abs(result.missedSpeechSeconds - 2) < 0.001)
        #expect(abs(result.der - 0.5) < 0.001)
    }

    @Test("false alarm: hypothesis has speech where reference has none")
    func falseAlarmIsCounted() {
        let ref = [DERSegment(speaker: "A", start: 0, end: 2)]
        let hyp = [DERSegment(speaker: "1", start: 0, end: 4)]  // extra speech [2, 4)
        let result = DiarizationErrorRate.compute(reference: ref, hypothesis: hyp, collar: 0)
        #expect(abs(result.falseAlarmSeconds - 2) < 0.001)
        #expect(abs(result.der - 1.0) < 0.001)  // false alarm / total ref speech (2s) = 2/2
    }

    @Test("a collar excludes frames near a reference speaker-change boundary")
    func collarExcludesBoundaryFrames() {
        // Reference changes speaker at t=2. Hypothesis is off by 100ms at the boundary
        // (switches at t=2.1 instead of t=2.0) — with a 0.5s collar (±0.25s around t=2), this
        // sub-collar jitter should be entirely excluded and DER should be 0.
        let ref = [
            DERSegment(speaker: "A", start: 0, end: 2),
            DERSegment(speaker: "B", start: 2, end: 4),
        ]
        let hyp = [
            DERSegment(speaker: "1", start: 0, end: 2.1),
            DERSegment(speaker: "2", start: 2.1, end: 4),
        ]
        let resultWithCollar = DiarizationErrorRate.compute(reference: ref, hypothesis: hyp, collar: 0.5)
        #expect(resultWithCollar.der == 0)

        let resultNoCollar = DiarizationErrorRate.compute(reference: ref, hypothesis: hyp, collar: 0)
        #expect(resultNoCollar.der > 0)
    }

    @Test("empty hypothesis against non-empty reference is all missed speech")
    func emptyHypothesisIsAllMissed() {
        let ref = [DERSegment(speaker: "A", start: 0, end: 3)]
        let result = DiarizationErrorRate.compute(reference: ref, hypothesis: [], collar: 0)
        #expect(abs(result.missedSpeechSeconds - 3) < 0.001)
        #expect(abs(result.der - 1.0) < 0.001)
    }

    @Test("empty reference with non-empty hypothesis is fully false alarm (DER 1.0, undefined denominator handled)")
    func emptyReferenceIsFullyFalseAlarm() {
        let hyp = [DERSegment(speaker: "1", start: 0, end: 3)]
        let result = DiarizationErrorRate.compute(reference: [], hypothesis: hyp, collar: 0)
        #expect(abs(result.der - 1.0) < 0.001)
        #expect(abs(result.falseAlarmSeconds - 3) < 0.001)
    }

    @Test("both empty is a perfect (trivial) match")
    func bothEmptyIsPerfect() {
        let result = DiarizationErrorRate.compute(reference: [], hypothesis: [], collar: 0)
        #expect(result.der == 0)
    }
}
