import Foundation
import MurmurCore

/// Gate 3 (`docs/product/DIRECTION.md` §2): the founder's own voice through the production mic
/// path, scored as three ASR word-error rates against the words on screen (the prompt text the
/// founder read, not the cleaned-up `expected` — cleanup is not what gate 3 measures):
///
///   - raw WER (ASR only, no dictionary, no cleanup) on normal + noisy takes: ≤ 5%
///   - WER after the dictionary (ASR biased by the dictionary, then the dictionary's
///     spelling substitutions, still no cleanup) on normal + noisy takes: ≤ 3%
///   - whispered WER (the after-dictionary path on whisper takes): ≤ 12%
///
/// The dictionary is a JSON file the founder passes explicitly with `--dictionary` (see
/// `VoiceLabDictionaryFile`); this command never opens the app's database. Without the flag the
/// "after dictionary" number is measured with an empty dictionary and labelled as such.
enum VoiceLabGate {
    static let rawWERLimit = 0.05
    static let dictionaryWERLimit = 0.03
    static let whisperWERLimit = 0.12

    struct Measurement: Equatable, Sendable {
        let rawWER: Double
        let dictionaryWER: Double
        let whisperWER: Double
        let normalNoisyCount: Int
        let whisperCount: Int
        let dictionaryTerms: Int

        var rawPasses: Bool { rawWER <= rawWERLimit }
        var dictionaryPasses: Bool { dictionaryWER <= dictionaryWERLimit }
        var whisperPasses: Bool { whisperCount == 0 || whisperWER <= whisperWERLimit }
        var passes: Bool { rawPasses && dictionaryPasses && whisperPasses }
    }

    /// One take's three transcripts against the words the founder read.
    struct Take: Sendable {
        let style: VoiceLabPrompt.Style
        let spoken: String
        let raw: String
        let withDictionary: String
    }

    static func measure(_ takes: [Take], dictionaryTerms: Int) -> Measurement {
        let speech = takes.filter { $0.style != .whisper }
        let whisper = takes.filter { $0.style == .whisper }
        return Measurement(
            rawWER: EvalMetrics.corpusWER(speech.map { ($0.spoken, $0.raw) }),
            dictionaryWER: EvalMetrics.corpusWER(speech.map { ($0.spoken, $0.withDictionary) }),
            whisperWER: EvalMetrics.corpusWER(whisper.map { ($0.spoken, $0.withDictionary) }),
            normalNoisyCount: speech.count, whisperCount: whisper.count, dictionaryTerms: dictionaryTerms)
    }

    /// The words the founder actually read: the prompt with its stage direction removed, using
    /// the same "everything after the first `: `" rule as the Voice Lab screen (`VoiceLabView`)
    /// so the reference matches what was on screen exactly.
    static func spokenText(of prompt: VoiceLabPrompt) -> String {
        if let colon = prompt.prompt.range(of: ": ") {
            return String(prompt.prompt[colon.upperBound...])
        }
        return prompt.prompt
    }

    static func markdown(_ m: Measurement) -> String {
        func line(_ label: String, _ value: Double, _ limit: Double, _ count: Int, _ ok: Bool) -> String {
            "  - \(label): **\(Runners.percent(value))** (limit \(Runners.percent(limit)), \(count) takes) — \(ok ? "PASS" : "FAIL")"
        }
        let dictionaryLabel = m.dictionaryTerms == 0 ? "WER after dictionary (no --dictionary passed: empty dictionary)" : "WER after dictionary (\(m.dictionaryTerms) terms)"
        let whisperLine = m.whisperCount == 0
            ? "  - Whispered WER: no whisper takes recorded — unmeasured"
            : line("Whispered WER", m.whisperWER, whisperWERLimit, m.whisperCount, m.whisperPasses)
        return """
            - Gate 3 (founder's voice, ASR against the words read aloud): **\(m.passes ? "PASS" : "FAIL")**
            \(line("Raw WER (no dictionary, no cleanup)", m.rawWER, rawWERLimit, m.normalNoisyCount, m.rawPasses))
            \(line(dictionaryLabel, m.dictionaryWER, dictionaryWERLimit, m.normalNoisyCount, m.dictionaryPasses))
            \(whisperLine)
            """
    }
}

/// `--dictionary <file.json>`: `[{"term": "Hushy", "soundsLike": ["hushi", "hush e"]}, …]`,
/// typed by the founder from Settings → Voice & style → Dictionary. `soundsLike` is optional.
enum VoiceLabDictionaryFile {
    private struct Entry: Decodable {
        let term: String
        let soundsLike: [String]?
    }

    static func load(from url: URL) throws -> [DictionaryEntry] {
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        return entries.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            return DictionaryEntry(term: term, soundsLike: entry.soundsLike ?? [])
        }
    }
}
