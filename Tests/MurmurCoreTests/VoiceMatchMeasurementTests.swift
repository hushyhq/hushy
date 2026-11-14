import Foundation
import Testing
@testable import MurmurCore

@Suite("Voice match measurement helpers", .timeLimit(.minutes(1)))
struct VoiceMatchMeasurementTests {
    private func range(_ label: String, _ start: Double, _ end: Double) -> LabeledRange {
        LabeledRange(label: label, start: start, end: end)
    }

    @Test("windows are back to back and keep a long enough tail")
    func windows() {
        let cut = VoiceMatchMeasurement.windows(duration: 305, length: 120, minimumTail: 60)
        #expect(cut.map(\.start) == [0, 120, 240])
        #expect(cut.last?.end == 305)
        #expect(VoiceMatchMeasurement.windows(duration: 275, length: 120, minimumTail: 60).count == 2)
        #expect(VoiceMatchMeasurement.windows(duration: 0, length: 120, minimumTail: 60).isEmpty)
    }

    @Test("clipping shifts to the window start and drops what falls outside")
    func clipping() {
        let clipped = VoiceMatchMeasurement.clipped(
            [range("a", 10, 30), range("b", 100, 110), range("c", 0, 5)], to: SpeechRange(start: 20, end: 60))
        #expect(clipped == [range("a", 0, 10)])
    }

    @Test("speech seconds count a speaker's overlapping turns once")
    func speechSeconds() {
        let seconds = VoiceMatchMeasurement.speechSeconds([range("a", 0, 10), range("a", 5, 12), range("b", 20, 23)])
        #expect(seconds["a"] == 12)
        #expect(seconds["b"] == 3)
    }

    @Test("a cluster is tied to the true speaker it overlaps most, with its purity")
    func origins() {
        let reference = [range("alice", 0, 30), range("bob", 30, 60)]
        let clusters = [range("S1", 0, 20), range("S1", 25, 40), range("S2", 40, 60), range("S3", 100, 105)]
        let byCluster = Dictionary(uniqueKeysWithValues: VoiceMatchMeasurement.origins(clusters: clusters, reference: reference).map { ($0.cluster, $0) })
        #expect(byCluster["S1"]?.trueSpeaker == "alice")
        #expect(byCluster["S1"]?.seconds == 35)
        #expect(abs((byCluster["S1"]?.purity ?? 0) - 25.0 / 35.0) < 1e-9)
        #expect(byCluster["S2"]?.trueSpeaker == "bob")
        #expect(byCluster["S2"]?.purity == 1)
        #expect(byCluster["S3"]?.trueSpeaker == nil)
        #expect(byCluster["S3"]?.purity == 0)
    }

    @Test("two clusters of one true speaker both point at that speaker")
    func splitVoice() {
        let reference = [range("alice", 0, 60)]
        let clusters = [range("S1", 0, 40), range("S2", 40, 60)]
        let origins = VoiceMatchMeasurement.origins(clusters: clusters, reference: reference)
        #expect(origins.map(\.trueSpeaker) == ["alice", "alice"])
    }

    @Test("quantiles interpolate and handle one value or none")
    func quantiles() throws {
        let q = try #require(VoiceMatchMeasurement.quantiles([0.9, 0.1, 0.5, 0.3, 0.7]))
        #expect(q.count == 5 && q.min == 0.1 && q.max == 0.9)
        #expect(abs(q.median - 0.5) < 1e-9)
        #expect(abs(q.p10 - 0.18) < 1e-9)
        #expect(abs(q.p90 - 0.82) < 1e-9)
        let one = try #require(VoiceMatchMeasurement.quantiles([0.4]))
        #expect(one.min == 0.4 && one.p10 == 0.4 && one.p90 == 0.4)
        #expect(VoiceMatchMeasurement.quantiles([]) == nil)
    }

    @Test("gate error rates: a score at the gate is a match")
    func gateRates() {
        let same = [0.5, 0.6, 0.7, 0.8]
        #expect(VoiceMatchMeasurement.missedRate(sameScores: same, gate: 0.6) == 0.25)
        #expect(VoiceMatchMeasurement.missedRate(sameScores: same, gate: 0.75) == 0.75)
        let different = [0.2, 0.55, 0.6, 0.3]
        #expect(VoiceMatchMeasurement.falseMatchRate(differentScores: different, gate: 0.6) == 0.25)
        #expect(VoiceMatchMeasurement.falseMatchRate(differentScores: different, gate: 0.9) == 0)
        #expect(VoiceMatchMeasurement.missedRate(sameScores: [], gate: 0.7) == nil)
        #expect(VoiceMatchMeasurement.falseMatchRate(differentScores: [], gate: 0.7) == nil)
    }

    @Test("speaker-count outcome names the direction and the size of the miss")
    func countOutcome() {
        #expect(VoiceMatchMeasurement.CountOutcome(detected: 2, truth: 2) == .exact)
        #expect(VoiceMatchMeasurement.CountOutcome(detected: 3, truth: 2) == .over(by: 1))
        #expect(VoiceMatchMeasurement.CountOutcome(detected: 1, truth: 4) == .under(by: 3))
    }
}
