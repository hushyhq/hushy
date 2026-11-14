import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// The `LanguageModel` seam (docs/product/MODEL-STRATEGY.md M1): MurmurCore stays free of
/// FoundationModels, `NullLanguageModel` means "rules only", and every model-backed caller goes
/// through the injected backend with its existing budget. Tests inject models; none of them sets
/// `LanguageModels.current`, which other suites read concurrently.
@Suite("LanguageModel seam")
struct LanguageModelSeamTests {
    @Test("no file in Sources/MurmurCore imports FoundationModels")
    func murmurCoreDoesNotImportFoundationModels() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MurmurCore")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "test setup: expected to find MurmurCore's sources at \(root.path)")
        let offenders = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("import FoundationModels") }
        }
        #expect(offenders.isEmpty, "import FoundationModels in: \(offenders.map(\.lastPathComponent))")
    }

    @Test("NullLanguageModel is unavailable, supports no language and throws on respond")
    func nullModelIsUnavailable() async {
        let model = NullLanguageModel()
        #expect(!model.isAvailable)
        #expect(!model.supportsLanguage("en"))
        await #expect(throws: LanguageModelError.self) {
            try await model.respond(instructions: "x", prompt: "y", schema: SmartCleaner.cleanedSchema, options: .greedy)
        }
    }

    @Test("with NullLanguageModel, Polished cleanup takes the rules path")
    func nullModelFallsBackToRules() async {
        let cleaner = SmartCleaner(model: NullLanguageModel())
        let output = await cleaner.clean("um so we need to ship the report by Friday", options: CleanupOptions(level: .polished))
        #expect(!output.usedModel)
        #expect(output.rejection == "model unavailable")
        #expect(!output.text.isEmpty)
    }

    @Test("a short Clean dictation asks the model")
    func shortCleanAsks() async {
        let model = FakeModel(json: #"{"text": "Hello there."}"#)
        _ = await SmartCleaner(model: model, health: ModelHealth())
            .clean("hello there", options: CleanupOptions(level: .clean))
        #expect(model.calls.filter { $0.schema == "Cleaned" }.count == 1)
    }

    @Test("a dictation carries a content-free trace of what the model did for it")
    func outputCarriesGroupTrace() async {
        let accepted = FakeModel(json: #"{"text": "We need to ship the report."}"#)
        let used = await SmartCleaner(model: accepted, health: ModelHealth())
            .clean("we need to ship the report", options: CleanupOptions(level: .clean))
        #expect(used.groups.count == 1)
        #expect(used.groups[0].outcome == .used)
        #expect(used.groups[0].modelMs != nil)
        #expect(used.groups[0].rejectedCandidate == nil)

        let skipped = await SmartCleaner(model: NullLanguageModel())
            .clean("we need to ship the report", options: CleanupOptions(level: .clean))
        #expect(skipped.groups.count == 1)
        #expect(skipped.groups[0].outcome == .unavailable)
        #expect(skipped.groups[0].modelMs == nil)
    }

    @Test("a guard rejection keeps the answer only when the cleaner was built to retain it")
    func rejectedCandidateIsRetainedOnlyOnRequest() async {
        let inventive = FakeModel(json: #"{"text": "We should definitely postpone the quarterly planning review meeting."}"#)
        let spoken = "we need to ship the report"
        let kept = await SmartCleaner(model: inventive, health: ModelHealth(), retainsRejectedCandidates: true)
            .clean(spoken, options: CleanupOptions(level: .clean))
        #expect(kept.groups[0].outcome == .rejectedByGuard)
        #expect(kept.groups[0].rejectedCandidate?.contains("postpone") == true)
        let dropped = await SmartCleaner(model: inventive, health: ModelHealth())
            .clean(spoken, options: CleanupOptions(level: .clean))
        #expect(dropped.groups[0].outcome == .rejectedByGuard)
        #expect(dropped.groups[0].rejectedCandidate == nil)
    }

    @Test("a segmented dictation traces every group, with where each came from")
    func segmentedTraceHasEveryGroup() async {
        let model = FakeModel(json: #"{"text": "Hello there."}"#)
        let transcript = Array(repeating: "We need to finish the report before Friday and send it to the team.", count: 12)
            .joined(separator: " ")
        let output = await SmartCleaner(model: model, health: ModelHealth())
            .clean(transcript, options: CleanupOptions(level: .clean))
        #expect(output.groups.count == output.groupSources.count)
        #expect(output.groups.map(\.source) == output.groupSources.map { Optional($0) })
    }

    @Test("each long dictation group asks the model")
    func everyGroupAsks() async {
        let model = FakeModel(json: #"{"text": "Hello there."}"#)
        let transcript = Array(repeating: "We need to finish the report before Friday and send it to the team.", count: 12)
            .joined(separator: " ")
        let output = await SmartCleaner(model: model, health: ModelHealth())
            .clean(transcript, options: CleanupOptions(level: .clean))
        #expect(output.groupSources.count > 1)
        #expect(model.calls.count == output.groupSources.count)
    }

    @Test("only a critical thermal state suppresses model calls")
    func criticalThermalGate() {
        // Task 110: "serious" is common on a busy laptop and used to silence the model; only critical does.
        #expect(!SmartCleaner.shouldSkipForThermal(.nominal))
        #expect(!SmartCleaner.shouldSkipForThermal(.fair))
        #expect(!SmartCleaner.shouldSkipForThermal(.serious))
        #expect(SmartCleaner.shouldSkipForThermal(.critical))
    }

    @Test("cleanup asks the injected model with the cleanup instructions and decodes its JSON")
    func cleanupUsesInjectedModel() async {
        let fake = FakeModel(json: #"{"text": "We need to ship the report by Friday."}"#)
        let answer = await SmartCleaner.debugAsk(draft: "we need to ship the report by Friday", budgetMs: 5_000, model: fake)
        #expect(answer == "We need to ship the report by Friday.")
        guard let call = fake.calls.first else {
            Issue.record("the injected model was never called")
            return
        }
        #expect(call.schema == "Cleaned")
        #expect(call.prompt == "Transcript: we need to ship the report by Friday\nOutput:")
        #expect(call.instructions == SmartCleaner.cleanupInstructions(confidenceGuided: false))
        #expect(call.options == .greedyTextTransform)
    }

    @Test("a call that outlives its budget returns nil and is cancelled")
    func budgetCancelsSlowModel() async {
        let fake = FakeModel(json: #"{"text": "late"}"#, delay: .seconds(120))
        // The model takes two minutes and the budget is 100 ms, so a call that waited for the model
        // would take 120 s. Half of that cannot be reached by a busy machine, and SuspendingClock
        // does not count time the Mac spent asleep.
        let clock = SuspendingClock()
        let start = clock.now
        let answer = await SmartCleaner.debugAsk(draft: "hello", budgetMs: 100, model: fake)
        #expect(answer == nil)
        #expect(clock.now - start < .seconds(60))
        // The call is cancelled right after the caller gets control back; give it a moment to notice.
        for _ in 0..<100 where !fake.sawCancellation { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fake.sawCancellation)
    }

    @Test("malformed model JSON is a rejected answer, not a crash")
    func malformedJSONIsNil() async {
        let fake = FakeModel(json: #"{"nope": 1}"#)
        let answer = await SmartCleaner.debugAsk(draft: "hello", budgetMs: 5_000, model: fake)
        #expect(answer == nil)
    }

    @Test("prewarm forwards the Clean instructions to the injected model")
    func prewarmForwardsInstructions() {
        let fake = FakeModel(json: "{}")
        SmartCleaner(model: fake).prewarm()
        #expect(fake.prewarmed == [SmartCleaner.cleanupInstructions(confidenceGuided: false)])
    }

    @Test("ActionExtractor decodes the action envelope from the injected model")
    func actionExtractorUsesInjectedModel() async {
        let fake = FakeModel(json: """
            {"speech": "askingYou", "actions": [{"kind": "createReminder", "title": "Buy flowers", "when": "", "durationMinutes": 0, \
            "listOrCalendarName": "", "location": "", "shortcutInput": ""}]}
            """)
        let output = await ActionExtractor(model: fake).extract("remind me to buy flowers", context: DateContext(now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!))
        #expect(output.usedModel)
        guard case .actions(let actions) = output.result else {
            Issue.record("expected actions, got \(output.result)")
            return
        }
        #expect(actions.map(\.kind) == [.createReminder])
        #expect(actions.first?.title == "Buy flowers")
        #expect(fake.calls.first?.schema == "GeneratedActionEnvelope")
    }

    @Test("ActionExtractor with NullLanguageModel reports the model unavailable")
    func actionExtractorNullModel() async {
        let output = await ActionExtractor(model: NullLanguageModel()).extract("remind me to buy flowers", context: DateContext(now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!))
        #expect(output.result == .modelUnavailable)
    }

    @Test("ModeExecutor sends the mode instruction to the injected model")
    func modeExecutorUsesInjectedModel() async {
        let fake = FakeModel(json: #"{"text": "- Buy milk\n- Call the bank"}"#)
        let mode = Mode(name: "Bullets", icon: "list.bullet", cleanupLevel: .clean, prompt: "Reformat as bullets.")
        _ = await ModeExecutor.apply(mode, to: "Buy milk. Call the bank.", model: fake)
        #expect(fake.calls.first?.schema == "Transformed")
        #expect(fake.calls.first?.instructions.contains("\"Reformat as bullets.\"") == true)
        #expect(fake.calls.first?.prompt == "Text:\nBuy milk. Call the bank.")
    }

    @Test("note summaries go through the injected model, greedy (extraction, reproducible)")
    func summaryUsesInjectedModel() async {
        let fake = FakeModel(json: #"{"title": "Plan", "keyPoints": ["Ship it"], "decisions": [], "actionItems": []}"#)
        let transcript = Array(repeating: "We talked about the launch plan and who owns the checklist.", count: 10).joined(separator: " ")
        let output = await SmartCleaner.summarize(transcript, fallbackTitle: "Note", model: fake)
        #expect(output.title == "Plan")
        #expect(fake.calls.first?.options == .greedy)
        #expect(fake.calls.first?.schema == "MeetingDigest")
    }
}

/// A scripted `LanguageModel`: returns `json` after `delay`, recording every call.
private final class FakeModel: LanguageModel {
    struct Call: Sendable {
        let instructions: String
        let prompt: String
        let schema: String
        let options: LanguageModelOptions
    }

    private struct State {
        var calls: [Call] = []
        var prewarmed: [String] = []
        var sawCancellation = false
    }

    private let json: String
    private let delay: Duration
    private let state = Mutex(State())

    init(json: String, delay: Duration = .zero) {
        self.json = json
        self.delay = delay
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var prewarmed: [String] { state.withLock { $0.prewarmed } }
    var sawCancellation: Bool { state.withLock { $0.sawCancellation } }

    var identifier: String { "fake" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) { state.withLock { $0.prewarmed.append(instructions) } }
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        state.withLock { $0.calls.append(Call(instructions: instructions, prompt: prompt, schema: schema.name, options: options)) }
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch {
                state.withLock { $0.sawCancellation = true }
                throw error
            }
        }
        return json
    }
}
