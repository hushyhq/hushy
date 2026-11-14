import Foundation

/// A wider read of on-screen text for window context (`WindowContextReader`). Pulls rare lowercase
/// coinages and dotted names the field-only extractor misses, ranked newest-first within the cap.
extension ContextExtractor {
    /// How much of the screen text the window reader passes in (matches `WindowTextReader.Budget`).
    public static let widenedWindowLength = 4_000
    /// The most terms returned for one dictation's boost and fixer lists.
    public static let widenedMaxTerms = 40
    static let widenedMinLength = 3
    static let widenedMaxLength = 32

    /// Everything `extract` finds in the last `widenedWindowLength` characters, plus every rare word
    /// (not `LearningLexicon.isCommonWord`), ranked with the nearest text first.
    public static func extractWidened(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let windowed = String(text.suffix(widenedWindowLength))
        var terms = extract(from: windowed, window: widenedWindowLength, limit: .max)
        var keys = Set(terms.map { $0.lowercased() })
        for token in Regex.matchesCaseSensitive(windowed, "(?<![\\p{L}\\p{N}])\\p{L}[\\p{L}\\p{N}]*(?:[.'’-][\\p{L}\\p{N}]+)*") {
            guard let word = token.string(at: 0, in: windowed), isWidenedCandidate(word) else { continue }
            if keys.insert(word.lowercased()).inserted { terms.append(word) }
        }
        let ranked = rankByRecency(terms, in: windowed).prefix(widenedMaxTerms).map(\.self)
        return ScreenBoostPolicy.filter(ranked).terms
    }

    static func rankByRecency(_ terms: [String], in windowed: String) -> [String] {
        terms.enumerated().map { index, term -> (term: String, at: Int, index: Int) in
            let found = windowed.range(of: term, options: [.backwards, .caseInsensitive])
            return (term, found.map { windowed.distance(from: windowed.startIndex, to: $0.lowerBound) } ?? -1, index)
        }
        .sorted { ($0.at, -$0.index) > ($1.at, -$1.index) }
        .map(\.term)
    }

    static func isWidenedCandidate(_ word: String) -> Bool {
        guard word.count >= widenedMinLength, word.count <= widenedMaxLength else { return false }
        let key = word.lowercased()
        if commonWordDenylist.contains(key) { return false }
        if word.contains(".") {
            let parts = word.split(separator: ".")
            return parts.count >= 2 && parts.allSatisfy { $0.count >= 2 } && word.contains { $0.isLetter }
        }
        let parts = key.split(whereSeparator: { "'’-".contains($0) }).map(String.init)
        if parts.count > 1 { return parts.contains { $0.count >= 2 && !LearningLexicon.isCommonWord($0) } }
        return !LearningLexicon.isCommonWord(key)
    }
}
