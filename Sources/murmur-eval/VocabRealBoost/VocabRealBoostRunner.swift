@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval vocab-real-boost [--harm Evals/vocab-harm.jsonl] [--win Evals/vocab-win.jsonl]
///     [--fixture Evals/vocab-real-boost-fixture.json] [--audio Evals/runs/vocab-real-boost/audio]
///     [--model ultra+guard] [--rows-out rows.jsonl] [--report summary.json] [--limit N] [--ai-prompt-app]`
///
/// `--ai-prompt-app` builds every vocabulary as the app does in an AI-prompt app (Claude, ChatGPT, an agent prompt box):
/// the AI model names are added (`VocabularyContext.aiModelTerms`). Without it the vocabulary is the one for any other app.
///
/// Measures what the real CTC vocabulary boost does to speech, with the vocabulary the app would build. For each
/// row it speaks to the real Parakeet recogniser (the audio comes from `scripts/vocab-eval-audio.sh`), runs the
/// real boost (FluidAudio's rescorer, spotter rescue off as in `SpeechEngine`) with the fixture vocabulary, then
/// `BoostGuard` through `VocabularyContext.guarded`, and records the three texts. Scoring is in
/// `VocabRealBoostScoring`. Invented sentences only. Changes no app behaviour; reads no app data.
enum VocabRealBoostRunner {
    private static let defaultModel = "ultra+guard"

    struct RowRecord: Codable {
        let set: String
        let id: String
        let vocab: String
        let spoken: String
        let recogniser: String
        let boosted: String
        let guarded: String
    }

    /// What the gate reads: counts only, no sentences.
    struct Report: Codable {
        let model: String
        let seconds: Double
        let vocabTerms: [String: Int]
        let harm: VocabRealBoostScoring.HarmSummary
        let win: VocabRealBoostScoring.WinSummary
    }

    static func run(_ args: Arguments) async throws {
        // Fixture vocabulary must never depend on the person's real feature flags.
        let suite = "hushy-vocab-eval-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw EvalError.missing("vocab-real-boost could not create isolated defaults")
        }
        let previous = FeatureFlags.source
        FeatureFlags.source = defaults
        defer {
            FeatureFlags.source = previous
            defaults.removePersistentDomain(forName: suite)
        }

        let harmPath = resolve(args.string("harm") ?? "Evals/vocab-harm.jsonl")
        let winPath = resolve(args.string("win") ?? "Evals/vocab-win.jsonl")
        let fixturePath = resolve(args.string("fixture") ?? "Evals/vocab-real-boost-fixture.json")
        let audioDir = URL(fileURLWithPath: resolve(args.string("audio") ?? "Evals/runs/vocab-real-boost/audio"), isDirectory: true)
        let modelName = args.string("model") ?? defaultModel
        let limit = args.int("limit")

        let fixture = try VocabFixture.load(fixturePath)
        var harmRows: [HarmRow] = try VocabRowFiles.load(harmPath)
        var winRows: [WinRow] = try VocabRowFiles.load(winPath)
        if let limit { harmRows = Array(harmRows.prefix(limit)); winRows = Array(winRows.prefix(limit)) }
        guard !harmRows.isEmpty || !winRows.isEmpty else { throw EvalError.missing("vocab-real-boost needs rows") }
        guard let engine = try await Engine.load(named: modelName) else {
            throw EvalError.missing("vocab-real-boost: unknown --model \(modelName) (v2|v3|ultra|redux, add +guard)")
        }

        let started = Date()
        var vocabularies: [String: SourcedVocabulary] = [:]
        for profile in Set(harmRows.map(\.vocab) + winRows.map(\.vocab)) {
            vocabularies[profile] = try fixture.vocabulary(profile: profile, aiPromptApp: args.flag("ai-prompt-app"))
        }
        let termCounts = vocabularies.mapValues { $0.context.terms.count }
        print("### Vocabulary boost on speech · \(harmRows.count) harm rows · \(winRows.count) win rows · model \(modelName)")
        print("vocabulary terms by profile: " + termCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        // Rows of one profile run together, so the boosting session is built once per profile.
        var harmResults: [VocabRealBoostScoring.HarmResult] = []
        var winResults: [VocabRealBoostScoring.WinResult] = []
        var records: [RowRecord] = []
        for profile in vocabularies.keys.sorted() {
            guard let vocabulary = vocabularies[profile] else { continue }
            for row in harmRows where row.vocab == profile {
                let trace = try await engine.vocabularyTrace(try samples(audioDir, row.id), vocabulary: vocabulary.context)
                harmResults.append(VocabRealBoostScoring.scoreHarm(
                    row: row, recogniser: trace.drifted, boosted: trace.rescored, guarded: trace.guarded, vocabulary: vocabulary))
                records.append(RowRecord(set: "harm", id: row.id, vocab: profile, spoken: row.text,
                                         recogniser: trace.drifted, boosted: trace.rescored, guarded: trace.guarded))
            }
            for row in winRows where row.vocab == profile {
                let trace = try await engine.vocabularyTrace(try samples(audioDir, row.id), vocabulary: vocabulary.context)
                winResults.append(VocabRealBoostScoring.scoreWin(
                    row: row, recogniser: trace.drifted, boosted: trace.rescored, guarded: trace.guarded))
                records.append(RowRecord(set: "win", id: row.id, vocab: profile, spoken: row.text,
                                         recogniser: trace.drifted, boosted: trace.rescored, guarded: trace.guarded))
            }
        }
        harmResults.sort { $0.id < $1.id }
        winResults.sort { $0.id < $1.id }
        records.sort { ($0.set, $0.id) < ($1.set, $1.id) }

        let report = Report(
            model: modelName, seconds: Date().timeIntervalSince(started), vocabTerms: termCounts,
            harm: VocabRealBoostScoring.summarise(harm: harmResults), win: VocabRealBoostScoring.summarise(win: winResults))
        printReport(report, harm: harmResults, win: winResults)
        try write(report, to: args.string("report"))
        try writeRows(records, to: args.string("rows-out"))
    }

    // MARK: Output

    private static func printReport(
        _ report: Report, harm: [VocabRealBoostScoring.HarmResult], win: [VocabRealBoostScoring.WinResult]
    ) {
        let h = report.harm, w = report.win
        print("\n#### Harm: ordinary sentences that must come out unchanged")
        print("| step | rows made worse | words made worse |")
        print("|---|---|---|")
        print("| boost | \(h.rowsWorseAtBoost)/\(h.rows) | \(h.wordsWorseAtBoost) |")
        print("| after guard | \(h.rowsWorseAfterGuard)/\(h.rows) | \(h.wordsWorseAfterGuard) |")
        print("rows made worse after the guard, by source: \(describe(h.rowsWorseAfterGuardBySource))")
        print("rows made worse at the boost, by source: \(describe(h.rowsWorseAtBoostBySource))")
        let worst = VocabRealBoostScoring.worst(harm, limit: 5)
        if !worst.isEmpty {
            print("\nworst examples:")
            for result in worst {
                let changes = result.worseAfterGuard > 0 ? result.changesAfterGuard : result.changesAtBoost
                print("- \(result.id) [\(result.vocab)] worse boost \(result.worseAtBoost), guard \(result.worseAfterGuard)")
                print("    said:       \(result.spoken)")
                print("    recogniser: \(result.recogniser)")
                print("    boosted:    \(result.boosted)")
                print("    guarded:    \(result.guarded)")
                for change in changes {
                    print("    \"\(change.old)\" -> \"\(change.new)\" · source: \(change.source)\(change.term.map { " (\($0))" } ?? "")")
                }
            }
        }
        print("\n#### Win: names and terms the boost should get right")
        print("| text | expected spellings found |")
        print("|---|---|")
        print("| recogniser | \(w.foundInRecogniser)/\(w.terms) (\(percent(w.recall(w.foundInRecogniser)))) |")
        print("| after boost | \(w.foundAfterBoost)/\(w.terms) (\(percent(w.recall(w.foundAfterBoost)))) |")
        print("| after guard | \(w.foundAfterGuard)/\(w.terms) (\(percent(w.recall(w.foundAfterGuard)))) |")
        print("gained by the boost \(w.gainedByBoost) · lost by the boost \(w.lostByBoost) · \(w.rows) rows")
        print(String(format: "\nrun time %.0f s", report.seconds))
    }

    private static func describe(_ counts: [String: Int]) -> String {
        counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private static func write(_ report: Report, to path: String?) throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func writeRows(_ rows: [RowRecord], to path: String?) throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Input

    private static func samples(_ directory: URL, _ id: String) throws -> [Float] {
        let url = directory.appendingPathComponent("\(id).wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvalError.missing("vocab-real-boost: no audio for \(id) in \(directory.path) (run scripts/vocab-eval-audio.sh)")
        }
        return try AudioConverter().resampleAudioFile(url)
    }

    private static func resolve(_ path: String) -> String {
        path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    }
}
