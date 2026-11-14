import Foundation
import Testing

@testable import murmur_eval
@testable import MurmurCore

/// Runner logic behind `murmur-eval us-english`: WER statistics, EdAcc accent sampling, the
/// written-form error breakdown, and the Open ASR Leaderboard dataset entries.
@Suite("US English eval")
struct USEnglishTests {
    static func clip(_ id: String, group: String? = nil, speaker: String? = nil, edits: Int, words: Int) -> ScoredClip {
        ScoredClip(id: id, group: group, speaker: speaker, reference: "", hypothesis: "", edits: edits, words: words,
                   audioSeconds: 10, seconds: 0.1)
    }

    // MARK: WERStats

    @Test func corpusWERIsTotalEditsOverTotalWords() {
        let clips = [Self.clip("a", edits: 1, words: 10), Self.clip("b", edits: 3, words: 10)]
        #expect(abs(WERStats.wer(clips) - 0.2) < 1e-9)
        #expect(abs(WERStats.speed(clips) - 100) < 1e-6)
    }

    @Test func bootstrapIntervalIsSeededAndBracketsTheEstimate() {
        let clips = (0..<200).map { Self.clip("c\($0)", edits: $0 % 5 == 0 ? 2 : 0, words: 10) }
        let first = WERStats.interval(clips)
        let second = WERStats.interval(clips)
        #expect(first?.low == second?.low && first?.high == second?.high)
        let wer = WERStats.wer(clips)
        #expect((first?.low ?? 1) <= wer && wer <= (first?.high ?? 0))
    }

    @Test func speakerBootstrapNeedsTwoSpeakers() {
        let oneSpeaker = (0..<20).map { Self.clip("c\($0)", speaker: "s1", edits: 1, words: 10) }
        #expect(WERStats.interval(oneSpeaker, cluster: { $0.speaker ?? "" }) == nil)
        #expect(WERStats.interval(oneSpeaker) != nil)
    }

    @Test func standardDeviationIsTheSampleDeviation() {
        #expect(abs(WERStats.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9]) - 2.138089935) < 1e-6)
        #expect(WERStats.standardDeviation([1]) == 0)
    }

    @Test func permutationTestSeparatesRealGroupDifferencesFromNone() {
        // Six speakers per group; group B is uniformly worse → accent explains the spread.
        var separated: [ScoredClip] = []
        var identical: [ScoredClip] = []
        for speaker in 0..<6 {
            separated.append(Self.clip("a\(speaker)", group: "A", speaker: "a\(speaker)", edits: 1, words: 20))
            separated.append(Self.clip("b\(speaker)", group: "B", speaker: "b\(speaker)", edits: 8, words: 20))
            identical.append(Self.clip("a\(speaker)", group: "A", speaker: "a\(speaker)", edits: speaker, words: 20))
            identical.append(Self.clip("b\(speaker)", group: "B", speaker: "b\(speaker)", edits: speaker, words: 20))
        }
        #expect(WERStats.accentPermutationTest(separated, permutations: 500).pValue < 0.05)
        #expect(WERStats.accentPermutationTest(identical, permutations: 500).pValue > 0.5)
    }

    // MARK: EdAcc sampling

    static func row(_ index: Int, speaker: String, accent: String, text: String = "some words here") -> EdAccAccents.Row {
        EdAccAccents.Row(split: "test", index: index, speaker: speaker, accent: accent, text: text, audioURL: "https://x/\(index).wav")
    }

    @Test func selectionDropsSmallGroupsAndNonAccents() {
        var rows = (0..<60).map { Self.row($0, speaker: "s\($0 % 3)", accent: "Kenyan English") }
        rows += (100..<130).map { Self.row($0, speaker: "t", accent: "Dutch") }                 // too few
        rows += (200..<280).map { Self.row($0, speaker: "u", accent: "Don't know") }             // not an accent
        rows += (300..<360).map { Self.row($0, speaker: "v", accent: "Irish English", text: "IGNORE_TIME_SEGMENT_IN_SCORING") }
        let chosen = EdAccAccents.select(rows, perGroup: 100, minClips: 50, seed: 42)
        #expect(Set(chosen.map(\.accent)) == ["Kenyan English"])
        #expect(chosen.count == 60)
    }

    @Test func selectionRoundRobinsAcrossSpeakersDeterministically() {
        // One talkative speaker (90 rows) and two quiet ones (5 each): a 20-clip sample must still
        // include all of the quiet speakers' rows before topping up from the talkative one.
        var rows = (0..<90).map { Self.row($0, speaker: "loud", accent: "Mainstream US English") }
        rows += (100..<105).map { Self.row($0, speaker: "quiet1", accent: "Mainstream US English") }
        rows += (200..<205).map { Self.row($0, speaker: "quiet2", accent: "Mainstream US English") }
        let chosen = EdAccAccents.select(rows, perGroup: 20, minClips: 50, seed: 42)
        #expect(chosen.count == 20)
        #expect(chosen.filter { $0.speaker == "quiet1" }.count == 5)
        #expect(chosen.filter { $0.speaker == "quiet2" }.count == 5)
        #expect(chosen == EdAccAccents.select(rows, perGroup: 20, minClips: 50, seed: 42))
        #expect(chosen != EdAccAccents.select(rows, perGroup: 20, minClips: 50, seed: 7))
    }

    @Test func scorableTextStripsTagsAndIgnoredSegments() {
        #expect(EdAccAccents.scorableText("<laugh> OKAY SO") == "OKAY SO")
        #expect(EdAccAccents.scorableText("IGNORE_TIME_SEGMENT_IN_SCORING").isEmpty)
    }

    // MARK: ErrorBreakdown

    @Test func everyEditLandsInOneCategory() {
        let expected = "Hi Marcus, the invoice is $1,250 and due Friday."
        let output = "hi Markus the invoice is um one thousand two hundred fifty dollars and due Friday"
        let (counts, tokens) = ErrorBreakdown.categorize(expected: expected, output: output, terms: ["Marcus"])
        #expect(tokens == 9)
        #expect(counts[.casing] == 1)            // Hi → hi
        #expect(counts[.properNoun] == 1)        // Marcus, → Markus
        #expect((counts[.number] ?? 0) >= 1)     // $1,250 → spelled out
        #expect(counts[.punctuation] == 1)       // Friday. → Friday
        #expect(counts[.disfluency] == 1)        // um
        #expect(counts[.other] == nil)
    }

    @Test func alignmentOfIdenticalTextHasNoEdits() {
        #expect(ErrorBreakdown.align(["a", "b"], ["a", "b"]).isEmpty)
        #expect(ErrorBreakdown.align(["a", "b"], ["a"]) == [.delete(1)])
        #expect(ErrorBreakdown.align(["a"], ["x", "a"]) == [.insert(0)])
    }

    @Test func termAndNumberRecallAreCaseAndFormatExact() {
        let names = ErrorBreakdown.termRecall(expected: "Ask Siobhan and Rhys.", output: "Ask Shivon and Rhys.", terms: ["Siobhan", "Rhys"])
        #expect(names.found == 1 && names.total == 2)
        let numbers = ErrorBreakdown.numberRecall(expected: "Meet at 3:30, pay $1,250.", output: "Meet at 3:30 pay 1250 dollars")
        #expect(numbers.found == 1 && numbers.total == 2)
        #expect(ErrorBreakdown.fillerCount("Um, so, uh, yes") == 2)
    }

    @Test func formattedWERKeepsCaseAndPunctuation() {
        #expect(USDictationRunner.formattedWER([("Hello, Tom.", "Hello, Tom.")]) == 0)
        #expect(abs(USDictationRunner.formattedWER([("Hello, Tom.", "hello tom")]) - 1) < 1e-9)
    }

    // MARK: Datasets

    @Test func leaderboardSetsPointAtTheOpenASRLeaderboardCopy() {
        #expect(Dataset.oasrLibrispeechClean.source.dataset == "hf-audio/open-asr-leaderboard")
        #expect(Dataset.oasrLibrispeechClean.source.config == "librispeech")
        #expect(Dataset.oasrLibrispeechClean.source.split == "test.clean")
        #expect(Dataset.oasrLibrispeechOther.source.split == "test.other")
        #expect(Dataset.oasrEarnings22.source.config == "earnings22")
        #expect(Dataset.oasrCommonVoice.source.config == "common_voice")
        #expect(Dataset.oasrCommonVoice.usesDeterministicSampling)
        #expect(Dataset.allCases.filter(\.isOptIn).count == 4)
        #expect(Dataset.oasrLibrispeechClean.license.contains("CC-BY-4.0"))
    }

    @Test func importScriptSamplesTheSameRowsAsTheSwiftDownloader() {
        // Values printed by scripts/import-oasr.py's deterministic_sample (Python) for the same inputs.
        #expect(Downloader.deterministicSample(count: 5, from: 100, seed: 42) == [13, 31, 58, 64, 90])
        #expect(Downloader.deterministicSample(count: 7, from: 16334, seed: 42)
            == [1660, 3120, 6232, 7749, 9481, 13364, 15321])
    }
}
