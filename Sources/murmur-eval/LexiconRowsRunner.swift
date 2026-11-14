@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// Scores the personal lexicon on the accuracy eval's rows (`Evals/accuracy-v1.jsonl`, branch `eval/accuracy-v1`):
///
///   murmur-eval lexicon-pack --rows <accuracy-v1.jsonl> [--voices Karen,Daniel] [--groups athletes,people,harm]
///
/// Each row's spoken text goes through `say`, then the recogniser with the vocabulary boost and `BoostGuard`. The
/// cleanup step does not run here: this is the recogniser step the lexicon changes. Conditions on the same audio:
///   none     main's vocabulary (no lexicon terms);
///   lexicon  the row's `context.lexicon` names given to `PersonalLexicon` as meeting attendees (a spelling authority);
///   pack     the NBA pack switched on (for rows with a pack), no personal sightings;
///   both     lexicon and pack together.
/// Term exact: every key term (any of its spellings) appears case-sensitive. Harm: any word that differs from `none`.
enum LexiconRowsRunner {
    struct Row: Decodable {
        struct Context: Decodable { let lexicon: [String]?; let pack: String? }
        let id: String, group: String, spoken: String
        let key_terms: [[String]]
        let context: Context
    }

    static func run(_ args: Arguments, path: String) async throws {
        let groups = Set((args.string("groups") ?? "athletes,people,harm").split(separator: ",").map(String.init))
        let voices = (args.string("voices") ?? "Karen,Daniel").split(separator: ",").map(String.init)
        let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
            .filter { groups.contains($0.group) }
        guard let nba = DomainPackCatalog.pack(id: "sports.nba") else { throw EvalError.missing("sports.nba pack") }
        let engine = try await Engine.load(args.model)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conditions = ["none", "lexicon", "pack", "both"]
        var exact: [String: [String: Int]] = [:], total: [String: Int] = [:], swaps: [String: [String: Int]] = [:]
        var notes: [String] = []
        var times: [String: [Double]] = [:]
        print("### Personal lexicon on accuracy-v1 rows · \(rows.count) rows × \(voices.count) voices")
        for voice in voices {
            var first = true
            for row in rows {
                let file = directory.appendingPathComponent("\(voice)-\(row.id).wav")
                try Runners.synthesize(row.spoken, voice: voice, to: file)
                let audio = try AudioConverter().resampleAudioFile(path: file.path)
                if first { _ = try await engine.transcribe(audio) as (String, Double); first = false }
                total[row.group, default: 0] += 1
                var plain = ""
                for condition in conditions {
                    let vocabulary = vocabulary(for: row, condition: condition, pack: nba)
                    let (text, seconds) = try await engine.transcribe(audio, vocabulary: vocabulary) as (String, Double)
                    times[condition, default: []].append(seconds * 1000)
                    if condition == "none" { plain = text }
                    let hit = row.key_terms.allSatisfy { spellings in spellings.contains { text.contains($0) } }
                    if hit { exact[row.group, default: [:]][condition, default: 0] += 1 }
                    if condition != "none", words(text) != words(plain) {
                        swaps[row.group, default: [:]][condition, default: 0] += 1
                        notes.append("[\(voice) \(row.id) \(condition)] none: \(plain) | \(condition): \(text)")
                    }
                }
            }
        }
        print("\n| Group | Rows | " + conditions.map { "\($0) exact" }.joined(separator: " | ") + " | changed vs none (lexicon/pack/both) |")
        print("|---|---:|" + String(repeating: "---:|", count: conditions.count) + "---|")
        for group in groups.sorted() {
            let count = total[group] ?? 0
            let cells = conditions.map { "\(exact[group]?[$0] ?? 0)" }
            let changed = conditions.dropFirst().map { "\(swaps[group]?[$0] ?? 0)" }.joined(separator: "/")
            print("| \(group) | \(count) | " + cells.joined(separator: " | ") + " | \(changed) |")
        }
        for condition in conditions {
            let sorted = (times[condition] ?? []).sorted()
            if !sorted.isEmpty { print(String(format: "%@: recogniser p50 %.0f ms, p95 %.0f ms", condition, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])) }
        }
        print("\nRows that changed against none:")
        for line in notes { print("  \(line)") }
    }

    static func vocabulary(for row: Row, condition: String, pack: DomainPack) -> VocabularyContext {
        guard condition != "none" else { return PipelineSettings().vocabulary }
        var inputs = PersonalLexicon.Inputs()
        inputs.packs = [pack]
        let now = Date()
        if condition == "lexicon" || condition == "both" {
            inputs.attendees = (row.context.lexicon ?? []).map { PersonalLexicon.DatedName(name: $0, date: now) }
        }
        var state = PackState()
        let packOn = (condition == "pack" || condition == "both") && (row.context.pack?.contains("nba") ?? false)
        state.setChoice(packOn ? .on : .off, for: pack)
        inputs.packState = state
        var settings = PipelineSettings()
        settings.lexiconTerms = PersonalLexicon.build(inputs, now: now).boostTerms()
        return settings.vocabulary
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
