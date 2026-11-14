import Foundation
import Synchronization
import Testing
@testable import MurmurCore

@Suite("FallbackLanguageModel")
struct FallbackLanguageModelTests {
    @Test("primary answers when it can")
    func primaryFirst() async throws {
        let chain = FallbackLanguageModel(primary: Scripted(.answer("p")), secondary: Scripted(.answer("s")))
        #expect(try await ask(chain) == "p")
    }

    @Test("a primary error falls through to the secondary")
    func errorFallsThrough() async throws {
        let chain = FallbackLanguageModel(primary: Scripted(.fail), secondary: Scripted(.answer("s")))
        #expect(try await ask(chain) == "s")
    }

    @Test("an unavailable primary is skipped without being called")
    func unavailablePrimary() async throws {
        let primary = Scripted(.answer("p"), available: false)
        let chain = FallbackLanguageModel(primary: primary, secondary: Scripted(.answer("s")))
        #expect(try await ask(chain) == "s")
        #expect(primary.callCount == 0)
        #expect(chain.isAvailable)
    }

    @Test("cancellation does not fall through")
    func cancellationStops() async {
        let secondary = Scripted(.answer("s"))
        let chain = FallbackLanguageModel(primary: Scripted(.cancel), secondary: secondary)
        await #expect(throws: CancellationError.self) { try await ask(chain) }
        #expect(secondary.callCount == 0)
    }

    @Test("both unavailable → unavailable, and the caller's rules path runs")
    func bothUnavailable() async {
        let chain = FallbackLanguageModel(primary: Scripted(.fail, available: false), secondary: NullLanguageModel())
        #expect(!chain.isAvailable)
        let output = await SmartCleaner(model: chain).clean("um so ship it friday", options: CleanupOptions(level: .polished))
        #expect(!output.usedModel)
    }

    private func ask(_ model: any LanguageModel) async throws -> String {
        try await model.respond(instructions: "i", prompt: "p", schema: SmartCleaner.cleanedSchema, options: .greedy)
    }
}

private final class Scripted: LanguageModel {
    enum Behavior: Sendable {
        case answer(String)
        case fail
        case cancel
    }

    let behavior: Behavior
    let available: Bool
    private let calls = Mutex(0)

    init(_ behavior: Behavior, available: Bool = true) {
        self.behavior = behavior
        self.available = available
    }

    var callCount: Int { calls.withLock { $0 } }
    var identifier: String { "scripted" }
    var availability: LanguageModelAvailability { available ? .available : .unavailable(reason: "off") }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        calls.withLock { $0 += 1 }
        switch behavior {
        case .answer(let text): return text
        case .fail: throw LanguageModelError.unavailable("boom")
        case .cancel: throw CancellationError()
        }
    }
}
