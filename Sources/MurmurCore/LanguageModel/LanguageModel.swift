import Foundation
import Synchronization

/// The seam every model-backed feature (cleanup, rerank, modes, note digests, voice actions) calls
/// through, so the backend can be Apple's Foundation Models (`HushyModelsApple`), an MLX model
/// (M2, `docs/product/MODEL-STRATEGY.md`) or nothing at all (`NullLanguageModel` → rules path).
///
/// The shape follows Apple's macOS 27 Foundation Models `LanguageModel` protocol where it makes
/// sense — availability, supported languages, instructions + prompt, guided generation against a
/// JSON schema, prewarm — so Apple's own bridge can become one more adapter later. It differs in
/// two places on purpose: (1) there is no session object — every Hushy call is one fresh,
/// single-turn request, which is what the callers already did; (2) guided generation is described
/// by a `GenerationSchemaSpec` (JSON schema text) and answered with JSON text, so `MurmurCore`
/// never needs `import FoundationModels` and an MLX backend can do constrained JSON from the same
/// schema.
///
/// Timeouts and cancellation: `respond` has no deadline of its own. Callers race it against their
/// budget with `respond(instructions:prompt:generating:options:budget:)`, which cancels the call
/// on timeout. Implementations must therefore stop promptly (within milliseconds) when their task
/// is cancelled, and throw — never block past cancellation.
public protocol LanguageModel: Sendable {
    /// Short, stable name for logs and eval reports ("apple-fm", "none", later "mlx:<hf-id>").
    var identifier: String { get }

    /// Whether the model can be called right now. Checked before every call; cheap.
    var availability: LanguageModelAvailability { get }

    /// The context window in tokens (instructions, prompt and answer together). Callers that
    /// could send a long prompt (note summaries) size their requests to it. Defaults to
    /// `LanguageModelContext.defaultTokens`, Apple's on-device model's window.
    var contextTokens: Int { get }

    /// Whether the model can work in `languageCode` (ISO 639-1, e.g. "es"). `false` when unknown.
    func supportsLanguage(_ languageCode: String) -> Bool

    /// Loads the model ahead of time (recording start) so the first call is warm. Fire and
    /// forget; must never block the caller.
    func prewarm(instructions: String)

    /// Hook for backends that can keep a KV cache of a fixed instructions prefix across calls
    /// (MLX, M2). Apple's framework gives no control over this, so its adapter does nothing.
    func prefixCache(instructions: String) async

    /// Touch model weights during speech without changing a later response or its prompt.
    func warmForDictation(instructions: String) async

    /// One single-turn, guided-generation request: `instructions` are the system half, `prompt`
    /// is the user half (always data), and the answer is JSON text that validates against
    /// `schema`. Throws on unavailability, cancellation, refusal or malformed output.
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String

    /// Background work (note summaries) awaits this before each model call, outside its call budget, so a
    /// model shared with dictation can let a dictation in progress go first. Returns at once by default;
    /// `MeetingLanguageModel` is the one that waits.
    func yieldToForeground() async
}

public enum LanguageModelAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

public struct LanguageModelOptions: Sendable, Equatable {
    public enum Sampling: Sendable, Equatable {
        /// Deterministic: greedy decoding, temperature 0 (every cleanup/action call).
        case greedy
        /// The backend's own default sampling (note summaries).
        case systemDefault
    }

    public var sampling: Sampling
    /// The caller rewrites the user's own text (Clean, custom modes) and wants the answer's one
    /// string field as-is. A backend may then relax content guardrails meant for open-ended
    /// generation: Apple generates plain text under `.permissiveContentTransformations` (DECISIONS
    /// 2026-09-27 "Apple FM errors are memory pressure"). Ignored by backends without such a mode.
    public var textTransform: Bool
    /// The request is worded for the first model of a chain only: the whole-transcript prompt the local intent model was
    /// trained on, judged by the guard measured with it. A `FallbackLanguageModel` does not hand it to its fallback,
    /// which was built for the rules-draft prompt and the word-level guard; the caller takes its rules path instead.
    public var firstModelOnly: Bool
    /// Work no one is waiting on (a meeting summary on the model dictation uses). A backend stops it when it is
    /// cancelled and leaves nothing of it running, so the dictation that cancelled it never waits behind it.
    public var isBackground = false

    public init(sampling: Sampling, textTransform: Bool = false, firstModelOnly: Bool = false) {
        self.sampling = sampling
        self.textTransform = textTransform
        self.firstModelOnly = firstModelOnly
    }

    public static let greedy = LanguageModelOptions(sampling: .greedy)
    /// Greedy, for a rewrite of the user's own text (`textTransform`).
    public static let greedyTextTransform = LanguageModelOptions(sampling: .greedy, textTransform: true)
    public static let systemDefault = LanguageModelOptions(sampling: .systemDefault)
}

/// A guided-generation schema: `json` is a JSON Schema in exactly the form Apple's
/// `GenerationSchema` encodes to (so the Apple adapter decodes it losslessly; `HushyModelsAppleTests`
/// pins each one to the `@Generable` type it replaced), and `name` is its `title`.
public struct GenerationSchemaSpec: Sendable, Hashable {
    public let name: String
    public let json: String

    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}

/// A structured answer type: decoded from the model's JSON, described by `generationSchema`.
public protocol StructuredOutput: Decodable, Sendable {
    static var generationSchema: GenerationSchemaSpec { get }
}

public enum LanguageModelError: Error, Sendable, Equatable {
    case unavailable(String)
    case unsupportedSchema(String)
    case malformedOutput(String)
    /// The system declined to run the request right now and said to try again later. Apple:
    /// `modelmanagerd` refuses every request while it sees critical memory pressure
    /// (`ModelManagerError 1013`, usually wrapped in `SensitiveContentAnalysisML` error 15 because
    /// the safety check is the first request to be refused), and rate limits. Fast and transient;
    /// says nothing about how quickly the model answers once it runs.
    case busy(String)
    /// The model's safety layer declined this content (guardrail violation or refusal).
    /// Deterministic for the same input; says nothing about speed.
    case refused(String)
}

/// Why a budgeted call produced no answer — what `ModelHealth` and the log's `why=` need to tell
/// a slow model (`timeout`) from one the system won't run right now (`busy`), content the safety
/// layer declined (`refused`), and anything else (`error`).
public enum ModelCallFailure: Error, Sendable, Equatable {
    /// The budget ran out first; the call was cancelled.
    case timeout
    case busy
    case refused
    /// The caller's task was cancelled (a superseded prewarm, release deadline).
    case cancelled
    /// Any other error: unavailable, unsupported schema, unknown.
    case error
    /// The model answered, but not with a usable answer (it ran past its answer cap, or the JSON did not
    /// decode). A greedy call repeats the same answer, so asking again only doubles the wait.
    case malformed
    /// No call was made: earlier calls were abandoned at their deadline and are still running, and one
    /// more would only join them (`AbandonedCalls`).
    case notResponding

    public init(_ error: any Error) {
        self = switch error {
        case LanguageModelError.busy: .busy
        case LanguageModelError.refused: .refused
        case LanguageModelError.malformedOutput: .malformed
        case is CancellationError: .cancelled
        default: .error
        }
    }
}

public enum LanguageModelContext {
    /// Apple's on-device Foundation Model: 4,096 tokens for instructions + prompt + answer.
    public static let defaultTokens = 4_096
}

extension LanguageModel {
    public func yieldToForeground() async {}
    public func warmForDictation(instructions: String) async {
        prewarm(instructions: instructions)
    }
    public var isAvailable: Bool { availability.isAvailable }
    public var contextTokens: Int { LanguageModelContext.defaultTokens }

    /// Guided generation into a `StructuredOutput` type.
    public func respond<Output: StructuredOutput>(
        instructions: String, prompt: String, generating: Output.Type, options: LanguageModelOptions
    ) async throws -> Output {
        let json = try await respond(
            instructions: instructions, prompt: prompt, schema: Output.generationSchema, options: options)
        do {
            return try JSONDecoder().decode(Output.self, from: Data(json.utf8))
        } catch {
            throw LanguageModelError.malformedOutput("\(Output.generationSchema.name): \(error)")
        }
    }

    /// Races one call against `budget`: returns nil on timeout, cancellation or any error, and
    /// cancels the in-flight call on timeout. The same race every caller used to write inline.
    public func respond<Output: StructuredOutput>(
        instructions: String, prompt: String, generating: Output.Type, options: LanguageModelOptions,
        budget: Duration, abandoned: AbandonedCalls? = nil
    ) async -> Output? {
        try? await respondResult(
            instructions: instructions, prompt: prompt, generating: Output.self, options: options, budget: budget,
            abandoned: abandoned
        ).get()
    }

    /// The same race, saying why no answer came (`ModelCallFailure`).
    public func respondResult<Output: StructuredOutput>(
        instructions: String, prompt: String, generating: Output.Type, options: LanguageModelOptions,
        budget: Duration, abandoned: AbandonedCalls? = nil
    ) async -> Result<Output, ModelCallFailure> {
        // Calls left behind at their deadline by a backend that ignores cancellation are counted; with too
        // many still outstanding, one more is not started.
        if let abandoned, !abandoned.tryBegin() { return .failure(.notResponding) }
        // A hard bound: control returns at the budget even if the backend ignores cancellation.
        let deadline = ContinuousClock.now.advanced(by: budget)
        let result = await HardDeadline.run(until: deadline, tracking: abandoned) { () async -> Result<Output, ModelCallFailure> in
            do {
                return .success(try await self.respond(
                    instructions: instructions, prompt: prompt, generating: Output.self, options: options))
            } catch {
                return .failure(Task.isCancelled ? .cancelled : ModelCallFailure(error))
            }
        }
        if let result { return result }
        return .failure(Task.isCancelled ? .cancelled : .timeout)
    }
}

/// No model: always unavailable, so every caller takes its rules path. The default until an
/// app or tool registers a real backend (`LanguageModels.current`), and `murmur-eval --backend none`.
public struct NullLanguageModel: LanguageModel {
    public init() {}

    public var identifier: String { "none" }
    public var availability: LanguageModelAvailability { .unavailable(reason: "no language model configured") }
    public func supportsLanguage(_ languageCode: String) -> Bool { false }
    public func prewarm(instructions: String) {}
    public func prefixCache(instructions: String) async {}
    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        throw LanguageModelError.unavailable("no language model configured")
    }
}

/// The process-wide default backend. The app and `murmur-eval` set it once at launch, before
/// constructing any cleaner; `SmartCleaner`, `ModeExecutor`, `ActionExtractor` and the static
/// helpers take a `model:` parameter that defaults to it.
public enum LanguageModels {
    private static let storage = Mutex<any LanguageModel>(NullLanguageModel())
    private static let meetingStorage = Mutex<(any LanguageModel)?>(nil)

    public static var current: any LanguageModel {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// A separately loaded meeting model, when its verified artefact is installed.
    /// Otherwise summaries use the ordinary on-device fallback.
    public static var meeting: any LanguageModel {
        get { meetingStorage.withLock { $0 } ?? current }
        set { meetingStorage.withLock { $0 = newValue } }
    }
}
