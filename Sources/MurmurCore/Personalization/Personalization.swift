import Foundation

/// A word the user wants spelled a specific way, optionally with spoken variants
/// the recognizer tends to produce ("cooper netties" -> "Kubernetes").
public struct DictionaryEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    public var term: String
    public var soundsLike: [String]
    public var createdAt: Date

    public init(id: Int64? = nil, term: String, soundsLike: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.soundsLike = soundsLike
        self.createdAt = createdAt
    }
}

/// A spoken trigger that expands into longer text ("my calendar link" -> "https://…").
public struct Snippet: Codable, Sendable, Equatable, Identifiable, Hashable {
    public static let maxTriggerLength = 60
    public static let maxExpansionLength = 4_000

    public var id: Int64?
    public var trigger: String
    public var expansion: String
    public var createdAt: Date

    public init(id: Int64? = nil, trigger: String, expansion: String, createdAt: Date = Date()) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.createdAt = createdAt
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case emptyTrigger, triggerTooLong, emptyExpansion, expansionTooLong

        public var errorDescription: String? {
            switch self {
            case .emptyTrigger: "Say something to trigger the snippet."
            case .triggerTooLong: "Keep the trigger under \(Snippet.maxTriggerLength) characters."
            case .emptyExpansion: "The snippet needs some text to insert."
            case .expansionTooLong: "Snippets can be up to \(Snippet.maxExpansionLength) characters."
            }
        }
    }

    public func validate() throws(ValidationError) {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw .emptyTrigger }
        if trimmed.count > Snippet.maxTriggerLength { throw .triggerTooLong }
        if expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .emptyExpansion }
        if expansion.count > Snippet.maxExpansionLength { throw .expansionTooLong }
    }
}

/// Applies dictionary spellings and snippet expansions to cleaned text.
public struct Personalizer: Sendable {
    private let globalDictionary: [DictionaryEntry]
    private let scopedTerms: [LearnedItem]
    private var appBundleID: String?
    public var dictionary: [DictionaryEntry] {
        guard !scopedTerms.isEmpty else { return globalDictionary }
        return globalDictionary + LearnedPersonalization.dictionaryEntries(
            from: scopedTerms, excluding: globalDictionary, appBundleID: appBundleID)
    }

    /// Resolve app-only learned casing from the cached snapshot; no I/O.
    public func scoped(to app: String?) -> Self {
        var copy = self
        copy.appBundleID = app
        return copy
    }
    public let snippets: [Snippet]
    public var keep: KeepHeardSet
    /// Built on first use and shared by every `scoped(to:)` copy; the Dictionary of one `Personalizer` never changes.
    private let matcherCache = DictionaryMatcherCache()

    public init(dictionary: [DictionaryEntry] = [], snippets: [Snippet] = [], keep: KeepHeardSet = .empty, scopedTerms: [LearnedItem] = []) {
        self.globalDictionary = dictionary
        self.scopedTerms = scopedTerms
        self.appBundleID = nil
        self.snippets = snippets
        self.keep = keep
    }

    public struct Output: Sendable, Equatable {
        public let text: String
        public let dictionaryFixes: Int
        public let snippetsUsed: Int
    }

    public func apply(_ text: String) -> Output {
        let (recased, fixes) = applyDictionary(text)
        // An ordinary-word Dictionary term ("Notion") keeps its capitals only where the sentence names the product.
        let (spelled, restored) = OrdinaryTermCase.restore(original: text, applied: recased, terms: dictionary.map(\.term))
        let (expanded, used) = applySnippets(spelled)
        return Output(text: expanded, dictionaryFixes: max(0, fixes - restored), snippetsUsed: used)
    }

    /// Terms the recognizer should be biased towards, for engines that support it.
    public var vocabulary: [String] { dictionary.map(\.term) }

    /// Heard-as spellings that `apply` rewrites to a Dictionary term.
    public var heardAliases: [ProtectedTermGuard.Alias] {
        dictionary.flatMap { entry in
            entry.soundsLike
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(entry.term) != .orderedSame }
                .map { ProtectedTermGuard.Alias(heard: $0, term: entry.term) }
        }
    }

    /// The same case-insensitive variant lookup used by Dictionary replacement, for one heard word.
    func protectsHeardWord(_ word: String) -> Bool {
        dictionary.contains { entry in
            ([entry.term] + entry.soundsLike).contains {
                !$0.isEmpty && $0.caseInsensitiveCompare(word) == .orderedSame
            }
        }
    }

    /// Dictionary replacement in one pass over the text (`DictionaryMatcher`), with the same results as
    /// `applyDictionarySequential`, which it falls back to for text holding scalars the matcher cannot fold.
    func applyDictionary(_ text: String) -> (String, Int) {
        let matcher = matcherCache.matcher(for: appBundleID) { DictionaryMatcher(entries: dictionary) }
        if let applied = matcher.apply(text, keep: keep) { return (applied.text, applied.fixes) }
        return Self.applyDictionarySequential(text, entries: dictionary, keep: keep)
    }

    /// The reference implementation: one case-insensitive regex per heard phrase, applied in order. Kept as the oracle for
    /// the differential tests and the benchmark, and as the exact path for text the matcher declines.
    static func applyDictionarySequential(_ text: String, entries: [DictionaryEntry], keep: KeepHeardSet) -> (String, Int) {
        var out = text
        var fixes = 0
        for entry in entries where !entry.term.isEmpty {
            // Longest variants first so "cooper netties" wins over "cooper".
            let variants = (entry.soundsLike + [entry.term]).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            for variant in variants {
                let pattern = "(?<![\\w])\(Regex.escape(variant))(?![\\w])"
                // A heard phrase inside text that already reads as the term (the term contains the phrase, as in
                // "jimmylord" -> "jimmylord.com") is replaced together with the rest of that reading, so a replacement
                // applied to its own output changes nothing.
                var spans: [Range<String.Index>] = []
                for match in Regex.matches(out, pattern) {
                    guard let heard = Range(match.range, in: out) else { continue }
                    guard !keep.blocks(heardKey: VocabularySwap.key(String(out[heard])), writtenKey: VocabularySwap.key(entry.term)) else { continue }
                    let span = TermSpan.reading(term: entry.term, around: heard, in: out) ?? heard
                    if !spans.contains(where: { $0.overlaps(span) }), out[span] != entry.term { spans.append(span) }
                }
                guard !spans.isEmpty else { continue }
                fixes += spans.count
                for span in spans.sorted(by: { $0.lowerBound > $1.lowerBound }) { out.replaceSubrange(span, with: entry.term) }
            }
        }
        return (out, fixes)
    }

    /// Actual alias changes from the same replacement pass used after cleanup.
    public func aliasSwaps(in raw: String) -> [VocabularySwap] {
        VocabularySwaps.diff(from: raw, to: applyDictionary(raw).0, source: .dictionaryAlias)
    }

    private func applySnippets(_ text: String) -> (String, Int) {
        let normalizedWhole = Self.normalize(text)
        // Whole-utterance trigger: replace everything, no surrounding punctuation.
        if let whole = snippets.first(where: { Self.normalize($0.trigger) == normalizedWhole }) {
            return (whole.expansion, 1)
        }
        var out = text
        var used = 0
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let words = snippet.trigger.split(separator: " ").map { Regex.escape(String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = "(?<![\\w])" + words.joined(separator: "[\\s,]+") + "(?![\\w])"
            let count = Regex.matches(out, pattern).count
            if count > 0 {
                out = Regex.replace(out, pattern, with: NSRegularExpression.escapedTemplate(for: snippet.expansion))
                used += count
            }
        }
        return (out, used)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
