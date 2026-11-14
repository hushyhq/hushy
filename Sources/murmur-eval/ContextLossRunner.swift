import Foundation
import MurmurCore
import FluidAudio

/// `murmur-eval context-loss [--cases a.jsonl,b.jsonl] [--audio dir] [--text] [--report path]`
///
/// Traces where invented screen key terms are lost (extraction, boost, repair, cleanup). Counts only in reports.
enum ContextLossRunner {
    struct Case: Decodable {
        let id: String
        let kind: String
        let context: String
        let spoken: String
        let expected: String
        let keyTerms: [String]
        enum CodingKeys: String, CodingKey {
            case id, kind, context, spoken, expected
            case keyTerms = "key_terms"
        }
        var isControl: Bool { kind == "control" }
    }

    static func run(_ args: Arguments) async throws {
        let paths = (args.string("cases") ?? "Evals/screen-context-loss.jsonl")
            .split(separator: ",").map { String($0) }
        var cases: [Case] = []
        for path in paths {
            let file = path.hasPrefix("/") ? path : Paths.root.appendingPathComponent(path).path
            cases += try load(file)
        }
        guard !cases.isEmpty else { throw EvalError.missing("context-loss needs at least one case file") }
        let useText = args.flag("text") || args.string("audio") == nil
        let audioDir = args.string("audio").map { URL(fileURLWithPath: $0) }
        let engine = (!useText && audioDir != nil) ? try await Engine.load(args.model) : nil
        let pipeline = DictationPipeline(transcriber: engine.map { $0 as any Transcriber } ?? NullTranscriber())
        let level = CleanupLevel(rawValue: args.string("level") ?? "polished") ?? .polished

        var stageTotals: [ContextTermTrace.Stage: Int] = [:]
        var keyFound = 0, keyTotal = 0, exact = 0
        // Whatever the stage trace says, is each key term in the delivered text with the screen's casing, and did the
        // screen change the delivered text from what the same words give with no screen at all.
        var keyInFinal = 0, changedByScreen = 0
        let plain = PipelineSettings(cleanupOptions: CleanupOptions(level: level))
        print("### Context loss · \(cases.count) cases · \(useText ? "text" : "audio") · level \(level.rawValue)")

        for item in cases where !item.isControl {
            let extracted = ContextTermTrace.extractedTerms(from: item.context)
            let settings = PipelineSettings(
                cleanupOptions: CleanupOptions(level: level),
                contextTerms: extracted)
            let baseASR: String
            let afterBoost: String
            let afterRepair: String
            let finalText: String

            if useText {
                baseASR = item.spoken
                afterBoost = baseASR
                afterRepair = DictionaryTermFixer.fixNames(
                    ContextSpellingFixer.fix(ScreenIdentifierJoiner.join(baseASR, terms: extracted), terms: extracted), settings: settings)
                finalText = (await pipeline.clean(afterRepair, settings: settings)).text
            } else if let engine, let audioDir, let samples = try? loadAudio(audioDir, id: item.id) {
                let vocabulary = settings.vocabulary
                let trace = try await engine.vocabularyTrace(samples, vocabulary: vocabulary)
                baseASR = trace.base
                afterBoost = trace.guarded
                afterRepair = DictionaryTermFixer.fixNames(
                    ContextSpellingFixer.fix(ScreenIdentifierJoiner.join(afterBoost, terms: extracted), terms: extracted), settings: settings)
                finalText = (await pipeline.clean(afterRepair, settings: settings)).text
            } else {
                print("  skip \(item.id): no audio")
                continue
            }

            let traced = ContextTermTrace.classify(
                keyTerms: item.keyTerms, screenText: item.context, extracted: extracted,
                baseASR: baseASR, afterBoost: afterBoost, afterRepair: afterRepair, finalText: finalText)
            for (stage, count) in ContextTermTrace.stageCounts(traced) { stageTotals[stage, default: 0] += count }
            keyTotal += item.keyTerms.count
            keyInFinal += item.keyTerms.filter { ScreenTermMatch.contains(finalText, term: $0) }.count
            if useText, (await pipeline.clean(item.spoken, settings: plain)).text != finalText { changedByScreen += 1 }
            keyFound += traced.filter { $0.stage == .ok }.count
            if ScreenTermMatch.normalized(finalText) == ScreenTermMatch.normalized(item.expected) { exact += 1 }
            let loss = traced.filter { $0.stage != .ok }.map(\.stage.rawValue).joined(separator: ",")
            if !loss.isEmpty { print("- \(item.id) [\(item.kind)] loss: \(loss)") }
        }

        print("\n| stage | failures |")
        print("|---|---|")
        for stage in ContextTermTrace.Stage.allCases where stage != .ok {
            print("| \(stage.rawValue) | \(stageTotals[stage, default: 0]) |")
        }
        let nonControl = cases.filter { !$0.isControl }.count
        print("| key terms ok | \(keyFound)/\(keyTotal) |")
        print("| exact | \(exact)/\(nonControl) |")
        print("| key terms in final, case-sensitive | \(keyInFinal)/\(keyTotal) |")
        if useText { print("| final changed by screen | \(changedByScreen)/\(nonControl) |") }
        if let path = args.string("report") {
            let payload: [String: Any] = [
                "keyFound": keyFound, "keyTotal": keyTotal, "exact": exact, "cases": nonControl,
                "stages": stageTotals.mapKeys { $0.rawValue },
            ]
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
        }
    }

    private static func load(_ path: String) throws -> [Case] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
    }

    private static func loadAudio(_ dir: URL, id: String) throws -> [Float]? {
        let url = dir.appendingPathComponent("\(id).wav")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AudioConverter().resampleAudioFile(url)
    }
}

private extension ScreenTermMatch {
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension Dictionary {
    func mapKeys<T>(_ transform: (Key) throws -> T) rethrows -> [T: Value] where T: Hashable {
        var result: [T: Value] = [:]
        for (key, value) in self { result[try transform(key)] = value }
        return result
    }
}
