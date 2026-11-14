import Foundation
import Synchronization
import os

/// A `LanguageModel` whose backend can be replaced while the app runs. `SmartCleaner` captures
/// its model at init, so the app hands it one of these and the "Cleanup model" setting swaps
/// what's inside (Apple FM ↔ local MLX chain ↔ none) without a restart. A call already running
/// finishes on the backend it started with.
public final class SwitchableLanguageModel: LanguageModel {
    private let inner: Mutex<any LanguageModel>
    private let wholeTranscript = Mutex(false)
    private let registerLines = Mutex(false)

    public init(_ initial: any LanguageModel) {
        inner = Mutex(initial)
    }

    public var current: any LanguageModel { inner.withLock { $0 } }

    public func replace(with model: any LanguageModel) {
        inner.withLock { $0 = model }
    }

    /// Whether cleanup sends the whole-transcript prompt: the backend in place was trained on it (what is set here) and the
    /// first model of its chain can answer now. While that model is paused its fallback answers, and the fallback was
    /// built for the rules-draft prompt and the word-level guard, so cleanup asks it that way until the model is back.
    public var usesWholeTranscript: Bool {
        get { wholeTranscript.withLock { $0 } && firstModelAvailable }
        set { wholeTranscript.withLock { $0 = newValue } }
    }

    private var firstModelAvailable: Bool {
        let model = current
        return (model as? FallbackLanguageModel)?.primary.isAvailable ?? model.isAvailable
    }

    /// Whether the backend in place was trained on the register line (`LocalModelEntry.understandsRegisterLines`).
    public var understandsRegisterLines: Bool {
        get { registerLines.withLock { $0 } }
        set { registerLines.withLock { $0 = newValue } }
    }

    public var identifier: String { current.identifier }
    public var availability: LanguageModelAvailability { current.availability }
    public var contextTokens: Int { current.contextTokens }
    public func supportsLanguage(_ languageCode: String) -> Bool { current.supportsLanguage(languageCode) }
    public func prewarm(instructions: String) { current.prewarm(instructions: instructions) }
    public func prefixCache(instructions: String) async { await current.prefixCache(instructions: instructions) }
    public func warmForDictation(instructions: String) async { await current.warmForDictation(instructions: instructions) }

    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        try await current.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
    }
}

/// The last few model calls — backend, outcome and latency, never the text — for the Settings
/// diagnostics line ("Local model · 212 ms · 198 ms · Apple 1.9 s").
public final class ModelCallLog: Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Outcome: String, Sendable {
            case answered, failed, cancelled
        }

        public let backend: String
        public let milliseconds: Double
        public let outcome: Outcome
        public let at: Date
        public let modelIdentifier: String?

        public init(backend: String, milliseconds: Double, outcome: Outcome, at: Date, modelIdentifier: String? = nil) {
            self.backend = backend
            self.milliseconds = milliseconds
            self.outcome = outcome
            self.at = at
            self.modelIdentifier = modelIdentifier
        }
    }

    private let entries = Mutex<[Entry]>([])
    private let loggedAnswers = Mutex<Set<String>>([])
    private static let logger = Logger(subsystem: "app.hushy", category: "cleanup-model")
    private let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    public var recent: [Entry] { entries.withLock { $0 } }

    public func record(_ entry: Entry) {
        entries.withLock {
            $0.append(entry)
            if $0.count > capacity { $0.removeFirst($0.count - capacity) }
        }
        if entry.outcome == .answered {
            let identity = entry.modelIdentifier ?? entry.backend
            let first = loggedAnswers.withLock { logged -> Bool in
                logged.insert(entry.backend + ":" + identity).inserted
            }
            if first {
                Self.logger.notice("first successful model response backend=\(entry.backend, privacy: .public) model=\(identity, privacy: .public)")
            }
        }
    }

    public func clear() {
        entries.withLock { $0.removeAll() }
    }
}

/// Times each call of `base` into a `ModelCallLog` under `label`. Content never reaches the log.
public struct RecordingLanguageModel: LanguageModel {
    public let base: any LanguageModel
    public let label: String
    public let log: ModelCallLog

    public init(_ base: any LanguageModel, label: String, log: ModelCallLog) {
        self.base = base
        self.label = label
        self.log = log
    }

    public var identifier: String { base.identifier }
    public var availability: LanguageModelAvailability { base.availability }
    public var contextTokens: Int { base.contextTokens }
    public func supportsLanguage(_ languageCode: String) -> Bool { base.supportsLanguage(languageCode) }
    public func prewarm(instructions: String) { base.prewarm(instructions: instructions) }
    public func prefixCache(instructions: String) async { await base.prefixCache(instructions: instructions) }
    public func warmForDictation(instructions: String) async { await base.warmForDictation(instructions: instructions) }

    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let start = ContinuousClock.now
        do {
            let answer = try await base.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
            record(.answered, since: start)
            return answer
        } catch is CancellationError {
            record(.cancelled, since: start)
            throw CancellationError()
        } catch {
            record(.failed, since: start)
            throw error
        }
    }

    private func record(_ outcome: ModelCallLog.Entry.Outcome, since start: ContinuousClock.Instant) {
        log.record(.init(backend: label, milliseconds: ModelPace.ms(ContinuousClock.now - start), outcome: outcome,
                         at: Date(), modelIdentifier: base.identifier))
    }
}
