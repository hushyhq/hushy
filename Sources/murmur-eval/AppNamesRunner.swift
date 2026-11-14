@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// Measures telling the recogniser the installed app names for one voice-action capture
/// (`VocabularyContext` of every installed app, helpers excluded):
///
///   murmur-eval appnames [--apps 40] [--dev-limit 60] [--model ultra]
///
/// Speech comes from macOS `say` (no microphone, no recordings), so it measures time, side
/// effects on ordinary words, and recognition of clean synthetic speech. It cannot say how well
/// a real voice is helped. Three questions:
///   1. Added time: per utterance, boosted minus plain; the cold cost of building the session.
///   2. Wrong swaps: the same words with and without the app-name context; every transcript that
///      differs in a word other than case or punctuation is listed.
///   3. Recognition: "open <app>" resolves to that app, plain vs boosted.
/// Utterances come from `Evals/actions-tools-dev.json` (dev only) plus ordinary-word probes.
enum AppNamesRunner {
    private static let commonWordProbes = [
        "open notes", "open messages", "open mail", "open music", "open calendar", "open reminders",
        "take notes on the call", "I got three messages from Priya", "check my mail later",
        "play some music", "what is on my calendar", "show me my reminders",
    ]

    static func run(_ args: Arguments) async throws {
        let apps = installedAppNames()
        print("### App names as vocabulary · \(apps.count) installed apps (helpers excluded)")
        let vocabulary = VocabularyContext(terms: apps.map { VocabularyTerm(text: $0) })
        let engine = try await Engine.load(args.model)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appnames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stride = max(1, apps.count / max(1, args.int("apps") ?? 40))
        let openPhrases = apps.enumerated().filter { $0.offset % stride == 0 }.map { "open \($0.element)" }
        let devPhrases = try devUtterances(limit: args.int("dev-limit") ?? 60)
        let phrases = openPhrases + commonWordProbes + devPhrases
        let samples = try phrases.enumerated().map { try speak($1, index: $0, in: directory) }

        // Warm the base model so the first plain pass is not charged for loading.
        _ = try await timed(engine, samples[0], nil)
        let cold = Date()
        _ = try await timed(engine, samples[0], vocabulary)
        let coldMs = Date().timeIntervalSince(cold) * 1000

        var rows: [Row] = []
        for (phrase, audio) in zip(phrases, samples) {
            let plain = try await timed(engine, audio, nil)
            let boosted = try await timed(engine, audio, vocabulary)
            rows.append(Row(phrase: phrase, plain: plain.0, boosted: boosted.0,
                            plainMs: plain.1 * 1000, boostedMs: boosted.1 * 1000))
        }
        report(rows, apps: apps, coldMs: coldMs, openCount: openPhrases.count)
    }

    /// `Engine` has same-named `Transcriber` conformances that return only text; this pins the
    /// timed overloads.
    private static func timed(_ engine: Engine, _ audio: [Float], _ vocabulary: VocabularyContext?) async throws -> (String, Double) {
        if let vocabulary { return try await engine.transcribe(audio, vocabulary: vocabulary) as (String, Double) }
        return try await engine.transcribe(audio) as (String, Double)
    }

    private struct Row {
        let phrase: String, plain: String, boosted: String, plainMs: Double, boostedMs: Double
    }

    private static func report(_ rows: [Row], apps: [String], coldMs: Double, openCount: Int) {
        let added = rows.map { max(0, $0.boostedMs - $0.plainMs) }.sorted()
        func percentile(_ p: Double) -> Double { added[min(added.count - 1, Int(Double(added.count) * p))] }
        print(String(format: "cold session build with %d terms (first boosted call minus nothing): %.0f ms", apps.count, coldMs))
        print(String(format: "added per utterance over %d: p50 %.0f ms · p95 %.0f ms · max %.0f ms",
                     rows.count, percentile(0.5), percentile(0.95), added.last ?? 0))
        print(String(format: "plain p50 %.0f ms", rows.map(\.plainMs).sorted()[rows.count / 2]))

        let changed = rows.filter { words($0.plain) != words($0.boosted) }
        print("transcripts that differ in a word: \(changed.count)/\(rows.count)")
        for row in changed { print("  \"\(row.phrase)\"  plain: \(row.plain)  |  boosted: \(row.boosted)") }

        let open = rows.prefix(openCount)
        func hits(_ text: (Row) -> String) -> Int {
            open.filter { row in
                guard case .app(let heard)? = OpenCommandParser.parse(text(row)) else { return false }
                guard case .confident(let match) = AppNameMatcher.resolve(spoken: heard, among: apps.map { .init(name: $0) }) else { return false }
                return AppNameMatcher.normalize(match.name) == AppNameMatcher.normalize(String(row.phrase.dropFirst(5)))
            }.count
        }
        print("open <app> resolved to that app: plain \(hits(\.plain))/\(open.count) · boosted \(hits(\.boosted))/\(open.count)")
        for row in open where row.plain != row.boosted {
            print("  \"\(row.phrase)\"  plain: \(row.plain)  |  boosted: \(row.boosted)")
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func devUtterances(limit: Int) throws -> [String] {
        struct Cases: Decodable { struct Case: Decodable { let utterance: String }; let cases: [Case] }
        let path = URL(fileURLWithPath: "Evals/actions-tools-dev.json")
        try SealedEvalGuard.assertTuningSafe(path, purpose: "murmur-eval appnames")
        let decoded = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: path))
        return Array(decoded.cases.prefix(limit).map(\.utterance))
    }

    private static func speak(_ text: String, index: Int, in directory: URL) throws -> [Float] {
        let file = directory.appendingPathComponent("\(index).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", file.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        return try AudioConverter().resampleAudioFile(path: file.path)
    }

    /// Every `.app` in the usual folders (and one level down), minus helpers: the list the
    /// matcher itself uses.
    static func installedAppNames() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
        var names: [AppNameMatcher.Candidate] = []
        for folder in folders {
            for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension.lowercased() == "app" {
                    names.append(.init(name: item.deletingPathExtension().lastPathComponent))
                } else {
                    for child in (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    where child.pathExtension.lowercased() == "app" {
                        names.append(.init(name: child.deletingPathExtension().lastPathComponent))
                    }
                }
            }
        }
        var seen = Set<String>()
        return AppNameMatcher.usableCandidates(names).map(\.name).filter { seen.insert($0.lowercased()).inserted }
    }
}
