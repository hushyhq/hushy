import Foundation
import MurmurCore

/// A way of answering one case. Two modes, both through the `LanguageModel` seam
/// (`LanguageModels.current`, chosen by `--backend apple|mlx|none`):
///
/// - `extractor`: the shipping path — `ActionExtractor` (Apple FM guided generation of 0–3
///   events/reminders/shortcuts) — mapped into tools-v1 calls. The baseline.
/// - `catalog`: the tools-v1 prompt and flat envelope (`VoiceToolCatalog`) — what a fine-tuned
///   local model answers. One call per utterance, with a `no_action` reason.
protocol ToolEvalBackend: Sendable {
    var label: String { get }
    var isAvailable: Bool { get }
    func prewarm()
    func answer(_ item: ToolEvalCase) async -> ToolEvalAnswer
}

enum ToolEvalMode: String, Sendable {
    case extractor
    case catalog
}

struct ExtractorToolBackend: ToolEvalBackend {
    let model: any LanguageModel
    /// Only for `prewarm`; each case builds its own extractor around that case's library.
    let extractor: ActionExtractor

    let budget: Duration

    /// `ActionExtractor`'s default budget (its `init` default), repeated here because the
    /// actor's stored `budget` can't be read synchronously.
    static let shippingBudget: Duration = .milliseconds(2_500)

    /// `budget` defaults to the shipping `ActionExtractor` budget (2.5 s); a longer one measures
    /// the model's answers apart from timeouts on a loaded machine.
    init(model: any LanguageModel, budget: Duration? = nil) {
        self.model = model
        let resolved = budget ?? Self.shippingBudget
        self.extractor = ActionExtractor(budget: resolved, model: model)
        self.budget = resolved
    }

    var label: String {
        let seconds = String(format: "%.1f", Double(budget.components.seconds) + Double(budget.components.attoseconds) / 1e18)
        return "\(model.identifier) · extractor (ActionExtractor, shipping path, \(seconds) s budget, \(EvalShortcutLibrary.label))"
    }
    var isAvailable: Bool { model.isAvailable }
    func prewarm() { extractor.prewarm() }

    func answer(_ item: ToolEvalCase) async -> ToolEvalAnswer {
        let context = item.context.dateContext
        let clock = ContinuousClock()
        let start = clock.now
        // A fresh extractor per case: the simulated Shortcuts library differs per case.
        let library = EvalShortcutLibrary.names(for: item)
        // …and its own ModelHealth: the eval measures the model, so a slow stretch must not turn
        // later cases into instant skips.
        let caseExtractor = ActionExtractor(budget: budget, model: model, shortcutLibrary: { library }, health: ModelHealth())
        let output = await caseExtractor.extract(item.utterance, context: context)
        let latency = ToolsRunner.milliseconds(clock.now - start)
        // The model was asked unless the rules answered first (a refusal or, on older code, the gate)
        // or its health gate skipped the call.
        var modelCalled = output.usedModel
        if case .rejected(let reason) = output.result, !reason.hasPrefix("skipped") { modelCalled = true }
        switch output.result {
        case .actions(let actions):
            var plan = false
            if case .actNow = ActionDispatch.plan(actions, utterance: item.utterance, setting: .risky) { plan = true }
            return ToolEvalAnswer(
                calls: actions.map { ToolCall(proposedAction: $0, timeZone: context.timeZone) }, latencyMs: latency,
                modelCalled: modelCalled, actsAtOnce: plan)
        case .refused(let refusal):
            return ToolEvalAnswer(calls: [.noAction(refusal.reason.noActionReason)], latencyMs: latency, modelCalled: modelCalled)
        case .notAnAction:
            return ToolEvalAnswer(calls: [], latencyMs: latency, modelCalled: modelCalled)
        case .modelUnavailable:
            return ToolEvalAnswer(calls: [], error: "model unavailable", latencyMs: latency, modelCalled: modelCalled)
        case .rejected(let reason):
            return ToolEvalAnswer(calls: [], error: reason, latencyMs: latency, modelCalled: modelCalled)
        }
    }
}

struct CatalogToolBackend: ToolEvalBackend {
    let model: any LanguageModel
    let budget: Duration

    var label: String { "\(model.identifier) · catalog (\(VoiceToolCatalog.version) prompt + flat envelope + VoiceToolGuard, \(EvalShortcutLibrary.label))" }
    var isAvailable: Bool { model.isAvailable }

    func prewarm() {
        model.prewarm(instructions: VoiceToolCatalog.instructions)
    }

    static func prompt(for item: ToolEvalCase) -> String {
        VoiceToolCatalog.userPrompt(contextLine: item.context.promptLine(), utterance: item.utterance)
    }

    func answer(_ item: ToolEvalCase) async -> ToolEvalAnswer {
        let clock = ContinuousClock()
        let start = clock.now
        // Same deterministic pre-model refusal as the shipping extractor.
        if let refusal = ActionSafetyScreen.unsupportedRequest(in: item.utterance) {
            return ToolEvalAnswer(calls: [.noAction(refusal.reason.noActionReason)], latencyMs: ToolsRunner.milliseconds(clock.now - start))
        }
        let json = await respond(Self.prompt(for: item))
        let latency = ToolsRunner.milliseconds(clock.now - start)
        guard let json else { return ToolEvalAnswer(calls: [], error: "timeout or model error", latencyMs: latency) }
        guard let call = ToolCall(envelopeJSON: json) else {
            return ToolEvalAnswer(calls: [], error: "malformed envelope", latencyMs: latency)
        }
        let reviewed = VoiceToolGuard.review(call, utterance: item.utterance, installedShortcuts: EvalShortcutLibrary.names(for: item))
        return ToolEvalAnswer(calls: [reviewed], latencyMs: latency)
    }

    /// One guided call raced against `budget` (the seam has no deadline of its own).
    private func respond(_ prompt: String) async -> String? {
        let model = self.model
        let budget = self.budget
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await model.respond(
                    instructions: VoiceToolCatalog.instructions, prompt: prompt, schema: VoiceToolCatalog.envelopeSchema,
                    options: .greedy)
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// `--backend mlx` before the MLX adapter (`claude/mlx-adapter`) is merged: a named, unavailable
/// model, so `tools` reports SKIPPED instead of scoring a floor under the wrong label.
struct UnavailableLanguageModel: LanguageModel {
    let identifier: String
    let reason: String

    var availability: LanguageModelAvailability { .unavailable(reason: reason) }
    func supportsLanguage(_ languageCode: String) -> Bool { false }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        throw LanguageModelError.unavailable(reason)
    }
}

/// The Shortcuts library a case is scored against. The eval files carry no library, so each case
/// simulates a user who has the Shortcut(s) the case expects them to name (in the expected call,
/// its alternatives or its split) plus a few unrelated ones. Uniform for dev and held-out, never
/// tuned: it only decides whether a proposed name exists, so a Shortcut that isn't expected —
/// an injected "wipe disk", a misheard name — is refused exactly as on a real Mac.
enum EvalShortcutLibrary {
    static let label = "Shortcuts library = expected names + 5 unrelated"

    static let unrelated = ["Text Last Image", "Make GIF", "Water Eject", "Home ETA", "Shazam It"]

    static func names(for item: ToolEvalCase) -> [String] {
        let calls = item.expect.acceptableCalls + (item.expect.split ?? [])
        let expected = calls.filter { $0.tool == "run_shortcut" }.compactMap { call -> String? in
            guard case .string(let name)? = call.arguments["name"] else { return nil }
            return name
        }
        return expected + unrelated
    }
}
