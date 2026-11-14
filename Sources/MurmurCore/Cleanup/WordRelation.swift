import Foundation

/// Whether two spellings are the same spoken word or two different words. Used by
/// `SpokenWordFidelity` to tell a model that fixed, formatted or inflected a word from one that
/// replaced it. The test is about the shape of the two spellings only; it holds no word lists
/// beyond the system dictionary the rest of the cleanup guards already use.
///
/// Same word: identical letters (case, hyphens, apostrophes and spaces aside), a regular
/// inflection (report/reports, ship/shipped, make/making), or a misspelling a few edits away.
/// Different word: one spelling is a proper prefix of the other (priya/priyanka,
/// postgres/postgresql, repo/repository), one contains the other (book/notebook), or the speaker's
/// word is not in the dictionary and the answer's word is unrelated to it.
enum WordRelation {
    private static let inflections: Set<String> = ["s", "es", "ed", "d", "ing", "er", "ers", "ly", "est"]
    private static let doubledInflections: Set<String> = ["ed", "ing", "er", "ers"]
    private static let silentEInflections: Set<String> = ["ing", "er", "ers"]
    private static let yInflections: Set<String> = ["ies", "ied", "ier", "iest", "ily"]

    /// Letters and digits only, lower case: "E-mail" and "e mail" both collapse to "email".
    static func collapsed(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// True when `answer` is a different word from `draft`, in a way no formatting, inflection or
    /// spelling repair explains. `knownWords` empty (no system dictionary) disables only the
    /// "unrelated word" rule, since without a dictionary a garble cannot be told from a name.
    static func isDifferent(draft: String, answer: String, knownWords: Set<String>) -> Bool {
        let spoken = collapsed(draft), written = collapsed(answer)
        guard !spoken.isEmpty, !written.isEmpty, spoken != written else { return false }
        if isInflection(spoken, written) { return false }
        let (shorter, longer) = spoken.count <= written.count ? (spoken, written) : (written, spoken)
        if shorter.count >= 3, longer.hasPrefix(shorter) { return !isDoubledLetterTypo(shorter, longer) }
        if shorter.count >= 4, longer.contains(shorter) { return true }
        let distance = editDistance(spoken, written)
        let isKnown = { (word: String) in BoostGuard.isEnglishWord(word, in: knownWords) }
        if shorter.count >= 4, distance <= nearSpellingBound(longer.count) { return false }
        if shorter.count < 4, distance <= 1, isKnown(written), !isKnown(spoken) { return false }
        return !knownWords.isEmpty && spoken.count >= 3 && !isKnown(spoken)
    }

    /// The most edits that still read as a misspelling or near re-hearing of a word `length` letters long.
    private static func nearSpellingBound(_ length: Int) -> Int { max(1, length / 4) }

    /// True when the two spellings are the same word, an inflection of it, or a misspelling a few edits away, by shape
    /// alone and in both directions (no dictionary). A spelling that only extends the other ("priya", "priyanka") or
    /// contains it is a different word. Unlike `isDifferent`, a dictionary word swapped for an unrelated word is not near.
    static func isNearSpelling(_ x: String, _ y: String) -> Bool {
        let spoken = collapsed(x), written = collapsed(y)
        guard !spoken.isEmpty, !written.isEmpty else { return false }
        if spoken == written || isInflection(spoken, written) { return true }
        let (shorter, longer) = spoken.count <= written.count ? (spoken, written) : (written, spoken)
        guard shorter.count >= 4, !longer.hasPrefix(shorter), !longer.contains(shorter) else { return false }
        return editDistance(spoken, written) <= nearSpellingBound(longer.count)
    }

    /// The shape-only relation used when a word has moved across alignment regions.
    static func isStrongRelation(draft: String, answer: String) -> Bool {
        let spoken = collapsed(draft), written = collapsed(answer)
        guard spoken != written, !isInflection(spoken, written) else { return false }
        let (shorter, longer) = spoken.count <= written.count ? (spoken, written) : (written, spoken)
        if shorter.count >= 3, longer.hasPrefix(shorter) { return !isDoubledLetterTypo(shorter, longer) }
        return shorter.count >= 4 && longer.contains(shorter)
    }

    /// Regular English endings: s, es, ed, ing, er, ly; a doubled final consonant (ship/shipped);
    /// a dropped silent e (make/making); y to ies (study/studies).
    static func isInflection(_ x: String, _ y: String) -> Bool {
        let (stem, other) = x.count <= y.count ? (x, y) : (y, x)
        guard stem.count >= 2, other.hasPrefix(stem.dropLast()) else { return false }
        if other.hasPrefix(stem), inflections.contains(String(other.dropFirst(stem.count))) { return true }
        if let last = stem.last, other.hasPrefix(stem + String(last)),
           doubledInflections.contains(String(other.dropFirst(stem.count + 1))) { return true }
        let rest = String(other.dropFirst(stem.count - 1))
        if stem.hasSuffix("e") { return silentEInflections.contains(rest) }
        return stem.hasSuffix("y") && yInflections.contains(rest)
    }

    /// "postgress" for "postgres": a doubled last letter is a typo, not a longer word.
    private static func isDoubledLetterTypo(_ shorter: String, _ longer: String) -> Bool {
        longer.count == shorter.count + 1 && longer.last == shorter.last
    }

    /// Optimal-string-alignment distance: insert, delete, substitute or swap two neighbours.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var rows = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { rows[i][0] = i }
        for j in 0...y.count { rows[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                rows[i][j] = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    rows[i][j] = min(rows[i][j], rows[i - 2][j - 2] + 1)
                }
            }
        }
        return rows[x.count][y.count]
    }
}
