import Foundation

/// Which words of what was said did cleanup remove? Compares word by word in order (longest
/// common subsequence), so contractions ("don't"), curly vs straight apostrophes and repeated
/// words ("I … I") are matched correctly instead of by a loose set lookup.
public enum WordDiff {
    /// Comparison key for a word: lowercased, curly apostrophes straightened, surrounding
    /// punctuation dropped ("Don’t," → "don't").
    public static func key(_ word: some StringProtocol) -> String {
        word.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'$%")))
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// For each whitespace-separated word of `original`, whether it survives in `cleaned`.
    /// Punctuation-only tokens (e.g. "-") count as kept, and so do words cleanup only joined or
    /// split ("real time" → "real-time", "Git Hub" → "GitHub", "e-mail" → "e mail").
    public static func keptFlags(original: String, cleaned: String) -> [Bool] {
        let a = words(original).map(key)
        let b = words(cleaned).map(key).filter { !$0.isEmpty }
        guard !a.isEmpty else { return [] }
        let (kept, usedInCleaned) = commonWords(a, b)
        return keepingJoins(kept: kept, original: a, cleaned: b, usedInCleaned: usedInCleaned)
    }

    /// Longest common subsequence of two key lists: which original words matched, and which
    /// cleaned words they matched.
    private static func commonWords(_ a: [String], _ b: [String]) -> ([Bool], [Bool]) {
        // LCS table, bounded by dictation length (a few hundred words at most).
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var kept = Array(repeating: false, count: a.count)
        var used = Array(repeating: false, count: b.count)
        var i = 0, j = 0
        while i < a.count {
            if a[i].isEmpty { kept[i] = true; i += 1; continue }
            if j < b.count, a[i] == b[j] {
                kept[i] = true; used[j] = true; i += 1; j += 1
            } else if j < b.count, table[i][j + 1] > table[i + 1][j] {
                j += 1
            } else {
                i += 1
            }
        }
        return (kept, used)
    }

    /// Longest run of words one side may join into a single word on the other.
    private static let maxJoinedWords = 4

    /// A word with its hyphens dropped, so "real-time", "realtime" and "real" + "time" compare equal.
    private static func joinKey(_ keys: ArraySlice<String>) -> String {
        keys.joined().replacingOccurrences(of: "-", with: "")
    }

    /// Marks as kept the unmatched original words that reappear joined or split: a run of
    /// unmatched original words equal to one unmatched cleaned word, or one unmatched original
    /// word equal to a run of unmatched cleaned words. Each cleaned word is used once.
    private static func keepingJoins(kept: [Bool], original a: [String], cleaned b: [String],
                                     usedInCleaned: [Bool]) -> [Bool] {
        var kept = kept
        var used = usedInCleaned
        var i = 0
        while i < a.count {
            guard !kept[i] else { i += 1; continue }
            if let (length, j) = joinedMatch(at: i, a: a, b: b, kept: kept, used: used) {
                for k in i..<(i + length) { kept[k] = true }
                used[j] = true
                i += length
            } else if let (start, length) = splitMatch(of: a[i], b: b, used: used) {
                kept[i] = true
                for k in start..<(start + length) { used[k] = true }
                i += 1
            } else {
                i += 1
            }
        }
        return kept
    }

    /// The longest run of unmatched original words from `i` that equals one unmatched cleaned word.
    private static func joinedMatch(at i: Int, a: [String], b: [String], kept: [Bool],
                                    used: [Bool]) -> (Int, Int)? {
        var end = i
        while end < a.count, !kept[end], end - i < maxJoinedWords { end += 1 }
        guard end - i >= 2 else { return nil }
        for length in stride(from: end - i, through: 2, by: -1) {
            let joined = joinKey(a[i..<(i + length)])
            if let j = b.indices.first(where: { !used[$0] && joinKey(b[$0...$0]) == joined }) {
                return (length, j)
            }
        }
        return nil
    }

    /// A run of consecutive unmatched cleaned words that equals one original word.
    private static func splitMatch(of word: String, b: [String], used: [Bool]) -> (Int, Int)? {
        let target = joinKey([word][...])
        guard !target.isEmpty else { return nil }
        for start in b.indices where !used[start] {
            var end = start
            while end < b.count, !used[end], end - start < maxJoinedWords {
                end += 1
                if end - start >= 2, joinKey(b[start..<end]) == target { return (start, end - start) }
            }
        }
        return nil
    }
}
