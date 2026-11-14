import Foundation

/// Vocabulary boosting replaces what the model heard with a dictionary term when the audio
/// supports it — but on real speech it also turned "voice" into "invoice", "buried" into
/// "build" and "privacy" into "Priya". Those originals are ordinary English words the model
/// heard confidently. This guard keeps a boosted replacement only where the original words
/// were not common English (e.g. "Sioban" → "Siobhan"), and reverts it otherwise.
public enum BoostGuard {
    public static func filter(
        original: String, boosted: String, terms: [String], installedTerms: [String] = [], personalTerms: [String] = [],
        isCommonWord: (String) -> Bool
    ) -> String {
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = boosted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard before != after else { return boosted }
        let termKeys = Set(terms.flatMap { $0.split(whereSeparator: \.isWhitespace).map { key(String($0)) } })
        let installedKeys = Set(installedTerms.flatMap { $0.split(whereSeparator: \.isWhitespace).map { key(String($0)) } })
        let personalKeys = Set(personalTerms.flatMap { $0.split(whereSeparator: \.isWhitespace).map { key(String($0)) } })

        var output: [String] = []
        // Words the speaker said that the swapped-in term already contains ("dot com" after "jimmylord.com").
        var alreadyInTerm = 0
        let regions = align(before.map(key), after.map(key))
        for (index, region) in regions.enumerated() {
            switch region {
            case .same(let range):
                output += after[range].dropFirst(alreadyInTerm)
                alreadyInTerm = 0
            case .changed(let old, let new):
                let introducesTerm = after[new].contains { termKeys.contains(key($0)) }
                let heardNumberIsReal = !spellsHeardNumber(
                    heard: before[old], written: after[new], personalKeys: personalKeys)
                let replacedRealWords = !old.isEmpty && before[old].allSatisfy {
                    let word = key($0)
                    return !word.isEmpty && !termKeys.contains(word)
                        && (isCommonWord(word) || (heardNumberIsReal && word.allSatisfy(\.isNumber)))
                }
                let unsupportedInstalledName = after[new].contains { installedKeys.contains(key($0)) }
                    && !InstalledNamePolicy.supportsReplacement(
                        heard: before[old].map(key).joined(), name: after[new].map(key).joined(),
                        previous: old.lowerBound > 0 ? key(before[old.lowerBound - 1]) : nil,
                        next: old.upperBound < before.count ? key(before[old.upperBound]) : nil)
                // Rescoring is a spelling pass: deleting a recognised ordinary word is
                // harmful even when no vocabulary token takes its place ("opens").
                if ((introducesTerm || new.isEmpty) && replacedRealWords) || unsupportedInstalledName {
                    output += before[old]
                } else {
                    output += after[new]
                    // Only when the whole ending sits in the unchanged words right after this replacement.
                    if index + 1 < regions.count, case .same(let next) = regions[index + 1] {
                        let found = wordsTheTermAlreadyHas(introduced: after[new], following: after[next], terms: terms)
                        alreadyInTerm = found <= next.count ? found : 0
                    }
                }
            }
        }
        return output.joined(separator: " ")
    }

    /// A number the recogniser heard is as real as an ordinary word ("try 95" stays when "TRY-95" is on screen), except
    /// where the person's own term writes that same number: their Dictionary entry "node:22-alpine" is what they mean
    /// by "node 22 Alpine". A term with other digits never overwrites a heard number ("try 96 times" stays).
    private static func spellsHeardNumber(
        heard: ArraySlice<String>, written: ArraySlice<String>, personalKeys: Set<String>
    ) -> Bool {
        guard written.contains(where: { personalKeys.contains(key($0)) }) else { return false }
        let digits = { (words: ArraySlice<String>) in words.map(key).joined().filter(\.isNumber) }
        return digits(heard) == digits(written)
    }

    /// How many of the words after a replacement say the ending of the term that was swapped in. Swapping "jimmy lord" for
    /// "jimmylord.com" leaves the spoken "dot com" behind it, which would write the ending twice (see `TermSpan`).
    private static func wordsTheTermAlreadyHas(
        introduced: ArraySlice<String>, following: ArraySlice<String>, terms: [String]
    ) -> Int {
        let introducedKey = introduced.map(key).joined()
        guard let term = terms.first(where: { !$0.isEmpty && key($0) == introducedKey }) else { return 0 }
        return TermSpan.wordsSayingTheEnding(of: term, in: Array(following))
    }

    /// Lowercased English word list from the system dictionary (empty if unavailable, in
    /// which case the guard lets every boost through, i.e. behaves as before).
    public static let systemWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }()

    /// The system list has base forms only ("invite", "voice"), so also accept common
    /// inflections: voices, invited, inviting, buries, quickly.
    public static func isEnglishWord(_ word: String, in words: Set<String>) -> Bool {
        if words.contains(word) { return true }
        let suffixes: [(String, [String])] = [
            ("ies", ["y"]), ("ied", ["y"]), ("es", ["", "e"]), ("s", [""]), ("ed", ["", "e"]),
            ("d", [""]), ("ing", ["", "e"]), ("ly", [""]), ("'s", [""]),
        ]
        for (suffix, replacements) in suffixes where word.hasSuffix(suffix) && word.count > suffix.count + 2 {
            let stem = String(word.dropLast(suffix.count))
            if replacements.contains(where: { words.contains(stem + $0) }) { return true }
            // Doubled consonant: "stopped" → "stop".
            if suffix == "ed" || suffix == "ing", let last = stem.last, stem.dropLast().last == last,
               words.contains(String(stem.dropLast())) { return true }
        }
        return false
    }

    static func key(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    enum Region: Equatable {
        case same(Range<Int>)
        case changed(old: Range<Int>, new: Range<Int>)
    }

    /// Longest-common-subsequence alignment of two token lists into equal and changed runs.
    static func align(_ a: [String], _ b: [String]) -> [Region] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var regions: [Region] = []
        var i = 0, j = 0, oldStart = 0, newStart = 0
        func flushChange() {
            if oldStart < i || newStart < j { regions.append(.changed(old: oldStart..<i, new: newStart..<j)) }
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flushChange()
                let start = j
                while i < a.count, j < b.count, a[i] == b[j] { i += 1; j += 1 }
                regions.append(.same(start..<j))
                oldStart = i; newStart = j
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                j += 1
            } else {
                i += 1
            }
        }
        flushChange()
        return regions
    }
}
