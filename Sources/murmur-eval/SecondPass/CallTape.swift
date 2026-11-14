import Foundation
import MurmurCore
import Synchronization

/// A recording of model calls made during one live arm of `murmur-eval second-pass`, so the same dictations can be
/// run again with the second pass off or under a time budget and get exactly the answers the live run got.
///
/// Why: Apple's model does not give the same answer twice, so two live runs differ by more than the thing being
/// compared. Replaying the recorded answers removes that noise: the only difference between a replayed arm and the
/// recorded one is whether a second-pass answer is used. Invented dev text only; nothing here is written by the app.
final class CallTape: Sendable {
    struct Take: Codable, Sendable {
        /// The model's answer, nil when the call failed.
        let answer: String?
        /// A fixed word for why it failed: `cancelled` (cut off at its deadline), `busy`, `refused`, `unavailable`,
        /// `malformed`, `unsupported` or `error`.
        let failure: String?
        let ms: Double
    }

    private struct State {
        var takes: [String: [Take]] = [:]
        var cursors: [String: Int] = [:]
        var scope = ""
        var hits = 0
        var misses = 0
        var late = 0
    }

    private let state = Mutex(State())

    /// Calls are keyed inside one dictation, so the same sentence in two dictations cannot swap answers.
    func begin(scope: String) {
        state.withLock { state in
            state.scope = scope
            state.cursors = state.cursors.filter { !$0.key.hasPrefix(scope + "\u{1}") }
        }
    }

    private func key(_ label: String, _ instructions: String, _ prompt: String, _ schema: String, scope: String) -> String {
        [scope, label, schema, instructions, prompt].joined(separator: "\u{1}")
    }

    func record(label: String, instructions: String, prompt: String, schema: String, take: Take) {
        state.withLock { state in
            state.takes[key(label, instructions, prompt, schema, scope: state.scope), default: []].append(take)
        }
    }

    /// The next recorded call for this request, in the order they were made; the last one repeats if asked again.
    func next(label: String, instructions: String, prompt: String, schema: String) -> Take? {
        state.withLock { state in
            let name = key(label, instructions, prompt, schema, scope: state.scope)
            guard let takes = state.takes[name], !takes.isEmpty else { state.misses += 1; return nil }
            let index = min(state.cursors[name, default: 0], takes.count - 1)
            state.cursors[name] = index + 1
            state.hits += 1
            return takes[index]
        }
    }

    func noteLate() { state.withLock { $0.late += 1 } }

    /// Replay counters since the last call, then reset: answers served, requests with no recording, answers
    /// withheld because they arrived after the budget.
    func drainCounters() -> (hits: Int, misses: Int, late: Int) {
        state.withLock { state in
            defer { state.hits = 0; state.misses = 0; state.late = 0 }
            return (state.hits, state.misses, state.late)
        }
    }
}

/// The recorded answer arrived after the budget of the arm being replayed: the caller keeps the first pass.
struct LateAnswer: Error {}

/// Wraps one model for `murmur-eval second-pass`: records its calls onto a tape, or answers from one.
struct TapedModel: LanguageModel {
    enum Role: Sendable {
        case record
        /// `budgetMs`: an answer that took longer than this when it was recorded is withheld (the second pass under
        /// a time budget). nil replays every answer.
        case replay(budgetMs: Double?)
    }

    let base: any LanguageModel
    let label: String
    let tape: CallTape
    let role: Role

    var identifier: String { base.identifier }
    var contextTokens: Int { base.contextTokens }
    var availability: LanguageModelAvailability {
        if case .replay = role { return .available }
        return base.availability
    }
    func supportsLanguage(_ languageCode: String) -> Bool { base.supportsLanguage(languageCode) }
    func prewarm(instructions: String) { if case .record = role { base.prewarm(instructions: instructions) } }
    func prefixCache(instructions: String) async { if case .record = role { await base.prefixCache(instructions: instructions) } }

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        switch role {
        case .record:
            let start = ContinuousClock.now
            func note(_ answer: String?, _ failure: String?) {
                tape.record(label: label, instructions: instructions, prompt: prompt, schema: schema.name,
                            take: .init(answer: answer, failure: failure, ms: ModelPace.ms(ContinuousClock.now - start)))
            }
            do {
                let answer = try await base.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
                note(answer, nil)
                return answer
            } catch {
                note(nil, Task.isCancelled || error is CancellationError ? "cancelled" : Self.word(for: error))
                throw error
            }
        case .replay(let budgetMs):
            guard let take = tape.next(label: label, instructions: instructions, prompt: prompt, schema: schema.name) else {
                throw LanguageModelError.unavailable("no recorded call for this request")
            }
            if let budgetMs, take.ms > budgetMs {
                tape.noteLate()
                throw LateAnswer()
            }
            if let answer = take.answer { return answer }
            // A call the live run cut off at its deadline: wait to be cut off again, as the model did.
            if take.failure == "cancelled" {
                try await Task.sleep(for: .seconds(600))
                throw CancellationError()
            }
            throw Self.error(for: take.failure ?? "error")
        }
    }

    static func word(for error: Error) -> String {
        guard let known = error as? LanguageModelError else { return "error" }
        switch known {
        case .unavailable: return "unavailable"
        case .unsupportedSchema: return "unsupported"
        case .malformedOutput: return "malformed"
        case .busy: return "busy"
        case .refused: return "refused"
        }
    }

    static func error(for word: String) -> Error {
        switch word {
        case "unavailable": return LanguageModelError.unavailable("replayed")
        case "unsupported": return LanguageModelError.unsupportedSchema("replayed")
        case "malformed": return LanguageModelError.malformedOutput("replayed")
        case "busy": return LanguageModelError.busy("replayed")
        case "refused": return LanguageModelError.refused("replayed")
        default: return NSError(domain: "second-pass-replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "replayed model error"])
        }
    }
}
