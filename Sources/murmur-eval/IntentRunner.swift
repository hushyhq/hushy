import Darwin
import Foundation
import HushyModelsMLX
import MurmurCore

/// `murmur-eval intent-run --model <mlx dir> --cases <jsonl> --system <prompt file> --out <jsonl>
///     [--reference <jsonl>] [--constrained] [--speculate] [--no-prefix-cache] [--max-tokens 600] [--show]`
///
/// Feasibility measurement for a converted model (Gemma 4 E2B and the like): the rewrite-to-intent
/// call through the app's `MLXLanguageModel` and engine, in the layout the Python reference runner
/// uses (`intent_stock.py`: system turn from the prompt file, user turn `Transcript: …\nOutput:`,
/// thinking off, greedy, at most 600 new tokens, answer is JSON `{"text": …}`). Without
/// `--constrained` the answer is decoded with no grammar, as `mlx_lm.generate` does, so it can be
/// compared with `--reference`; with it, under the app's `Cleaned` grammar. Invented passages only.
enum IntentRunner {
    static func run(_ args: Arguments) async throws {
        guard let modelPath = args.string("model"), let casesPath = args.string("cases"),
              let systemPath = args.string("system"), let outPath = args.string("out") else {
            throw EvalError.missing("intent-run needs --model <dir> --cases <jsonl> --system <file> --out <jsonl>")
        }
        guard let system = IntentRun.systemTurn(inPromptFile: try String(contentsOfFile: systemPath, encoding: .utf8)) else {
            throw EvalError.missing("\(systemPath) has no '--- system turn ---' section")
        }
        let cases = try IntentRun.rows(atPath: casesPath).compactMap { row -> (id: String, spoken: String)? in
            guard let id = row["id"] as? String, let spoken = row["spoken"] as? String else { return nil }
            return (id, spoken)
        }
        guard !cases.isEmpty else { throw EvalError.missing("\(casesPath) has no rows with id and spoken") }

        var configuration = MLXLanguageModel.Configuration(directory: URL(fileURLWithPath: modelPath, isDirectory: true))
        if args.flag("speculate") { configuration.speculation = SpeculationSettings() }
        configuration.usePrefixCache = !args.flag("no-prefix-cache")
        let model = MLXLanguageModel(configuration: configuration)
        let schema = args.flag("constrained") ? SmartCleaner.cleanedSchema : nil
        let maxTokens = args.int("max-tokens") ?? 600

        // Warm-up as the reference runner does (not timed); it also pays the model load.
        let warm = try await model.respondVerbatim(
            system: system, prompt: IntentRun.userTurn(spoken: "so the the meeting is at three no four"),
            schema: schema, maxTokens: maxTokens)
        let afterLoad = MLXLanguageModel.allocatorMemoryBytes.active

        var rows: [[String: Any]] = []
        var seconds: [Double] = []
        var generated = 0
        var decodeMilliseconds = 0.0
        var failures = 0
        for item in cases {
            let answer: (text: String, timings: MLXLanguageModel.CallTimings)
            do {
                answer = try await model.respondVerbatim(
                    system: system, prompt: IntentRun.userTurn(spoken: item.spoken), schema: schema, maxTokens: maxTokens)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One failed case (the grammar path throws when an answer passes its token budget) must not
                // end the run: the row records the reason, and the timing figures leave it out.
                failures += 1
                rows.append(["id": item.id, "error": String(describing: error)])
                continue
            }
            let tokens = answer.timings.generatedTokens + answer.timings.forcedTokens
            let took = answer.timings.totalMilliseconds / 1_000
            seconds.append(took)
            generated += tokens
            decodeMilliseconds += answer.timings.totalMilliseconds - answer.timings.timeToFirstTokenMilliseconds
            rows.append([
                "id": item.id, "text": IntentRun.answerText(raw: answer.text), "raw": answer.text,
                "seconds": NSDecimalNumber(string: String(format: "%.2f", took)), "tokens": tokens, "prompt_tokens": answer.timings.promptTokens,
                "words": item.spoken.split(whereSeparator: \.isWhitespace).count,
            ])
        }
        let lines = try rows.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)

        let total = seconds.reduce(0, +)
        let peak = peakMemory()
        print("intent-run \(model.identifier) \(schema == nil ? "unconstrained" : "constrained")\(args.flag("speculate") ? " speculate" : "") cases=\(cases.count) failed=\(failures)")
        print(String(format: "load %.0f ms (warm-up call %.0f ms total)", warm.timings.loadMilliseconds, warm.timings.totalMilliseconds))
        print(String(format: "seconds per passage: median %.2f worst %.2f total %.2f", IntentRun.upperMedian(seconds), seconds.max() ?? 0, total))
        print(String(format: "tokens: %ld generated, %.1f tok/s end to end, %.1f tok/s after the first token",
                     generated, Double(generated) / max(total, 0.001), Double(generated - seconds.count) / max(decodeMilliseconds / 1_000, 0.001)))
        print(String(format: "memory: peak resident %.0f MB, peak footprint %.0f MB; MLX active after load %.0f MB, MLX peak %.0f MB",
                     peak.resident, peak.footprint, mb(afterLoad), mb(MLXLanguageModel.allocatorMemoryBytes.peak)))
        if let referencePath = args.string("reference") {
            try compare(rows, referencePath: referencePath, show: args.flag("show"))
        }
    }

    /// Counts answers identical to the reference after whitespace normalisation; `--show` prints the
    /// first differing pair (the passages are invented text).
    private static func compare(_ rows: [[String: Any]], referencePath: String, show: Bool) throws {
        let reference = try IntentRun.rows(atPath: referencePath)
        let texts = Dictionary(reference.compactMap { row in (row["id"] as? String).map { ($0, row["text"] as? String ?? "") } }) { first, _ in first }
        let referenceSeconds = reference.compactMap { $0["seconds"] as? Double }
        var same = 0
        var differing: [String] = []
        for row in rows {
            guard let id = row["id"] as? String, let text = row["text"] as? String, let expected = texts[id] else { continue }
            if IntentRun.normalised(text) == IntentRun.normalised(expected) { same += 1 } else { differing.append(id) }
        }
        print(String(format: "reference: %ld of %ld identical after whitespace normalisation; reference seconds median %.2f worst %.2f",
                     same, rows.count, IntentRun.upperMedian(referenceSeconds), referenceSeconds.max() ?? 0))
        guard let first = differing.first else { return }
        print("differing ids: \(differing.joined(separator: " "))")
        if show, let row = rows.first(where: { $0["id"] as? String == first }) {
            print("first difference \(first)\n  swift:  \(row["text"] as? String ?? "")\n  python: \(texts[first] ?? "")")
        }
    }

    private static func mb(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

    /// Peak resident size and peak physical footprint (the latter includes Metal buffers), in MB.
    private static func peakMemory() -> (resident: Double, footprint: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.resident_size_peak) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}

/// The pure parts of `intent-run`: the prompt layout and answer parsing of the Python reference runner.
enum IntentRun {
    /// The text between `--- system turn ---` and `--- user turn ---` of a draft prompt file, trimmed
    /// (`retrain_groups.prompt_sections`); nil when the file has no system section.
    static func systemTurn(inPromptFile text: String) -> String? {
        guard let start = text.range(of: "--- system turn ---") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "--- user turn ---")?.lowerBound ?? rest.endIndex
        let system = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return system.isEmpty ? nil : system
    }

    static func userTurn(spoken: String) -> String { "Transcript: \(spoken)\nOutput:" }

    /// The message inside a raw answer (`intent_stock.clean`): cut at the end-of-turn token, drop a
    /// thinking block and a code fence, then read `{"text": …}`; an answer whose JSON does not parse
    /// is searched for its text field, and failing that returned as it stands. Never empty.
    /// (Foundation's reader accepts a trailing comma that Python's rejects; well-formed answers read the same.)
    static func answerText(raw: String) -> String {
        var out = raw
        for marker in ["<|im_end|>", "<end_of_turn>", "<turn|>"] {
            if let cut = out.range(of: marker) { out = String(out[..<cut.lowerBound]) }
        }
        out = replacing(#"<think>.*?</think>|<\|channel>thought.*?<channel\|>"#, in: out)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        out = replacing(#"^```(?:json)?\s*|\s*```$"#, in: out)
        var text = out
        if let object = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], let value = object["text"] as? String {
            text = value
        } else if let inner = firstGroup(#"\{.*"text"\s*:\s*"(.*)"\s*\}"#, in: out) {
            let decoded = try? JSONSerialization.jsonObject(with: Data("\"\(inner)\"".utf8), options: .fragmentsAllowed) as? String
            text = decoded ?? inner
        }
        return text.isEmpty ? "(empty)" : text
    }

    /// Runs of whitespace become one space; leading and trailing whitespace goes.
    static func normalised(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The reference runner's median: the element at `count / 2` of the sorted values.
    static func upperMedian(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    static func rows(atPath path: String) throws -> [[String: Any]] {
        try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    private static func replacing(_ pattern: String, in text: String) -> String {
        expression(pattern)?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let match = expression(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
