import Foundation

/// Fuzzy-matches a spoken Shortcut name against the list of actually-installed Shortcuts
/// (voice-actions.md §4.2: "Shortcut not found by name" should list the closest matches rather
/// than silently failing). Deliberately simple (case-insensitive containment + word overlap,
/// no external dependency) since the candidate set is small (a user's own Shortcuts library).
public enum ShortcutMatcher {
    /// Returns `available` sorted by similarity to `spoken`, best first. An exact
    /// (case-insensitive) match is always first when present.
    public static func rank(spoken: String, available: [String]) -> [String] {
        let spokenLower = spoken.lowercased()
        guard !spokenLower.isEmpty, !available.isEmpty else { return [] }
        let spokenWords = Set(words(spokenLower))
        return available
            .map { candidate -> (name: String, score: Double) in
                let candidateLower = candidate.lowercased()
                if candidateLower == spokenLower { return (candidate, 1.0) }
                let candidateWords = Set(words(candidateLower))
                let overlap = spokenWords.intersection(candidateWords).count
                let union = max(spokenWords.union(candidateWords).count, 1)
                var score = Double(overlap) / Double(union)
                if candidateLower.contains(spokenLower) || spokenLower.contains(candidateLower) {
                    score = max(score, 0.6)
                }
                return (candidate, score)
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.name)
    }

    /// The single best match, or nil when nothing scores above a confident threshold — callers
    /// should fall back to showing `rank`'s full list for the user to pick from rather than
    /// silently running a low-confidence guess.
    public static func bestMatch(spoken: String, available: [String], threshold: Double = 0.99) -> String? {
        if available.contains(where: { $0.caseInsensitiveCompare(spoken) == .orderedSame }) {
            return available.first { $0.caseInsensitiveCompare(spoken) == .orderedSame }
        }
        return nil
    }

    /// The installed Shortcut the speaker named, or nil. Never a free-form name: the spoken
    /// name must equal an installed one once case, punctuation and filler words ("my", "the",
    /// "shortcut", "called") are ignored — word order may differ only when that leaves exactly
    /// one candidate. A near miss returns nil so the caller can refuse with `rank` suggestions.
    public static func installedName(spoken: String, available: [String]) -> String? {
        let wanted = significantWords(spoken)
        guard !wanted.isEmpty else { return nil }
        if let exact = available.first(where: { significantWords($0) == wanted }) { return exact }
        let reordered = available.filter { significantWords($0).sorted() == wanted.sorted() }
        return reordered.count == 1 ? reordered.first : nil
    }

    private static let fillerWords: Set<String> = ["my", "the", "a", "an", "shortcut", "shortcuts", "called", "named", "run", "please"]

    private static func significantWords(_ text: String) -> [String] {
        words(text.lowercased()).filter { !fillerWords.contains($0) }
    }

    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
