import Foundation
import Testing
@testable import MurmurCore

@Suite("TuneSentenceBuilder")
struct TuneSentenceBuilderTests {
    @Test("fills placeholders from user terms in order")
    func fillsFromTerms() {
        let sentences = TuneSentenceBuilder.build(terms: ["Priya", "Kubernetes", "Siobhan", "the roadmap"])
        let rich = sentences[0]
        #expect(rich.id == .richNormal)
        #expect(rich.text.contains("Priya"))
        let jargon = sentences[1]
        #expect(jargon.text.contains("Kubernetes"))
        #expect(jargon.text.contains("the roadmap"))
        #expect(jargon.text.contains("Siobhan"))
    }

    @Test("falls back to defaults when fewer than 5 terms supplied")
    func fallsBackToDefaults() {
        let sentences = TuneSentenceBuilder.build(terms: [])
        #expect(sentences.count == 4)
        #expect(sentences[0].text.contains("Alex"))
    }

    @Test("blank entries are skipped before padding with defaults")
    func skipsBlankEntries() {
        let sentences = TuneSentenceBuilder.build(terms: ["  ", "Priya", ""])
        #expect(sentences[0].text.contains("Priya"))
    }

    @Test("exactly one sentence is marked whisper")
    func exactlyOneWhisper() {
        let sentences = TuneSentenceBuilder.build(terms: [])
        #expect(sentences.filter(\.isWhisper).count == 1)
        #expect(sentences.first { $0.isWhisper }?.id == .whisper)
    }
}

@Suite("TuneScorer")
struct TuneScorerTests {
    let sentences = TuneSentenceBuilder.build(terms: ["Priya"])

    @Test("plain sentence scores as passed on an exact match")
    func plainSentencePasses() {
        let sentence = sentences[0]
        let score = TuneScorer.score(sentence, transcript: sentence.expected)
        #expect(score.passed)
    }

    @Test("plain sentence fails on a wrong word")
    func plainSentenceFails() {
        let sentence = sentences[0]
        let score = TuneScorer.score(sentence, transcript: "Can you send the invoice to Bob by Thursday at 3:30?")
        #expect(!score.passed)
    }

    @Test("correction sentence passes when it resolves to the corrected quantity")
    func correctionResolves() {
        let sentence = sentences[3]
        #expect(sentence.id == .correction)
        let score = TuneScorer.score(sentence, transcript: "Order thirty chairs for the office.")
        #expect(score.passed)
    }

    @Test("correction sentence fails when it keeps the superseded quantity")
    func correctionUnresolved() {
        let sentence = sentences[3]
        let score = TuneScorer.score(sentence, transcript: "Order twenty five chairs, no, thirty, for the office.")
        #expect(!score.passed)
    }

    @Test("correction sentence fails when it drops the correction entirely")
    func correctionWrongNumber() {
        let sentence = sentences[3]
        let score = TuneScorer.score(sentence, transcript: "Order twenty five chairs for the office.")
        #expect(!score.passed)
    }

    @Test("accuracy is the fraction of passed sentences")
    func accuracyFraction() {
        let scores = sentences.map { TuneScorer.score($0, transcript: $0.expected) }
        #expect(TuneScorer.accuracy(scores) == 1.0)
        let mixed = [scores[0], TuneSentenceScore(sentence: sentences[1], transcript: "wrong", passed: false)]
        #expect(TuneScorer.accuracy(mixed) == 0.5)
    }

    @Test("picks the highest-accuracy candidate")
    func picksHighestAccuracy() {
        let good = TuneCandidateResult(
            candidate: TuneCandidate(model: .ultra, boosting: true),
            transcripts: Dictionary(uniqueKeysWithValues: sentences.map { ($0.id, $0.expected) }))
        let bad = TuneCandidateResult(
            candidate: TuneCandidate(model: .v2, boosting: false),
            transcripts: Dictionary(uniqueKeysWithValues: sentences.map { ($0.id, "wrong") }))
        let result = TuneScorer.pickBest([bad, good], sentences: sentences)
        #expect(result?.candidate == TuneCandidate(model: .ultra, boosting: true))
    }

    @Test("ties break towards the current default (v2, boosting off)")
    func tiesBreakTowardsDefault() {
        let transcripts = Dictionary(uniqueKeysWithValues: sentences.map { ($0.id, $0.expected) })
        let results = TuneCandidate.sweepOrder.map { TuneCandidateResult(candidate: $0, transcripts: transcripts) }
        let result = TuneScorer.pickBest(results, sentences: sentences)
        #expect(result?.candidate == TuneCandidate(model: .v2, boosting: false))
    }

    @Test("explain reports zero errors for a perfect candidate")
    func explainsPerfectCandidate() {
        let scores = sentences.map { TuneScorer.score($0, transcript: $0.expected) }
        let line = TuneScorer.explain(TuneCandidate(model: .v2, boosting: true), scores: scores)
        #expect(line == "English model + your names: 0 errors")
    }

    @Test("explain reports the error count for an imperfect candidate")
    func explainsImperfectCandidate() {
        var scores = sentences.map { TuneScorer.score($0, transcript: $0.expected) }
        scores[0] = TuneSentenceScore(sentence: sentences[0], transcript: "wrong", passed: false)
        let line = TuneScorer.explain(TuneCandidate(model: .ultra, boosting: false), scores: scores)
        #expect(line == "Automatic model: 1 error")
    }

    @Test("finds a single-word mishearing at the same position")
    func findsMishearing() {
        let mishearings = TuneScorer.mishearings(expected: "Talk to Priya tomorrow", heard: "Talk to Pria tomorrow")
        #expect(mishearings.count == 1)
        #expect(mishearings.first?.expectedWord == "priya")
        #expect(mishearings.first?.heardWord == "pria")
    }

    @Test("reports no mishearings on an exact match")
    func noMishearingsOnMatch() {
        #expect(TuneScorer.mishearings(expected: "Hello there", heard: "Hello there").isEmpty)
    }

    @Test("skips mishearing detection when word counts differ")
    func skipsWhenLengthDiffers() {
        #expect(TuneScorer.mishearings(expected: "Hello there friend", heard: "Hello there").isEmpty)
    }
}

@Suite("VoiceCalibration")
struct VoiceCalibrationTests {
    @Test("computes levels from room tone and takes")
    func computesLevels() {
        let roomTone = [Float](repeating: 0.001, count: 1000)
        let speech = [[Float](repeating: 0.2, count: 1000), [Float](repeating: 0.3, count: 1000)]
        let whisper = [Float](repeating: 0.02, count: 1000)
        let calibration = VoiceCalibration.from(roomTone: roomTone, speechTakes: speech, whisperTake: whisper)
        #expect(calibration.noiseFloorRMS > 0)
        #expect(calibration.speechLevelRMS > calibration.noiseFloorRMS)
        #expect(calibration.whisperLevelRMS > calibration.noiseFloorRMS)
    }

    @Test("clamps out-of-range values instead of storing them")
    func clampsValues() {
        let calibration = VoiceCalibration(noiseFloorRMS: -1, speechLevelRMS: 999, whisperLevelRMS: .nan)
        #expect(calibration.noiseFloorRMS == 0)
        #expect(calibration.speechLevelRMS == 1)
        #expect(calibration.whisperLevelRMS == 0)
    }

    @Test("flags whisper level too close to the noise floor")
    func flagsRiskyWhisper() {
        let calibration = VoiceCalibration(noiseFloorRMS: 0.01, speechLevelRMS: 0.2, whisperLevelRMS: 0.015)
        #expect(calibration.whisperBelowGateRisk)
    }

    @Test("does not flag a whisper well above the noise floor")
    func doesNotFlagSafeWhisper() {
        let calibration = VoiceCalibration(noiseFloorRMS: 0.001, speechLevelRMS: 0.2, whisperLevelRMS: 0.02)
        #expect(!calibration.whisperBelowGateRisk)
    }

    @Test("round-trips through Codable for AppSettings storage")
    func codableRoundTrip() throws {
        let calibration = VoiceCalibration(noiseFloorRMS: 0.001, speechLevelRMS: 0.2, whisperLevelRMS: 0.02)
        let data = try JSONEncoder().encode(calibration)
        let decoded = try JSONDecoder().decode(VoiceCalibration.self, from: data)
        #expect(decoded.noiseFloorRMS == calibration.noiseFloorRMS)
        #expect(decoded.speechLevelRMS == calibration.speechLevelRMS)
        #expect(decoded.whisperLevelRMS == calibration.whisperLevelRMS)
    }
}
