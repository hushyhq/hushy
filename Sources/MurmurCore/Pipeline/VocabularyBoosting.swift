import Foundation

/// One term to bias speech recognition towards: the canonical spelling plus phonetic variants
/// the recognizer tends to mishear it as. Mirrors `DictionaryEntry` (term + soundsLike) but
/// lives in the pipeline layer so `Transcriber` conformers that need FluidAudio's own
/// `CustomVocabularyTerm` (see `SpeechEngine`) can convert one-to-one without `MurmurCore`
/// depending on FluidAudio.
public struct VocabularyTerm: Sendable, Equatable {
    /// Where a term came from, which decides how much a boost to it may overwrite (`BoostGuard`).
    public enum Source: Sendable, Equatable {
        /// The person's own Dictionary entry or a term the personal lexicon learned from them: explicit evidence of what
        /// they mean, so a heard number the term spells is part of the term ("node 22 Alpine" is "node:22-alpine").
        case personal
        /// Read from the window or the project's files: "try 95" stays when "TRY-95" is only on screen.
        case context
        /// A name from a domain pack (`DomainPack`): the boosted text keeps a pack name the recogniser already wrote
        /// (`PackNameGuard`).
        case pack
        /// An installed app's display name (`InstalledNamePolicy`).
        case installedApp
        /// Hushy's own names.
        case builtIn
        /// A built-in AI model or product name an AI-prompt app adds (`VocabularyContext.aiModelTerms`): the boosted text keeps
        /// it only where the sentence supports it (`AIModelBoostGuard`).
        case aiModel
    }

    public let text: String
    public let aliases: [String]
    public let source: Source

    public var installedApp: Bool { source == .installedApp }
    public var fromPack: Bool { source == .pack }
    public var aiModel: Bool { source == .aiModel }

    public init(text: String, aliases: [String] = [], source: Source = .context) {
        self.text = text
        self.aliases = aliases
        self.source = source
    }
}

/// The vocabulary to bias one transcription pass towards. Built from the user's Dictionary
/// entries (never snippet trigger phrases — those are expansions, not names the recognizer
/// needs to hear correctly) so names, jargon and acronyms are boosted for every dictation and
/// note chunk.
public struct VocabularyContext: Sendable, Equatable {
    public let terms: [VocabularyTerm]

    public init(terms: [VocabularyTerm] = []) {
        self.terms = terms
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Applies `BoostGuard` with the word-frequency table (`WordFrequency.isOrdinary`): boosts may fix names and
    /// jargon but never overwrite a common word the recognizer heard.
    public func guarded(original: String, boosted: String) -> String {
        let userTerms = Set(terms.filter { !$0.installedApp }.map { BoostGuard.key($0.text) })
        let installed = terms.filter { $0.installedApp && !userTerms.contains(BoostGuard.key($0.text)) }.map(\.text)
        var filtered = BoostGuard.filter(
            original: original, boosted: boosted, terms: terms.map(\.text), installedTerms: installed,
            personalTerms: terms.filter { $0.source == .personal }.map(\.text)
        ) { WordFrequency.shared.isOrdinary($0) }
        if terms.contains(where: \.fromPack) { filtered = PackNameGuard.keepHeardNames(original: original, boosted: filtered) }
        let aiTerms = terms.filter(\.aiModel).map(\.text)
        if !aiTerms.isEmpty { filtered = AIModelBoostGuard.keepSupported(original: original, boosted: filtered, aiTerms: aiTerms) }
        // A case-only change of an ordinary word ("next" -> "Next") keeps the recogniser's casing; the Dictionary pass
        // after cleanup recases it where the sentence names the product (`OrdinaryTermCase`).
        // Built-in AI model names keep their own cue-based fixer (`AIProductNameFixer`).
        let builtIn = Set((Self.builtInTerms + Self.aiModelTerms).map(\.text))
        filtered = OrdinaryTermCase.keepRecogniserCase(
            original: original, boosted: filtered, terms: terms.filter { !$0.installedApp && !builtIn.contains($0.text) }.map(\.text))
        // LCS alignment regards case-only changes as the same word. Restore the ASR's casing
        // for ordinary words so a multiword app term cannot capitalize normal prose.
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = filtered.split(whereSeparator: \.isWhitespace).map(String.init)
        guard before.count == after.count else { return filtered }
        let appWords = Set(terms.filter(\.installedApp).flatMap {
            $0.text.split(whereSeparator: \.isWhitespace).map { BoostGuard.key(String($0)) }
        })
        guard !appWords.isEmpty else { return filtered }
        let userWords = Set(terms.filter { !$0.installedApp }.flatMap {
            $0.text.split(whereSeparator: \.isWhitespace).map { BoostGuard.key(String($0)) }
        })
        let ranges = Regex.matchesCaseSensitive(filtered, "\\S+").compactMap { Range($0.range, in: filtered) }
        guard ranges.count == after.count else { return filtered }
        var replacements: [(Range<String.Index>, String)] = []
        for ((old, new), range) in zip(zip(before, after), ranges) {
            let key = BoostGuard.key(old)
            if key == BoostGuard.key(new) && appWords.contains(key) && !userWords.contains(key)
                && LearningLexicon.isCommonWord(old.lowercased()) && old != new {
                replacements.append((range, old))
            }
        }
        var result = filtered
        for (range, word) in replacements.reversed() { result.replaceSubrange(range, with: word) }
        return result
    }

    public static let empty = VocabularyContext()

    public static let builtInTerms: [VocabularyTerm] = [
        VocabularyTerm(text: "Hushy", aliases: ["Hushi", "Husshy", "Hashi"], source: .builtIn),
        VocabularyTerm(text: "tryhushy.com", aliases: ["try hushy dot com"], source: .builtIn)
    ]

    /// The AI model and product names, boosted for the recogniser in an AI-prompt app (`PipelineSettings.aiPromptApp`).
    /// "Sonnet" is heard as "son at", "Claude" as "cloud". `BoostGuard` still keeps an ordinary word the recogniser heard
    /// plainly, and `AIModelBoostGuard` keeps a swap to one of these only in a sentence about AI; `AIModelNames` and
    /// `AIProductNameFixer` spell what is left, where a cue says it is the name.
    public static let aiModelTerms: [VocabularyTerm] = [
        "Sonnet", "Opus", "Haiku", "Claude Code", "Claude", "Anthropic", "Codex", "Gemini", "GPT", "ChatGPT",
    ].map { VocabularyTerm(text: $0, source: .aiModel) }

    /// Builds a vocabulary context from Dictionary entries. `soundsLike` variants become
    /// aliases; entries with an empty term are skipped.
    public static func from(dictionary: [DictionaryEntry]) -> VocabularyContext {
        VocabularyContext(terms: dictionary.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let aliases = entry.soundsLike.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return VocabularyTerm(text: term, aliases: aliases, source: .personal)
        })
    }
}

/// Measures how long vocabulary boosting adds to a transcription, so the hot path can log it
/// (see `SpeechEngine.transcribe` and `.claude/DECISIONS.md`'s latency budget). Pure/testable:
/// no I/O, just arithmetic over caller-supplied timestamps.
public struct VocabularyBoostingLatency: Sendable, Equatable {
    public let baseMs: Double
    public let boostedMs: Double

    public init(baseMs: Double, boostedMs: Double) {
        self.baseMs = baseMs
        self.boostedMs = boostedMs
    }

    /// Milliseconds added by running the CTC boosting pass on top of the base ASR transcription.
    /// Never negative — a boosted pass that (due to timer noise) measures faster than the base
    /// pass reports zero added cost rather than a misleading negative number.
    public var addedMs: Double { max(0, boostedMs - baseMs) }
}
