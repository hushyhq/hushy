import Foundation
import MurmurCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `LanguageModel` backed by Apple's on-device Foundation Models (macOS 26+, Apple Intelligence
/// on). The only place in Hushy that imports `FoundationModels`.
///
/// Every call is a fresh `LanguageModelSession(instructions:)` with the caller's instructions,
/// exactly as `SmartCleaner`, `ModeExecutor` and `ActionExtractor` created them before the seam.
/// Guided generation decodes the caller's `GenerationSchemaSpec` into a `GenerationSchema`; each
/// spec is pinned to the `@Generable` type it replaced (`HushyModelsAppleTests`), so the schema
/// the model sees is byte-for-byte the same.
///
/// Text transformations are the exception (2026-09-27, DECISIONS "Apple FM errors are memory
/// pressure"): a call marked `LanguageModelOptions.textTransform` whose schema's whole answer is
/// one string field (Clean's `Cleaned`, a mode's `Transformed`) is generated as plain text under
/// `.permissiveContentTransformations` and wrapped back into that field. Apple's permissive guardrails only apply to `String` generation; with guided
/// generation the default guardrails threw on ordinary dictation ("kill the process and shoot the
/// email over to legal") and silently dropped words ("what the hell is wrong" → "what is wrong").
public struct AppleFoundationModel: MurmurCore.LanguageModel {
    /// Plain text under permissive guardrails for text-transform calls (the default), or guided
    /// generation under the default guardrails for everything (before 2026-09-27; kept for
    /// `murmur-eval --backend apple-guided` A/B runs).
    public let permissiveTextTransforms: Bool

    public init(permissiveTextTransforms: Bool = true) {
        self.permissiveTextTransforms = permissiveTextTransforms
    }

    public var identifier: String { "apple-fm" }

    public var availability: LanguageModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason): return .unavailable(reason: String(describing: reason))
            }
        }
        #endif
        return .unavailable(reason: "Apple Foundation Models needs macOS 26")
    }

    public func supportsLanguage(_ languageCode: String) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let target = Locale.Language(identifier: languageCode)
            return SystemLanguageModel.default.supportedLanguages.contains { supported in
                supported.languageCode?.identifier(.alpha2) == target.languageCode?.identifier(.alpha2)
            }
        }
        #endif
        return false
    }

    public func prewarm(instructions: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            LanguageModelSession(model: Self.model(permissive: permissiveTextTransforms), instructions: instructions).prewarm()
        }
        #endif
    }

    /// Apple's framework has no cross-session prefix cache; nothing to do.
    public func prefixCache(instructions: String) async {}

    public func respond(
        instructions: String, prompt: String, schema: MurmurCore.GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let generationSchema = try Self.decode(schema)
            do {
                if permissiveTextTransforms, options.textTransform, let field = Self.singleStringField(schema) {
                    let session = LanguageModelSession(model: Self.model(permissive: true), instructions: instructions)
                    let text = try await session.respond(to: prompt, options: Self.generationOptions(options)).content
                    return try Self.wrap(Self.plainAnswer(text), field: field)
                }
                let response = try await LanguageModelSession(instructions: instructions).respond(
                    to: prompt, schema: generationSchema, options: Self.generationOptions(options))
                return response.content.jsonString
            } catch {
                throw Self.classify(error)
            }
        }
        #endif
        throw LanguageModelError.unavailable("Apple Foundation Models needs macOS 26")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func decode(_ spec: MurmurCore.GenerationSchemaSpec) throws -> GenerationSchema {
        do {
            return try JSONDecoder().decode(GenerationSchema.self, from: Data(spec.json.utf8))
        } catch {
            throw LanguageModelError.unsupportedSchema("\(spec.name): \(error)")
        }
    }

    @available(macOS 26.0, *)
    static func model(permissive: Bool) -> SystemLanguageModel {
        permissive ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : .default
    }
    #endif

    /// The property name when the schema's whole answer is one required string field — a text
    /// transformation — else nil.
    static func singleStringField(_ spec: MurmurCore.GenerationSchemaSpec) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(spec.json.utf8)) as? [String: Any],
              object["type"] as? String == "object",
              let properties = object["properties"] as? [String: Any], properties.count == 1,
              let entry = properties.first,
              (entry.value as? [String: Any])?["type"] as? String == "string",
              (object["required"] as? [String])?.contains(entry.key) == true
        else { return nil }
        return entry.key
    }

    /// The model's plain-text answer without the few-shot scaffolding it may echo: a leading
    /// "Output:" (the prompt ends with that label), a further "Transcript:" example it goes on to
    /// invent, and surrounding whitespace.
    static func plainAnswer(_ text: String) -> String {
        var answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.hasPrefix("Output:") { answer = String(answer.dropFirst("Output:".count)) }
        if let next = answer.range(of: "\nTranscript:") { answer = String(answer[..<next.lowerBound]) }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wrap(_ text: String, field: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [field: text]), as: UTF8.self)
    }

    #if canImport(FoundationModels)
    /// Maps a framework error onto `LanguageModelError`, so callers can tell "the system won't run
    /// anything right now" and "the safety layer declined this text" from a slow model
    /// (`ModelCallFailure`, `ModelHealth`). Measured on macOS 27 (DECISIONS 2026-09-27 "Apple FM
    /// errors are memory pressure"): under critical memory pressure `modelmanagerd` refuses every
    /// request ("Not executed due to current system state [CriticalMemoryPressure], try again
    /// later" = `ModelManagerServices.ModelManagerError` 1013). The prompt's safety check runs
    /// first, so the error usually arrives as a plain `NSError`
    /// `com.apple.SensitiveContentAnalysisML` 15 → `CombinedTextSanitizerBackend.BackendError` 1 →
    /// `ModelManagerError` 1013 — not a `GenerationError` — within ~50 ms.
    @available(macOS 26.0, *)
    static func classify(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation(let context): return LanguageModelError.refused("guardrail: \(context.debugDescription)")
            case .refusal(_, let context): return LanguageModelError.refused("refusal: \(context.debugDescription)")
            case .rateLimited(let context), .concurrentRequests(let context):
                return LanguageModelError.busy(context.debugDescription)
            case .assetsUnavailable(let context): return LanguageModelError.unavailable(context.debugDescription)
            default: break
            }
        }
        let nsError = error as NSError
        return isSystemBusy(nsError) ? LanguageModelError.busy(chain(nsError)) : error
    }
    #endif

    /// Whether an `NSError` chain bottoms out in `modelmanagerd` refusing to run the request now.
    static func isSystemBusy(_ error: NSError) -> Bool {
        var current: NSError? = error
        var depth = 0
        while let e = current, depth < 8 {
            if e.domain.hasSuffix("ModelManagerError"), e.code == modelManagerSystemStateCode { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// `ModelManagerServices.ModelManagerError` code for "not executed due to current system state".
    static let modelManagerSystemStateCode = 1013

    /// "domain#code > domain#code …" for the log (`NSLocalizedDescription` is private there).
    static func chain(_ error: NSError) -> String {
        var parts: [String] = []
        var current: NSError? = error
        while let e = current, parts.count < 8 {
            parts.append("\(e.domain)#\(e.code)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " > ")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func generationOptions(_ options: LanguageModelOptions) -> GenerationOptions {
        switch options.sampling {
        case .greedy: GenerationOptions(samplingMode: .greedy, temperature: 0)
        case .systemDefault: GenerationOptions()
        }
    }
    #endif

    /// Debug-only latency probe for `murmur-eval model-diag --latency-probe` (moved here from
    /// `SmartCleaner.debugLatencyProbe`, since it measures Apple session features the seam does not
    /// expose): ms for (fresh session, prewarmed session, one-line instructions, second turn of a
    /// reused session) on the same draft. Empty when the framework is unavailable.
    public static func latencyProbe(instructions: String, schema: MurmurCore.GenerationSchemaSpec, draft: String) async -> [Double] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), let generationSchema = try? decode(schema) else { return [] }
        let prompt = "Transcript: \(draft)\nOutput:"
        let options = GenerationOptions(samplingMode: .greedy, temperature: 0)
        func time(_ session: LanguageModelSession) async -> Double {
            let start = ContinuousClock.now
            _ = try? await session.respond(to: prompt, schema: generationSchema, options: options)
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        let fresh = await time(LanguageModelSession(instructions: instructions))
        let warmed = LanguageModelSession(instructions: instructions)
        warmed.prewarm(promptPrefix: Prompt("Transcript: "))
        try? await Task.sleep(for: .seconds(3))
        let prewarmed = await time(warmed)
        let short = await time(LanguageModelSession(instructions: "Remove filler words and stutters from the dictation transcript. Keep everything else."))
        let reused = LanguageModelSession(instructions: instructions)
        _ = try? await reused.respond(to: "Transcript: Okay.\nOutput:", schema: generationSchema, options: options)
        let secondTurn = await time(reused)
        return [fresh, prewarmed, short, secondTurn]
        #else
        return []
        #endif
    }
}
