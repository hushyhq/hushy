import Foundation

/// Tries `primary`, and on any failure other than cancellation asks `secondary` — the runtime
/// order in `docs/product/MODEL-STRATEGY.md` §3.1 (MLX → Apple FM → rules): when both fail or are
/// unavailable, the call throws and the caller takes its rules path as it always has. The
/// caller's budget covers both attempts (cancellation stops whichever is running).
public struct FallbackLanguageModel: LanguageModel {
    public let primary: any LanguageModel
    public let secondary: any LanguageModel

    public init(primary: any LanguageModel, secondary: any LanguageModel) {
        self.primary = primary
        self.secondary = secondary
    }

    public var identifier: String { "\(primary.identifier)>\(secondary.identifier)" }

    public var availability: LanguageModelAvailability {
        if primary.isAvailable || secondary.isAvailable { return .available }
        return primary.availability
    }

    /// The window of whichever backend a call goes to first. A prompt that only fits the
    /// primary's window fails on the secondary, and the caller takes its short-prompt path.
    public var contextTokens: Int {
        primary.isAvailable ? primary.contextTokens : secondary.contextTokens
    }

    public func supportsLanguage(_ languageCode: String) -> Bool {
        (primary.isAvailable && primary.supportsLanguage(languageCode))
            || (secondary.isAvailable && secondary.supportsLanguage(languageCode))
    }

    public func prewarm(instructions: String) {
        (primary.isAvailable ? primary : secondary).prewarm(instructions: instructions)
    }

    public func prefixCache(instructions: String) async {
        await (primary.isAvailable ? primary : secondary).prefixCache(instructions: instructions)
    }

    public func warmForDictation(instructions: String) async {
        await (primary.isAvailable ? primary : secondary).warmForDictation(instructions: instructions)
    }

    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        if options.firstModelOnly {
            guard primary.isAvailable else { throw LanguageModelError.unavailable("\(primary.identifier) cannot answer now") }
            return try await primary.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
        }
        if primary.isAvailable {
            do {
                return try await primary.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // Nothing to fall back to: the caller should hear why the primary failed (a busy
                // local model under memory pressure), not "no model configured".
                guard secondary.isAvailable else { throw error }
            }
        }
        return try await secondary.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
    }
}
