import CryptoKit
import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval us-english dictation`: Hushy's own US dictation proxy. 120 dictation-style
/// paragraphs (`Evals/us-dictation-golden.json`: emails, messages, notes, numbers, names, tech,
/// disfluent speech) spoken by six macOS US English voices, run through the production
/// `DictationPipeline` (loudness normalisation → ASR → Clean). TTS audio is clean, evenly paced and
/// accent-neutral, so every number here is an **upper bound** on real microphones.
///
/// Per model it reports: ASR WER against what was said; content WER (Whisper normaliser),
/// formatted WER (case and punctuation kept) and exact-match rate against the written text, before
/// and after Clean; proper-noun and number recall; fillers left in; and an error breakdown by
/// category (`ErrorBreakdown`). With a Parakeet model the run is repeated with every case's names
/// in the Dictionary (vocabulary boosting + `BoostGuard`), the one cheap win that needs no model
/// change.
enum USDictationRunner {
    struct Case: Decodable {
        let id: String
        let tag: String
        let spoken: String
        let expected: String
        let terms: [String]
    }

    static let defaultVoices = ["Samantha", "Eddy", "Flo", "Reed", "Sandy", "Shelley"]

    struct Outcome {
        let item: Case
        let raw: String
        let cleaned: String
    }

    static func run(_ args: Arguments) async throws {
        let path = args.string("golden") ?? Paths.root.appendingPathComponent("us-dictation-golden.json").path
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let voices = USEnglishRunner.list(args, "voices", default: defaultVoices)
        let audio = try synthesizeAll(cases, voices: voices)
        let models = USEnglishRunner.list(args, "models", default: ["ultra+guard", "v2", "v3", "apple-dictation"])
        let cleaner = args.makeCleaner()
        cleaner.prewarm()
        let dictionary = Personalizer(dictionary: Array(Set(cases.flatMap(\.terms))).sorted().map { DictionaryEntry(term: $0) })

        for model in models {
            let recognizer = try await USEnglishRunner.recognizer(named: model)
            let transcriber: any Transcriber = (recognizer as? Engine) ?? RecognizerTranscriber(recognizer: recognizer)
            let pipeline = DictationPipeline(transcriber: transcriber, cleaner: cleaner)
            // `--american-spelling` turns on the optional en-US spelling rule for every variant.
            let spelling = args.flag("american-spelling")
            let options = CleanupOptions(americanSpelling: spelling)
            let suffix = spelling ? " + US spelling" : ""
            var variants: [(String, PipelineSettings)] = []
            if args.string("vocab") != "only" {
                variants.append(("no dictionary" + suffix, PipelineSettings(cleanupOptions: options)))
            }
            if recognizer is Engine, args.string("vocab") != "off" {
                variants.append(("\(dictionary.dictionary.count)-term dictionary" + suffix,
                                 PipelineSettings(cleanupOptions: options, personalizer: dictionary)))
            }
            for (label, settings) in variants {
                var outcomes: [Outcome] = []
                for item in cases {
                    guard let url = audio[item.id] else { continue }
                    let samples = try AudioConverter().resampleAudioFile(url)
                    let result = try await pipeline.run(samples: samples, settings: settings, strategy: args.strategy)
                    outcomes.append(Outcome(item: item, raw: result.raw, cleaned: result.text))
                }
                try save(outcomes, model: model, variant: label)
                Runners.emit(report(outcomes, model: model, variant: label, voices: voices, strategy: args.strategy.rawValue))
            }
        }
    }

    // MARK: Report

    static func report(_ outcomes: [Outcome], model: String, variant: String, voices: [String], strategy: String) -> String {
        let pct = USEnglishRunner.pct
        let asr = WhisperEnglishNormalizer.corpusWER(outcomes.map { ($0.item.spoken, $0.raw) })
        func stageLine(_ name: String, _ text: (Outcome) -> String) -> String {
            let content = WhisperEnglishNormalizer.corpusWER(outcomes.map { ($0.item.expected, text($0)) })
            let formatted = formattedWER(outcomes.map { ($0.item.expected, text($0)) })
            let exact = outcomes.filter { $0.item.expected == text($0).trimmingCharacters(in: .whitespacesAndNewlines) }.count
            let names = outcomes.map { ErrorBreakdown.termRecall(expected: $0.item.expected, output: text($0), terms: $0.item.terms) }
            let numbers = outcomes.map { ErrorBreakdown.numberRecall(expected: $0.item.expected, output: text($0)) }
            let fillers = outcomes.reduce(0) { $0 + ErrorBreakdown.fillerCount(text($1)) }
            return "| \(name) | \(pct(content)) | **\(pct(formatted))** | \(exact)/\(outcomes.count) | \(ratio(names)) | \(ratio(numbers)) | \(fillers) |"
        }
        let breakdown = ErrorBreakdown.Category.allCases.map { category in
            let raw = totals(outcomes, \.raw)[category] ?? 0
            let clean = totals(outcomes, \.cleaned)[category] ?? 0
            return "| \(category.rawValue) | \(raw) | \(clean) |"
        }
        let byTag = Dictionary(grouping: outcomes, by: \.item.tag).sorted { $0.key < $1.key }.map { tag, items in
            "\(tag) \(pct(formattedWER(items.map { ($0.item.expected, $0.cleaned) })))"
        }
        return """
            ### US dictation proxy (TTS, upper bound) · \(model) · \(variant) · \(strategy) · \(outcomes.count) cases · voices \(voices.joined(separator: "/"))
            - ASR WER vs what was said (\(WhisperEnglishNormalizer.version)): **\(pct(asr))**
            | Stage (vs written text) | Content WER | Formatted WER | Exact | Names | Numbers | Fillers left |
            |---|---|---|---|---|---|---|
            \(stageLine("raw ASR", \.raw))
            \(stageLine("after Clean", \.cleaned))
            - Formatted WER after Clean by tag: \(byTag.joined(separator: " · "))
            | Error category (edits) | Raw ASR | After Clean |
            |---|---|---|
            \(breakdown.joined(separator: "\n"))
            """
    }

    /// Case- and punctuation-sensitive WER over whitespace tokens: what the user actually sees.
    static func formattedWER(_ pairs: [(String, String)]) -> Double {
        var edits = 0, words = 0
        for (expected, output) in pairs {
            let reference = ErrorBreakdown.tokens(expected)
            edits += EvalMetrics.editDistance(reference, ErrorBreakdown.tokens(output))
            words += reference.count
        }
        return words == 0 ? 0 : Double(edits) / Double(words)
    }

    static func totals(_ outcomes: [Outcome], _ text: KeyPath<Outcome, String>) -> [ErrorBreakdown.Category: Int] {
        var result: [ErrorBreakdown.Category: Int] = [:]
        for outcome in outcomes {
            let counts = ErrorBreakdown.categorize(expected: outcome.item.expected, output: outcome[keyPath: text],
                                                   terms: outcome.item.terms).counts
            for (category, count) in counts { result[category, default: 0] += count }
        }
        return result
    }

    static func ratio(_ parts: [(found: Int, total: Int)]) -> String {
        let found = parts.reduce(0) { $0 + $1.found }
        let total = parts.reduce(0) { $0 + $1.total }
        return total == 0 ? "—" : "\(found)/\(total)"
    }

    // MARK: Audio and dumps

    /// All audio is rendered before any model loads (see `Runners.endToEnd` for why).
    static func synthesizeAll(_ cases: [Case], voices: [String]) throws -> [String: URL] {
        let folder = Paths.data.appendingPathComponent("tts-us", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var audio: [String: URL] = [:]
        for (index, item) in cases.enumerated() {
            let voice = voices[index % voices.count]
            let key = SHA256.hash(data: Data("tts-us-v1|LEI16@16000|\(voice)|\(item.spoken)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent("\(key).wav")
            if !FileManager.default.fileExists(atPath: url.path) { try Runners.synthesize(item.spoken, voice: voice, to: url) }
            audio[item.id] = url
        }
        return audio
    }

    static func save(_ outcomes: [Outcome], model: String, variant: String) throws {
        let folder = Paths.root.appendingPathComponent("runs/us-english", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rows = outcomes.map { ["id": $0.item.id, "tag": $0.item.tag, "spoken": $0.item.spoken,
                                   "expected": $0.item.expected, "raw": $0.raw, "cleaned": $0.cleaned] }
        let name = "dictation.\(model).\(variant.replacingOccurrences(of: " ", with: "-")).json"
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
