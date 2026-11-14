@preconcurrency import AVFoundation
import Foundation
import MurmurCore

/// US English accuracy, measured so it can sit next to published numbers.
///
///   murmur-eval us-english bench [--sets oasr-librispeech-clean,oasr-librispeech-other,oasr-earnings22,oasr-commonvoice]
///       [--models ultra,ultra+guard,v2,v3,apple-transcriber,apple-dictation] [--limit N]
///   murmur-eval us-english parity [--models ultra+guard] [--per-group 100] [--min-clips 50] [--download-only]
///   murmur-eval us-english dictation [--models ultra+guard,v2,v3] [--voices Samantha,Eddy,…] [--golden path]
///       [--vocab on|off|only] [--american-spelling]
///   murmur-eval us-english spelling   (British spellings per 10k words in every bench dump, before/after `AmericanSpelling`)
///   murmur-eval us-english normalize --in strings.json --out normalized.json
///   murmur-eval us-english breakdown --set oasr-earnings22 --model ultra+guard
///     (error categories of a finished bench run; needs a cased, punctuated reference such as Earnings-22)
///
/// Every WER here uses `WhisperEnglishNormalizer` (the Whisper / Open ASR Leaderboard convention),
/// with the older `esb-v1` normaliser alongside for continuity. Per-clip transcripts are written to
/// `Evals/runs/us-english/` (gitignored) for error analysis. See docs/product/US-ENGLISH-ACCURACY.md.
enum USEnglishRunner {
    static let defaultSets = ["oasr-librispeech-clean", "oasr-librispeech-other", "oasr-earnings22", "oasr-commonvoice"]
    static let defaultModels = ["ultra", "ultra+guard", "v2", "v3", "apple-transcriber"]

    static func run(_ args: Arguments) async throws {
        switch args.positional.first ?? "" {
        case "bench": try await bench(args)
        case "parity": try await AccentParity.run(args)
        case "dictation": try await USDictationRunner.run(args)
        case "normalize": try normalizeFile(args)
        case "breakdown": try breakdown(args)
        case "spelling": try spelling(args)
        default:
            throw EvalError.missing("usage: murmur-eval us-english bench|parity|dictation|normalize … (see USEnglishRunner.swift)")
        }
    }

    static func list(_ args: Arguments, _ key: String, default fallback: [String]) -> [String] {
        args.string(key).map { $0.split(separator: ",").map(String.init) } ?? fallback
    }

    // MARK: Recognizers

    /// `ultra`, `ultra+guard`, `v2`, `v3` (Parakeet via FluidAudio) or `apple-transcriber` /
    /// `apple-dictation` (Apple's on-device SpeechAnalyzer modules, en-US).
    static func recognizer(named name: String) async throws -> any Recognizer {
        switch name {
        case "apple-transcriber": return try await AppleRecognizer.make(.transcriber)
        case "apple-dictation": return try await AppleRecognizer.make(.dictation)
        default:
            guard let engine = try await Engine.load(named: name) else {
                throw EvalError.missing("unknown model \(name) (ultra, ultra+guard, v2, v3, apple-transcriber, apple-dictation)")
            }
            return engine
        }
    }

    /// Transcribes every clip and scores it; clips whose reference normalises to nothing are
    /// still transcribed but contribute no words (the leaderboard drops them the same way).
    static func transcribe(_ clips: [EvalClip], with recognizer: any Recognizer, label: String) async throws -> [ScoredClip] {
        var scored: [ScoredClip] = []
        scored.reserveCapacity(clips.count)
        for (index, clip) in clips.enumerated() {
            let url = URL(fileURLWithPath: clip.audioPath)
            let (text, seconds) = try await recognizer.transcribe(file: url)
            scored.append(.score(id: clip.id, reference: clip.reference, hypothesis: text,
                                 audioSeconds: Runners.audioSeconds(url) ?? 0, seconds: seconds,
                                 group: clip.group, speaker: clip.speaker))
            if (index + 1) % 500 == 0 { print("  \(label): \(index + 1)/\(clips.count)") }
        }
        return scored
    }

    // MARK: bench

    static func loadClips(_ name: String, limit: Int?) throws -> [EvalClip] {
        let manifest = Paths.data.appendingPathComponent(name, isDirectory: true).appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw EvalError.missing("\(name) is not downloaded — run `murmur-eval download \(name) --limit N` first")
        }
        let clips = try JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifest))
            .filter { !$0.reference.contains("IGNORE_TIME_SEGMENT") && !$0.reference.contains("ignore time segment in scoring") }
        return Array(clips.prefix(limit ?? .max))
    }

    static func bench(_ args: Arguments) async throws {
        let sets = list(args, "sets", default: defaultSets)
        let models = list(args, "models", default: defaultModels)
        let clipsBySet = try Dictionary(uniqueKeysWithValues: sets.map { ($0, try loadClips($0, limit: args.int("limit"))) })
        var rows: [String] = []
        for model in models {
            let recognizer = try await recognizer(named: model)
            for set in sets {
                guard let clips = clipsBySet[set], !clips.isEmpty else { continue }
                let scored = try await transcribe(clips, with: recognizer, label: "\(model) · \(set)")
                try dump(scored, set: set, model: model)
                rows.append(row(set: set, model: model, scored: scored))
                print(rows.last ?? "")
            }
            if let engine = recognizer as? Engine, engine.driftGuard {
                rows.append("|  | \(model) drift fallback |  |  | \(await engine.driftFallbackCount)/\(await engine.transcriptionCount) |  |  |  |")
            }
        }
        let header = """
            ### US English benchmark · \(WhisperEnglishNormalizer.version) normaliser · \(models.joined(separator: ", "))
            | Set | Model | Clips | Audio | WER (\(WhisperEnglishNormalizer.version)) | 95% CI | WER (\(EvalTextNormalizer.version)) | Speed |
            |---|---|---|---|---|---|---|---|
            """
        Runners.emit(header + "\n" + rows.joined(separator: "\n"))
    }

    static func row(set: String, model: String, scored: [ScoredClip]) -> String {
        let wer = WERStats.wer(scored)
        // Speaker-cluster bootstrap where speakers are known (LibriSpeech), clip bootstrap otherwise.
        let bySpeaker = scored.allSatisfy { $0.speaker != nil }
        let ci = WERStats.interval(scored, cluster: bySpeaker ? { $0.speaker ?? "" } : nil)
            .map { "\(pct($0.low))–\(pct($0.high))\(bySpeaker ? " (spk)" : "")" } ?? "—"
        let esb = EvalTextNormalizer.corpusWER(scored.map { ($0.reference, $0.hypothesis) })
        let hours = scored.reduce(0) { $0 + $1.audioSeconds } / 3600
        return "| \(set) | \(model) | \(scored.count) | \(String(format: "%.2f", hours)) h | **\(pct(wer))** | \(ci) | \(pct(esb)) | \(String(format: "%.0f", WERStats.speed(scored)))× |"
    }

    /// Two decimals: LibriSpeech-clean differences between models are tenths of a point.
    static func pct(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }

    static func dump(_ scored: [ScoredClip], set: String, model: String) throws {
        let folder = Paths.root.appendingPathComponent("runs/us-english", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(scored).write(to: folder.appendingPathComponent("\(set).\(model).json"), options: .atomic)
    }

    // MARK: breakdown (error categories on a bench dump with written-form references)

    static func breakdown(_ args: Arguments) throws {
        let set = args.string("set") ?? "oasr-earnings22"
        let model = args.string("model") ?? "ultra+guard"
        let url = Paths.root.appendingPathComponent("runs/us-english/\(set).\(model).json")
        let scored = try JSONDecoder().decode([ScoredClip].self, from: Data(contentsOf: url))
        var totals: [ErrorBreakdown.Category: Int] = [:]
        var tokens = 0
        for clip in scored {
            let result = ErrorBreakdown.categorize(expected: clip.reference, output: clip.hypothesis)
            tokens += result.tokens
            for (category, count) in result.counts { totals[category, default: 0] += count }
        }
        let edits = totals.values.reduce(0, +)
        let rows = ErrorBreakdown.Category.allCases.map { category -> String in
            let count = totals[category] ?? 0
            return "| \(category.rawValue) | \(count) | \(pct(Double(count) / Double(max(edits, 1)))) | \(pct(Double(count) / Double(max(tokens, 1)))) |"
        }
        Runners.emit("""
            ### Error breakdown · \(set) · \(model) · \(scored.count) clips (written-form reference, case and punctuation kept)
            - Formatted WER \(pct(Double(edits) / Double(max(tokens, 1)))) over \(tokens) reference tokens; content WER (\(WhisperEnglishNormalizer.version)) \(pct(WERStats.wer(scored)))
            | Category | Edits | Share of edits | Per reference token |
            |---|---|---|---|
            \(rows.joined(separator: "\n"))
            """)
    }

    // MARK: spelling (British spellings in recognizer output, before/after AmericanSpelling)

    static func britishCount(_ text: String) -> (british: Int, words: Int) {
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map { $0.lowercased() }
        return (words.filter { BritishAmericanSpellings.map[$0] != nil }.count, words.count)
    }

    static func spelling(_ args: Arguments) throws {
        let folder = Paths.root.appendingPathComponent("runs/us-english", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("oasr-") && $0.hasSuffix(".json") }.sorted()
        var rows: [String] = []
        for file in files {
            let scored = try JSONDecoder().decode([ScoredClip].self, from: Data(contentsOf: folder.appendingPathComponent(file)))
            var before = 0, after = 0, words = 0
            for clip in scored {
                let raw = britishCount(clip.hypothesis)
                before += raw.british
                words += raw.words
                after += britishCount(AmericanSpelling.apply(clip.hypothesis)).british
            }
            let per10k = { (count: Int) in String(format: "%.1f", Double(count) * 10_000 / Double(max(words, 1))) }
            rows.append("| \(file.dropLast(5)) | \(words) | \(before) (\(per10k(before))) | \(after) (\(per10k(after))) |")
        }
        Runners.emit("""
            ### British spellings in recognizer output (per 10,000 words) · before / after `AmericanSpelling`
            | Run | Words | British forms before | After |
            |---|---|---|---|
            \(rows.joined(separator: "\n"))
            """)
    }

    // MARK: normalize (for checking the port against the Python reference)

    static func normalizeFile(_ args: Arguments) throws {
        guard let input = args.string("in"), let output = args.string("out") else {
            throw EvalError.missing("usage: murmur-eval us-english normalize --in strings.json --out normalized.json")
        }
        let strings = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        let normalized = strings.map(WhisperEnglishNormalizer.normalize)
        try JSONEncoder().encode(normalized).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("normalized \(strings.count) strings with \(WhisperEnglishNormalizer.version)")
    }
}
