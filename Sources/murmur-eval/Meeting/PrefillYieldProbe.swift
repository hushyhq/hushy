import Foundation
import HushyModelsMLX
import MurmurCore

/// `murmur-eval prefill-yield --mlx-model <dir> [--trials N] [--chunks 128,512] [--words N]`: how long a dictation
/// waits behind a meeting summary or extract on the shared local model (meetings schema freeze section 8,
/// "Preemption latency"; task T4b).
///
/// For each background prompt chunk size:
/// 1. one background call over an invented meeting transcript (about 5,900 tokens at the default `--words`), and the
///    milliseconds of each prompt chunk it fed (`CallTimings.leadChunkMilliseconds`);
/// 2. `--trials` times: the same call through `MeetingLanguageModel` (the app's route), a dictation pressed at a random
///    moment of its prompt (`ForegroundActivity.set(busy:)`), and a dictation-sized cleanup call sent to the model at
///    once. Reported: how long the background call took to stop after the press, and the dictation call's time against
///    the same call on an idle model.
///
/// Invented text only; prints timings, never model output.
enum PrefillYieldProbe {
    static let okSchema = GenerationSchemaSpec(name: "PrefillProbe", json: #"""
        {"additionalProperties":false,"properties":{"ok":{"type":"boolean"}},"required":["ok"],"title":"PrefillProbe","type":"object","x-order":["ok"]}
        """#)

    static let lines = [
        "Priya: let us start with the quarterly numbers for the northern region before we move on to hiring.",
        "Marcus: the supplier confirmed the second shipment arrives two weeks after the first, so we are fine.",
        "Priya: I think we should test the onboarding flow with five new people next Tuesday morning.",
        "Marcus: can you share the draft budget so finance can review it before Friday?",
        "Priya: the migration finished overnight and the error rate stayed below half a percent.",
        "Marcus: we agreed to keep the old pricing page live until the new one has been reviewed.",
        "Priya: my concern is that the training schedule overlaps with the holiday week in December.",
        "Marcus: the prototype handles about forty requests a second on the smaller machine.",
    ]

    static func transcript(words: Int) -> String {
        var out: [String] = []
        var count = 0
        var index = 0
        while count < words {
            let line = lines[index % lines.count]
            out.append(line)
            count += line.split(separator: " ").count
            index += 1
        }
        return out.joined(separator: "\n")
    }

    static func run(_ args: Arguments) async throws {
        let model = try args.mlxModel()
        let trials = args.int("trials") ?? 20
        let chunks = (args.string("chunks") ?? "128,512").split(separator: ",").compactMap { Int($0) }
        let prompt = transcript(words: args.int("words") ?? 4_400)
        let instructions = "Read this meeting transcript and answer whether it mentions a budget."
        var background = LanguageModelOptions.greedy
        background.isBackground = true

        try await model.loadForMeasurement()
        let idle = try await idleDictation(model, runs: 8)
        print(String(format: "idle dictation call: p50 %.0f ms, p95 %.0f ms", percentile(idle, 0.5), percentile(idle, 0.95)))
        for chunk in chunks {
            await model.setMeasurementBackgroundPromptChunk(chunk)
            let full = try await model.respondMeasured(
                instructions: instructions, prompt: prompt, schema: okSchema, options: background, usePrefixCache: false)
            let leads = full.timings.leadChunkMilliseconds
            let prefill = leads.reduce(0, +)
            print(String(
                format: "chunk %d: prompt %d tokens, %d chunks, chunk ms p50 %.1f p95 %.1f max %.1f, prefill %.0f ms, call %.0f ms",
                chunk, full.timings.promptTokens, leads.count, percentile(leads, 0.5), percentile(leads, 0.95), leads.max() ?? 0,
                prefill, full.timings.totalMilliseconds))
            var stops: [Double] = []
            var waits: [Double] = []
            for _ in 0..<trials {
                let (stop, wait) = try await preempt(
                    model, instructions: instructions, prompt: prompt, pressAfter: Double.random(in: 0.05...0.9) * prefill)
                stops.append(stop)
                waits.append(wait)
            }
            let extra = waits.map { $0 - percentile(idle, 0.5) }
            print(String(
                format: "chunk %d: %d presses: stop after press p50 %.0f ms p95 %.0f ms max %.0f ms; dictation call p50 %.0f ms p95 %.0f ms (idle p50 %.0f, extra p95 %.0f ms)",
                chunk, trials, percentile(stops, 0.5), percentile(stops, 0.95), stops.max() ?? 0,
                percentile(waits, 0.5), percentile(waits, 0.95), percentile(idle, 0.5), percentile(extra, 0.95)))
        }
        await model.setMeasurementBackgroundPromptChunk(128)
    }

    /// A dictation-sized cleanup call, warm prefix: what the release waits for.
    static func dictationCall(_ model: MLXLanguageModel) async throws -> Double {
        let began = ContinuousClock.now
        _ = try await model.respond(
            instructions: MeetingDictationProbe.instructions, prompt: MeetingDictationProbe.sentence,
            schema: SmartCleaner.cleanedSchema, options: .greedy)
        return MeetingDictationProbe.seconds(ContinuousClock.now - began) * 1_000
    }

    static func idleDictation(_ model: MLXLanguageModel, runs: Int) async throws -> [Double] {
        _ = try await dictationCall(model)
        var out: [Double] = []
        for _ in 0..<runs { out.append(try await dictationCall(model)) }
        return out
    }

    /// One press during a background call through the app's route. Returns (ms from the press until the background call
    /// gave way, ms of the dictation call sent at the press).
    static func preempt(
        _ model: MLXLanguageModel, instructions: String, prompt: String, pressAfter milliseconds: Double
    ) async throws -> (Double, Double) {
        let activity = ForegroundActivity()
        let route = MeetingLanguageModel(shared: model, apple: NullLanguageModel(), activity: activity, health: ModelHealth())
        route.route(for: .local(ModelRegistry.hushyCleanup4B))
        let summary = Task { () -> ContinuousClock.Instant in
            _ = try? await route.respond(instructions: instructions, prompt: prompt, schema: okSchema, options: .greedy)
            return .now
        }
        try await Task.sleep(for: .milliseconds(Int(milliseconds)))
        let pressed = ContinuousClock.now
        activity.set(busy: true)
        let wait = try await dictationCall(model)
        let stopped = await summary.value
        activity.set(busy: false)
        return (MeetingDictationProbe.seconds(stopped - pressed) * 1_000, wait)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}
