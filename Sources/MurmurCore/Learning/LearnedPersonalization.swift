import Foundation

/// Turns learned items into the inputs the existing pipeline already understands: Dictionary
/// entries (ASR boosting via `VocabularyContext`, replacements via `Personalizer`, protection
/// via `ProtectedTermGuard`) and per-app preference hints.
public enum LearnedPersonalization {
    /// Active learned terms as Dictionary entries. `appBundleID` nil means the terms that apply everywhere; an app means
    /// the terms that apply only in some apps and that this app is one of (`LearnedItem.scope`). Every misrecognition the person corrected
    /// becomes a replacement alias (`soundsLike`), even when it is made only of ordinary
    /// English words ("mark it" → "Markit"): the person said "this was wrong, this is right",
    /// and an item only gets here once they confirmed it or repeated the fix. `BoostGuard`
    /// still keeps an *untaught* Dictionary term from swallowing an ordinary word in the
    /// recogniser, and forgetting the item takes the alias away again.
    public static func dictionaryEntries(
        from items: [LearnedItem], excluding userTerms: [DictionaryEntry] = [], appBundleID: String? = nil
    ) -> [DictionaryEntry] {
        let taken = Set(userTerms.map { $0.term.lowercased() })
        return items
            .filter { $0.kind == .term && $0.status == .active && $0.isUsed(inApp: appBundleID) && !taken.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { item in
                DictionaryEntry(
                    term: item.value, soundsLike: heardAliases(item.heardAs, term: item.value),
                    createdAt: item.activatedAt ?? item.createdAt)
            }
    }

    /// The taught "heard as" phrases that make sense as a replacement: not blank, not just the
    /// term again.
    static func heardAliases(_ heard: [String], term: String) -> [String] {
        heard.filter { variant in
            let hasWords = CorrectionAlignment.tokens(variant).map(CorrectionAlignment.key).contains { !$0.isEmpty }
            return hasWords && variant.lowercased() != term.lowercased()
        }
    }

    /// The Personalizer the pipeline should use. The user's own entries come first and win on
    /// conflicts. What was learned about a term the user already has is merged into a *copy* of
    /// that entry at use time (their stored entry is never rewritten): their own "sounds like"
    /// phrases stay first, learned phrases follow, and a phrase another of their entries
    /// already claims stays with that entry. Learned terms the user does not have follow.
    public static func personalizer(
        dictionary: [DictionaryEntry], snippets: [Snippet], learned: [LearnedItem]
    ) -> Personalizer {
        Personalizer(
            dictionary: mergedUserEntries(dictionary, learned: learned) + dictionaryEntries(from: learned, excluding: dictionary),
            snippets: snippets, scopedTerms: learned.filter { $0.kind == .term && !$0.isGlobal })
    }

    private static func mergedUserEntries(_ dictionary: [DictionaryEntry], learned: [LearnedItem]) -> [DictionaryEntry] {
        let taught = Dictionary(
            learned.filter { $0.kind == .term && $0.status == .active && $0.isGlobal }
                .map { ($0.key, heardAliases($0.heardAs, term: $0.value)) },
            uniquingKeysWith: { first, _ in first })
        guard taught.values.contains(where: { !$0.isEmpty }) else { return dictionary }
        return dictionary.enumerated().map { index, entry in
            var claimed = Set<String>()
            for (otherIndex, other) in dictionary.enumerated() where otherIndex != index {
                claimed.insert(Learner.listedKey(other.term))
                claimed.formUnion(other.soundsLike.map(Learner.listedKey))
            }
            var phrases = entry.soundsLike
            var seen = Set(phrases.map(Learner.listedKey) + [Learner.listedKey(entry.term)])
            for phrase in taught[entry.term.lowercased()] ?? []
            where !claimed.contains(Learner.listedKey(phrase)) && seen.insert(Learner.listedKey(phrase)).inserted {
                phrases.append(phrase)
            }
            guard phrases != entry.soundsLike else { return entry }
            var merged = entry
            merged.soundsLike = phrases
            return merged
        }
    }

    /// Items the UI should announce now ("Learned from your edits: Priya, Kubernetes · Undo").
    public static func unannounced(_ items: [LearnedItem]) -> [LearnedItem] {
        items.filter { $0.status == .active && !$0.announced && $0.kind == .term }
            .sorted { ($0.activatedAt ?? $0.lastSeenAt) < ($1.activatedAt ?? $1.lastSeenAt) }
    }

    /// Terms awaiting the user's yes ("Add Kubernetes?"): ready suggestions (enough fixes to
    /// have activated if auto-activation were on) first, then newest.
    public static func suggestions(_ items: [LearnedItem]) -> [LearnedItem] {
        items.filter { $0.kind == .term && $0.status == .candidate }
            .sorted { lhs, rhs in
                lhs.isReadySuggestion != rhs.isReadySuggestion ? lhs.isReadySuggestion : lhs.lastSeenAt > rhs.lastSeenAt
            }
    }
}

/// What the user's edits say about how they like text in one app. Deterministic, local,
/// derived only from explicitly confirmed active style signals and used by the cleanup person block.
public struct PreferenceHints: Sendable, Equatable {
    /// The user keeps lowercasing what Hushy capitalizes here.
    public let prefersLowercase: Bool
    /// The user keeps removing the terminal period here.
    public let dropsTerminalPeriod: Bool
    public var noGreeting: Bool = false
    public var noExclamation: Bool = false
    public var commaSignOff: Bool = false
    /// Words cleanup removed that the user keeps typing back ("actually").
    public let keepWords: [String]
    /// Fillers cleanup left that the user keeps deleting ("like").
    public let dropWords: [String]

    public static let none = PreferenceHints(prefersLowercase: false, dropsTerminalPeriod: false, keepWords: [], dropWords: [])

    public var isEmpty: Bool { self == .none }

    /// A short per-app instruction, used when the person has no explicit app note.
    public var promptLine: String? {
        var parts: [String] = []
        if noGreeting { parts.append("No greeting") }
        if noExclamation { parts.append("no exclamation marks") }
        if prefersLowercase { parts.append("lowercase") }
        if dropsTerminalPeriod { parts.append("no final period") }
        if commaSignOff { parts.append("comma after thanks") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + "."
    }

    /// Detailed plain-language descriptions retained for callers that display each habit.
    public var promptLines: [String] {
        var lines: [String] = []
        if prefersLowercase { lines.append("The user writes in lowercase in this app; do not add capitals.") }
        if dropsTerminalPeriod { lines.append("The user leaves off the final period in this app.") }
        if !keepWords.isEmpty { lines.append("Keep these words when the user says them: \(keepWords.joined(separator: ", ")).") }
        if !dropWords.isEmpty { lines.append("Remove these fillers: \(dropWords.joined(separator: ", ")).") }
        return lines
    }

    /// Hints for `bundleID` from active style signals the person explicitly accepted.
    public static func from(_ items: [LearnedItem], bundleID: String?) -> PreferenceHints {
        guard let bundleID else { return .none }
        let keys = Set(items.filter { $0.kind == .styleSignal && $0.status == .active && $0.confirmed && $0.appBundleID == bundleID }.map(\.key))
        func words(_ prefix: String) -> [String] {
            keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
        }
        var hints = PreferenceHints(
            prefersLowercase: keys.contains("format:\(FormattingSignal.lowercased.rawValue)"),
            dropsTerminalPeriod: keys.contains("format:\(FormattingSignal.droppedTerminalPeriod.rawValue)"),
            keepWords: words("keep:"), dropWords: words("drop:"))
        hints.commaSignOff = keys.contains("format:signOff:,")
        hints.noGreeting = keys.contains("format:noGreeting")
        hints.noExclamation = keys.contains("format:noExclamation")
        return hints
    }
}
