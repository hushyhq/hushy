import Darwin
import Foundation
import HushyModelsMLX
import MurmurCore

/// `murmur-eval model-diag --backend mlx --mlx-probe [--repeats 10] [--lengths 15,30,60] [--warm-only]`
/// (add `--speculation` for the speculative-decoding A/B, `MLXSpeculationProbe`):
/// per-call latency of the Clean cleanup call on the MLX backend — process-cold (load + prefix +
/// call), prefix-uncached (full prompt prefill every call: what a backend without a prefix cache
/// pays) and warm (prefix cached) — with p50/p95 total and time-to-first-token by draft length,
/// plus memory and load average. Drafts are synthetic dictation text, never user data.
enum MLXProbe {
    static func run(_ args: Arguments) async throws {
        let model: MLXLanguageModel
        if let mlx = LanguageModels.current as? MLXLanguageModel {
            model = mlx
        } else if let chain = LanguageModels.current as? FallbackLanguageModel, let mlx = chain.primary as? MLXLanguageModel {
            model = mlx
        } else {
            throw EvalError.missing("--mlx-probe needs --backend mlx")
        }
        if args.flag("speculation") { return try await MLXSpeculationProbe.run(args, model: model) }
        let repeats = args.int("repeats") ?? 10
        let lengths = (args.string("lengths") ?? "15,30").split(separator: ",").compactMap { Int($0) }
        let level = args.cleanupLevel
        let instructions = SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: level == .polished)
        let schema = SmartCleaner.cleanedSchema
        var lines = ["## MLX latency probe — \(model.identifier), \(level.rawValue) prompt, \(Date())", ""]
        lines.append("- Machine: \(machine()), load average at start \(loadAverage())")
        lines.append("- Memory before load: \(memory())")
        lines.append("- Weights on disk: \(weightsOnDisk(model.configuration.directory))")

        let coldDraft = draft(words: 15, variant: 0)
        let cold = try await model.respondMeasured(
            instructions: instructions, prompt: prompt(coldDraft), schema: schema, options: .greedy)
        lines.append("- Process-cold first call (load \(ms(cold.timings.loadMilliseconds)) + prefix \(cold.timings.prefixTokens) tokens \(ms(cold.timings.prefixMilliseconds)) + call): \(ms(cold.timings.totalMilliseconds)) total, TTFT \(ms(cold.timings.timeToFirstTokenMilliseconds)), tokens by \(windowLabel) \(cold.timings.earlyTokens) (sampled \(cold.timings.earlySampledTokens))")
        lines.append("- Memory after load + prefix: \(memory())")
        lines.append("")
        lines.append("| Draft | Mode | n | p50 total | p95 total | p50 TTFT | p95 TTFT | prompt tok | sampled tok (p50) | forced tok (p50) | tok by \(windowLabel) (p50) | tok by \(windowLabel) (worst) | tok/s from call start (p50) | tok/s from call start (worst) |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for words in lengths {
            for cached in args.flag("warm-only") ? [true] : [false, true] {
                var totals: [Double] = []
                var ttfts: [Double] = []
                var generated: [Double] = []
                var forced: [Double] = []
                var early: [Double] = []
                var rates: [Double] = []
                var promptTokens = 0
                var failures = 0
                for index in 0..<repeats {
                    let text = draft(words: words, variant: index + 1)
                    let result: (json: String, timings: MLXLanguageModel.CallTimings)
                    do {
                        result = try await model.respondMeasured(
                            instructions: instructions, prompt: prompt(text), schema: schema, options: .greedy,
                            usePrefixCache: cached)
                    } catch {
                        failures += 1
                        print("[\(words)w \(cached ? "warm" : "uncached")] call failed: \(String(describing: error))")
                        continue
                    }
                    totals.append(result.timings.totalMilliseconds)
                    ttfts.append(result.timings.timeToFirstTokenMilliseconds)
                    generated.append(Double(result.timings.generatedTokens))
                    forced.append(Double(result.timings.forcedTokens))
                    early.append(Double(result.timings.earlyTokens))
                    rates.append(EarlyTokens.perSecond(tokens: result.timings.earlyTokens, totalMilliseconds: result.timings.totalMilliseconds))
                    promptTokens = result.timings.promptTokens
                    if index == 0, args.flag("show") { print("[\(words)w \(cached ? "warm" : "uncached")] \(text)\n  -> \(result.json)") }
                }
                lines.append("| \(words) words | \(cached ? "warm (prefix cached)" : "uncached (full prefill)") | \(totals.count) | \(ms(p(totals, 0.5))) | \(ms(p(totals, 0.95))) | \(ms(p(ttfts, 0.5))) | \(ms(p(ttfts, 0.95))) | \(promptTokens) | \(Int(p(generated, 0.5))) | \(Int(p(forced, 0.5))) | \(early.isEmpty ? "–" : String(Int(p(early, 0.5)))) | \(early.min().map { String(Int($0)) } ?? "–") | \(rates.isEmpty ? "–" : String(Int(p(rates, 0.5)))) | \(rates.min().map { String(Int($0)) } ?? "–") |" + (failures > 0 ? " \(failures) failed" : ""))
            }
        }
        lines.append("")
        lines.append("- Memory after probe: \(memory()); load average at end \(loadAverage())")
        let stats = model.stats
        lines.append("- Stats: calls \(stats.calls), failures \(stats.failures), prefix hits \(stats.prefixHits), builds \(stats.prefixBuilds), misses \(stats.prefixMisses)")
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = args.string("report") {
            try (report + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The early-token window as the table headers show it ("250 ms"); the engine owns the number.
    static var windowLabel: String { "\(Int(EarlyTokens.windowMilliseconds)) ms" }

    static func prompt(_ draft: String) -> String { "Transcript: \(draft)\nOutput:" }

    /// Dictation-shaped synthetic text (fillers, a restart, a correction), sliced to `words`.
    static func draft(words: Int, variant: Int) -> String {
        let source = """
            so um the thing with the pricing page is basically that it doesn't actually say what's free \
            and what's paid and people sign up and then they're kind of surprised when voice actions \
            are locked so I think we should we should just add a simple table you know so it's \
            obvious and then maybe send the draft to Priya by Thursday no actually Friday because \
            she's out on Thursday and the import it fails on files over like two gigs so we should \
            stream it in chunks instead of loading the whole file into memory at once
            """
        let all = source.split(separator: " ")
        let start = (variant * 7) % max(1, all.count - words)
        return all[start..<min(all.count, start + words)].joined(separator: " ")
    }

    static func p(_ values: [Double], _ quantile: Double) -> Double { EvalMetrics.percentile(values, quantile) }

    /// Total size of the model directory's `.safetensors` files (what a user downloads, ± tokenizer).
    static func weightsOnDisk(_ directory: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.filter { $0.pathExtension == "safetensors" }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
    static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "n/a" }
        return String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }

    /// Resident size and physical footprint (the latter includes Metal buffers).
    static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "n/a" }
        return String(format: "RSS %.0f MB, footprint %.0f MB", Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(name), \(memory) GB"
    }
}
