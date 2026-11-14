@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// Scores CTC vocabulary boosting (see `SpeechEngine`'s vocabulary-boosting pass and
/// `.build/checkouts/FluidAudio/Documentation/ASR/CustomVocabulary.md`):
///
///   murmur-eval vocab --dir <voicelab session dir> --terms "Priya,Siobhan,Xiaoyu,Kristopher,invoice,build"
///
/// For each of v2 and ultra, with and without boosting, reports:
///   - term recall: fraction of Voice Lab takes whose expected text contains a boosted term,
///     where the produced transcript also contains that term (case-insensitive substring).
///   - false insertions: on a held-out distractor set (LibriSpeech clean, no boosted terms in
///     the reference), how often a boosted term appears in the transcript when it should not.
///   - overall WER on the Voice Lab set.
///
/// The Voice Lab folders this is meant to be pointed at are intentionally never tuned against
/// (see Evals/README.md and VoiceLabRunner.swift) — this command only reports aggregates.
extension Runners {
    struct VocabConfig: Sendable, Equatable {
        let name: String
        let version: AsrModelVersion
        let boosting: Bool
    }

    struct VocabResult {
        let config: VocabConfig
        let termRecall: Double
        let recallDenominator: Int
        let falseInsertions: Int
        let distractorCount: Int
        let wer: Double
        let addedLatencyMsP50: Double
    }

    static func vocab(_ args: Arguments) async throws {
        let directory = args.string("dir").map { URL(fileURLWithPath: $0) } ?? VoiceLabStorage.root
        let recordings = (try? VoiceLabStorage.discoverRecordings(in: directory)) ?? []
        guard !recordings.isEmpty else {
            print("### Vocabulary boosting · no recordings found under \(directory.path)")
            print("Skipped: point --dir at a Voice Lab session folder (see VoiceLab in Settings → Developer).")
            return
        }

        let rawTerms = (args.string("terms") ?? "Priya,Siobhan,Xiaoyu,Kristopher,invoice,build")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rawTerms.isEmpty else { throw EvalError.missing("--terms must list at least one term") }
        let vocabulary = VocabularyContext(terms: rawTerms.map { VocabularyTerm(text: $0) })

        let promptsURL = args.string("prompts").map { URL(fileURLWithPath: $0) } ?? Paths.root.appendingPathComponent("voicelab-prompts.json")
        let prompts = try VoiceLabPrompts.load(from: promptsURL)
        let promptsByID = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, $0) })

        // Recall set: Voice Lab takes whose expected text actually contains one of the terms.
        var recallCases: [(recording: VoiceLabRecording, expected: String)] = []
        for recording in recordings {
            guard let prompt = promptsByID[recording.take.promptID] else { continue }
            if rawTerms.contains(where: { prompt.expected.range(of: $0, options: .caseInsensitive) != nil }) {
                recallCases.append((recording, prompt.expected))
            }
        }

        // Distractor set: LibriSpeech clean clips, none of which mention any boosted term —
        // any term appearing in the transcript here is a false insertion caused by boosting.
        let distractorLimit = args.int("distractors") ?? 100
        let distractorClips = try Dataset.librispeechClean.load(root: Paths.data)
            .filter { clip in !rawTerms.contains { clip.reference.range(of: $0, options: .caseInsensitive) != nil } }
            .prefix(distractorLimit)
        let distractorSamples = try distractorClips.map { try AudioConverter().resampleAudioFile(path: $0.audioPath) }

        var results: [VocabResult] = []
        for version in [AsrModelVersion.v2, .ultra] {
            let engine = try await Engine.load(version)
            for boosting in [false, true] {
                let activeVocabulary = boosting ? vocabulary : .empty
                let name = "\(version == .v2 ? "v2" : "ultra") · boosting \(boosting ? "ON" : "OFF")"

                var werPairs: [(reference: String, hypothesis: String)] = []
                var recallHits = 0
                var latencies: [Double] = []
                for (recording, expected) in recallCases {
                    let samples = try AudioConverter().resampleAudioFile(recording.audioURL)
                    let start = Date()
                    let (text, _) = try await engine.transcribe(samples, vocabulary: activeVocabulary)
                    latencies.append(Date().timeIntervalSince(start) * 1000)
                    werPairs.append((expected, text))
                    if rawTerms.contains(where: { term in
                        expected.range(of: term, options: .caseInsensitive) != nil
                            && text.range(of: term, options: .caseInsensitive) != nil
                    }) {
                        recallHits += 1
                    }
                }

                var falseInsertions = 0
                for samples in distractorSamples {
                    let (text, _) = try await engine.transcribe(samples, vocabulary: activeVocabulary)
                    // Whole-word match: "build" must not count "building".
                    let inserted = rawTerms.filter {
                        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b",
                                   options: [.regularExpression, .caseInsensitive]) != nil
                    }
                    if !inserted.isEmpty {
                        falseInsertions += 1
                        print("  false insertion [\(inserted.joined(separator: ","))]: \(text)")
                    }
                }

                let wer = EvalMetrics.corpusWER(werPairs)
                results.append(VocabResult(
                    config: VocabConfig(name: name, version: version, boosting: boosting),
                    termRecall: recallCases.isEmpty ? 0 : Double(recallHits) / Double(recallCases.count),
                    recallDenominator: recallCases.count,
                    falseInsertions: falseInsertions,
                    distractorCount: distractorSamples.count,
                    wer: wer,
                    addedLatencyMsP50: EvalMetrics.percentile(latencies, 0.5)))
            }
        }

        report(results: results, recallCount: recallCases.count, terms: rawTerms, directory: directory)
    }

    private static func report(results: [VocabResult], recallCount: Int, terms: [String], directory: URL) {
        let header = "| Model | Boosting | Term recall | False insertions | WER | Latency p50 |\n" +
            "|---|---|---|---|---|---|"
        let rows = results.map { result -> String in
            "| \(result.config.version == .v2 ? "v2" : "ultra") | \(result.config.boosting ? "on" : "off") | "
                + "\(percent(result.termRecall)) (\(result.recallDenominator) case(s)) | "
                + "\(result.falseInsertions)/\(result.distractorCount) | "
                + "\(percent(result.wer)) | \(ms(result.addedLatencyMsP50)) |"
        }
        let summary = """
            ### Vocabulary boosting · \(directory.lastPathComponent) · terms: \(terms.joined(separator: ", "))
            \(recallCount) Voice Lab take(s) mention a boosted term; distractor set is LibriSpeech clean (no boosted terms).

            \(header)
            \(rows.joined(separator: "\n"))
            """
        emit(summary)
    }
}
