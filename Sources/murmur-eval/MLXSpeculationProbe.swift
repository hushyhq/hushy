import Foundation
import HushyModelsMLX
import MurmurCore

/// `murmur-eval model-diag --backend mlx --mlx-probe --speculation [--repeats 10] [--lengths 15,30,60]
///     [--tasks clean,polished,tools] [--mlx-speculate <max draft>] [--report path.md]`
///
/// A/B of prompt-lookup speculative decoding on warm calls (prefix cached): every input runs once
/// without and once with speculation (alternating which goes first), and the probe reports p50/p95
/// total and TTFT, forward passes, tokens per pass, draft acceptance, and whether the two answers
/// are byte-identical (greedy). `--control` also re-runs each input without speculation but with
/// the whole prompt prefilled at once (no prefix cache): the baseline's own sensitivity to batch
/// shapes. Inputs are synthetic (`MLXProbe.draft`), never user data.
enum MLXSpeculationProbe {
    enum Task: String, CaseIterable {
        case clean, polished, tools
    }

    struct Sample {
        var totalMs: Double
        var ttftMs: Double
        var sampled: Int
        var forced: Int
        var passes: Int
        var speculation: SpeculationStats?
    }

    static func run(_ args: Arguments, model: MLXLanguageModel) async throws {
        let repeats = args.int("repeats") ?? 10
        let lengths = (args.string("lengths") ?? "15,30,60").split(separator: ",").compactMap { Int($0) }
        let tasks = (args.string("tasks") ?? "clean,polished,tools").split(separator: ",").compactMap { Task(rawValue: String($0)) }
        var lines = [
            "## MLX speculation probe — \(model.identifier), \(Date())", "",
            "- Machine: \(MLXProbe.machine()), load average at start \(MLXProbe.loadAverage())",
            "- Settings: \(model.speculationSettings(override: true).map(describe) ?? "off")", "",
            "| Task | Draft | n | off p50 / p95 | on p50 / p95 | speedup p50 / p95 | TTFT off / on (p50) | sampled tok (p50) | passes off → on (p50) | tokens/pass on | acceptance | identical | load |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        var passCosts: [Int: [Double]] = [:]
        for task in tasks {
            let (instructions, schema) = spec(task)
            // Build the prefix and compile the grammar off the clock, then one warm-up call each way
            // (a warm-up answer that runs away is fine: only the timed calls are reported).
            for speculate in [false, true] {
                _ = try? await model.respondMeasured(
                    instructions: instructions, prompt: prompt(task, words: 15, variant: 0), schema: schema, options: .greedy,
                    speculate: speculate)
            }
            for words in lengths {
                var off: [Sample] = []
                var on: [Sample] = []
                var identical = 0
                var controlIdentical = 0
                var controls = 0
                var failures = 0
                for index in 0..<repeats {
                    let text = prompt(task, words: words, variant: index + 1)
                    do {
                        var answers: [Bool: String] = [:]
                        for speculate in index % 2 == 0 ? [false, true] : [true, false] {
                            let result = try await model.respondMeasured(
                                instructions: instructions, prompt: text, schema: schema, options: .greedy, speculate: speculate)
                            answers[speculate] = result.json
                            let t = result.timings
                            let sample = Sample(
                                totalMs: t.totalMilliseconds, ttftMs: t.timeToFirstTokenMilliseconds, sampled: t.generatedTokens,
                                forced: t.forcedTokens, passes: t.speculation?.forwardPasses ?? t.generatedTokens, speculation: t.speculation)
                            if speculate { on.append(sample) } else { off.append(sample) }
                            for (tokens, values) in t.speculation?.passMilliseconds ?? [:] { passCosts[tokens, default: []] += values }
                        }
                        if args.flag("control") {
                            // Control: the same plain (non-speculative) call with the whole prompt
                            // prefilled at once instead of prefix + suffix — only batch shapes differ.
                            let control = try await model.respondMeasured(
                                instructions: instructions, prompt: text, schema: schema, options: .greedy,
                                usePrefixCache: false, speculate: false)
                            controls += 1
                            if control.json == answers[false] { controlIdentical += 1 }
                        }
                        if answers[false] == answers[true] {
                            identical += 1
                        } else if args.flag("show") {
                            print("[\(task.rawValue) \(words)w] DIFFERS\n  off: \(answers[false] ?? "")\n  on:  \(answers[true] ?? "")")
                        }
                        if index == 0, args.flag("show") { print("[\(task.rawValue) \(words)w] \(text)\n  -> \(answers[true] ?? "")") }
                    } catch {
                        failures += 1
                        print("[\(task.rawValue) \(words)w] call failed: \(String(describing: error))")
                    }
                }
                lines.append(row(task: task, words: words, off: off, on: on, identical: identical, failures: failures)
                    + (controls > 0 ? " control \(controlIdentical)/\(controls) |" : ""))
            }
        }
        lines.append("")
        let costs = passCosts.keys.sorted().map { tokens in
            "\(tokens) tok \(String(format: "%.1f", MLXProbe.p(passCosts[tokens] ?? [], 0.5))) ms (n=\(passCosts[tokens]?.count ?? 0))"
        }
        lines.append("- Forward pass p50 by tokens fed (speculative calls, prompt pass excluded): " + costs.joined(separator: " · "))
        lines.append("- Memory after probe: \(MLXProbe.memory()); load average at end \(MLXProbe.loadAverage())")
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = args.string("report") {
            try (report + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func describe(_ settings: SpeculationSettings) -> String {
        "prompt lookup + answer history, cost-model draft length ≤ \(settings.maxDraftTokens) tokens, n-gram ≤ \(settings.maxNgram)"
    }

    private static func row(task: Task, words: Int, off: [Sample], on: [Sample], identical: Int, failures: Int) -> String {
        func p(_ values: [Double], _ q: Double) -> Double { MLXProbe.p(values, q) }
        func ms(_ value: Double) -> String { String(format: "%.0f", value) }
        let offTotal = off.map(\.totalMs), onTotal = on.map(\.totalMs)
        let speedup50 = p(offTotal, 0.5) / max(p(onTotal, 0.5), 0.001)
        let speedup95 = p(offTotal, 0.95) / max(p(onTotal, 0.95), 0.001)
        let stats = on.compactMap(\.speculation)
        let drafted = stats.reduce(0) { $0 + $1.draftedTokens }
        let accepted = stats.reduce(0) { $0 + $1.acceptedDraftTokens }
        let emitted = on.reduce(0) { $0 + $1.sampled + $1.forced }
        let passes = on.reduce(0) { $0 + $1.passes }
        let n = min(off.count, on.count)
        return "| \(task.rawValue) | \(words) words | \(n) | \(ms(p(offTotal, 0.5))) / \(ms(p(offTotal, 0.95))) ms | \(ms(p(onTotal, 0.5))) / \(ms(p(onTotal, 0.95))) ms | "
            + String(format: "%.2f× / %.2f×", speedup50, speedup95)
            + " | \(ms(p(off.map(\.ttftMs), 0.5))) / \(ms(p(on.map(\.ttftMs), 0.5))) ms | \(Int(p(on.map { Double($0.sampled) }, 0.5))) | "
            + "\(Int(p(off.map { Double($0.passes) }, 0.5))) → \(Int(p(on.map { Double($0.passes) }, 0.5))) | "
            + String(format: "%.2f", Double(emitted) / Double(max(passes, 1)))
            + " | " + (drafted == 0 ? "n/a" : String(format: "%.0f%% (%d/%d)", 100 * Double(accepted) / Double(drafted), accepted, drafted))
            + " | \(identical)/\(n) | \(MLXProbe.loadAverage().split(separator: " ").first ?? "") |"
            + (failures > 0 ? " \(failures) failed" : "")
    }

    static func spec(_ task: Task) -> (instructions: String, schema: GenerationSchemaSpec) {
        switch task {
        case .clean: (SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: false), SmartCleaner.cleanedSchema)
        case .polished: (SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true), SmartCleaner.cleanedSchema)
        case .tools: (VoiceToolCatalog.instructions, VoiceToolCatalog.envelopeSchema)
        }
    }

    /// Cleanup: the dictation draft. Tools: a command whose argument carries most of the words
    /// (message/email/note bodies copy the utterance — the case speculation should help most).
    static func prompt(_ task: Task, words: Int, variant: Int) -> String {
        switch task {
        case .clean, .polished:
            return MLXProbe.prompt(MLXProbe.draft(words: words, variant: variant))
        case .tools:
            let commands = [
                "email priya saying", "send a message to arjun on slack saying", "take a note that",
                "remind me to tell the team that",
            ]
            let command = commands[variant % commands.count]
            let body = MLXProbe.draft(words: max(3, words - command.split(separator: " ").count), variant: variant)
            return "Now: Saturday 2026-09-26 10:00 (America/Los_Angeles). Locale: en_US. Frontmost app: Mail.\nUtterance: \(command) \(body)"
        }
    }
}
