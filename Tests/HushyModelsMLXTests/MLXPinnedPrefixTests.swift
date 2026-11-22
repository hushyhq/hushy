import Foundation
import Synchronization
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

/// The next dictation after a voice action, a voice edit or a restyle finds its cleanup prefix warm. The real callers
/// (`SmartCleaner`, `ActionExtractor`, `VoiceEditor`, `SelectionRestyler`, `ScreenSummarizer`) run against a model
/// that only records what they ask for; each request is then filed the way `MLXEngine` files it (the intent model's
/// system text, `PrefixKey.filing`, `PrefixPolicy`) in a store of the shipped shape.
@Suite("Cleanup prefixes stay pinned")
struct MLXPinnedPrefixTests {
    /// What a caller asked of the model: a warm-up or a call, its instructions and schema, and whether it was background.
    private struct Request: Sendable {
        var instructions: String
        var schema: GenerationSchemaSpec
        var policy: PrefixPolicy
    }

    /// Records every request and answers none, so each caller takes its own no-answer path.
    private final class RecordingModel: LanguageModel {
        private let log = Mutex<[Request]>([])
        private let schemas = Mutex<[String: GenerationSchemaSpec]>([:])

        var identifier: String { "recording" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }

        /// Like `MLXLanguageModel.schema(for:)`: the schema last used with the instructions, cleanup's before any call.
        private func schema(for instructions: String) -> GenerationSchemaSpec {
            schemas.withLock { $0[instructions] } ?? SmartCleaner.cleanedSchema
        }

        func prewarm(instructions: String) {
            log.withLock { $0.append(Request(instructions: instructions, schema: schema(for: instructions), policy: .warmUp)) }
        }

        func prefixCache(instructions: String) async { prewarm(instructions: instructions) }

        func warmForDictation(instructions: String) async {
            log.withLock { $0.append(Request(instructions: instructions, schema: schema(for: instructions), policy: .dictation)) }
        }

        func respond(
            instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
        ) async throws -> String {
            schemas.withLock { $0[instructions] = schema }
            log.withLock { $0.append(Request(instructions: instructions, schema: schema, policy: PrefixPolicy(options))) }
            throw LanguageModelError.unavailable("recording only")
        }

        func drain() -> [Request] { log.withLock { requests in defer { requests = [] }; return requests } }
    }

    /// The prefix cache of the 4B intent model, fed requests in order.
    private struct Cache {
        var store = PrefixCacheStore<Int>(pinnedCapacity: 4, transientCapacity: 2)
        var builds: [PrefixSlot: Int] = [:]

        mutating func feed(_ requests: [Request]) {
            for request in requests {
                let system = MLXLanguageModel.systemText(instructions: request.instructions, schema: request.schema, profile: .intent)
                let (key, slot) = PrefixKey.filing(system: system, schema: request.schema, adapterOn: false)
                _ = store.resolve(key, slot: slot, policy: request.policy) {
                    builds[slot, default: 0] += 1
                    return 0
                }
            }
        }
    }

    private static let budget = Duration.seconds(1)
    /// An invented page, long enough for a screen summary.
    private static let page = String(repeating: "The planning group met on Tuesday to review the beta schedule and the open design questions. ", count: 12)

    /// One dictation in each register, as `SmartCleaner.ask` sends it on the intent model.
    private func dictateInEveryRegister(_ model: RecordingModel) async {
        for register in [nil] + IntentRegister.allCases.map(Optional.some) {
            _ = await SmartCleaner.ask(
                model: model, draft: "so the review moved to friday at three", budget: Self.budget,
                intentProfile: true, register: register, firstModelOnly: true)
        }
    }

    /// Everything a person may do between two dictations that asks the same model for something else.
    private func actionsEditsAndRestyles(_ model: RecordingModel) async {
        let actions = ActionExtractor(budget: Self.budget, model: model, health: ModelHealth(), probeBudget: Self.budget)
        actions.prewarm()
        _ = await actions.extract(
            "remind me to call the dentist tomorrow at noon",
            context: DateContext(now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!))
        _ = await VoiceEditor.edit(
            VoiceEditRequest(selection: "The draft is ready for review.", instruction: "make it shorter"), model: model,
            budget: Self.budget)
        for style in RestyleStyle.allCases {
            _ = await SelectionRestyler.restyle("hey, the draft is ready, take a look", as: style, model: model, budget: Self.budget)
        }
        _ = await ScreenSummarizer(model: model, budget: Self.budget).summarize(Self.page)
    }

    @Test("cleanup, then an action, a voice edit and every restyle, then cleanup: no cleanup prefix is built again")
    func cleanupStaysWarm() async {
        let model = RecordingModel()
        var cache = Cache()
        await dictateInEveryRegister(model)
        cache.feed(model.drain())
        #expect(cache.builds[.pinned] == 4, "the plain prompt and three register lines")
        let warm = cache.store.keys(.pinned)

        await actionsEditsAndRestyles(model)
        let between = model.drain()
        let others = Set(between.map(\.schema.name)).subtracting(PrefixSlot.cleanupSchemaNames)
        #expect(others.count >= 3, "actions, voice edit and screen ask with their own schemas: \(others.sorted())")
        cache.feed(between)
        #expect(cache.builds[.transient, default: 0] >= 3, "more transient prompts than transient slots: they take turns")
        #expect(Set(cache.store.keys(.pinned)) == Set(warm), "no cleanup prefix was evicted")

        await dictateInEveryRegister(model)
        cache.feed(model.drain())
        #expect(cache.builds[.pinned] == 4, "the next dictation in each register is a hit, not a rebuild")
    }

    @Test("the old single 4-slot LRU loses cleanup prefixes to the same sequence")
    func sharedLRUWouldRebuild() async {
        let model = RecordingModel()
        var shared = PrefixCacheStore<Int>(pinnedCapacity: 4, transientCapacity: 0)
        var builds = 0
        func feed(_ requests: [Request]) {
            for request in requests {
                let system = MLXLanguageModel.systemText(instructions: request.instructions, schema: request.schema, profile: .intent)
                _ = shared.resolve(PrefixKey(system: system), slot: .pinned, policy: request.policy) { builds += 1; return 0 }
            }
        }
        await dictateInEveryRegister(model)
        feed(model.drain())
        await actionsEditsAndRestyles(model)
        feed(model.drain())
        let before = builds
        await dictateInEveryRegister(model)
        feed(model.drain())
        #expect(builds > before, "without the partition the dictation after an action rebuilds its prefix")
    }

    @Test("a cleanup prompt is pinned only with the adapter off; every other schema is transient")
    func slots() {
        #expect(PrefixSlot.of(schemaName: SmartCleaner.cleanedSchema.name, adapterOn: false) == .pinned)
        #expect(PrefixSlot.of(schemaName: SmartCleaner.groupCleanedSchema.name, adapterOn: false) == .pinned)
        #expect(PrefixSlot.of(schemaName: SmartCleaner.cleanedSchema.name, adapterOn: true) == .transient)
        #expect(PrefixSlot.of(schemaName: VoiceEditor.Edited.generationSchema.name, adapterOn: false) == .transient)
        #expect(PrefixSlot.of(schemaName: GeneratedActionEnvelope.generationSchema.name, adapterOn: false) == .transient)
    }
}
