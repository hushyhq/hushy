import Foundation
import MurmurCore

/// Pure scoring for `murmur-eval vocab-real-boost`: no audio, no recogniser, so every rule is unit-tested.
///
/// Three texts are scored per row: what the recogniser heard, what the CTC boost made of it, and what is left
/// after `BoostGuard` (the text the app goes on with).
///   - Harm rows: the spoken sentence is the reference. A word is "made worse" when it matched the reference
///     before a step and no longer does after it (`MadeWorseScorer`), measured at the boost step
///     (recogniser -> boosted) and after the guard (recogniser -> guarded).
///   - Win rows: each expected spelling must appear, case-sensitively, as a whole word (or word run).
enum VocabRealBoostScoring {
    /// One region the boost (or the guard) rewrote, with the vocabulary term that explains it.
    struct Change: Codable, Equatable, Sendable {
        let old: String
        let new: String
        /// The vocabulary term (or alias owner) whose words appear in the new side; nil when none does.
        let term: String?
        /// The source label, or "deletion" / "unexplained" when there is no term.
        let source: String
    }

    struct HarmResult: Codable, Equatable, Sendable {
        let id: String
        let vocab: String
        let spoken: String
        let recogniser: String
        let boosted: String
        let guarded: String
        let worseAtBoost: Int
        let worseAfterGuard: Int
        let changesAtBoost: [Change]
        let changesAfterGuard: [Change]
    }

    struct HarmSummary: Codable, Equatable, Sendable {
        var rows = 0
        var rowsWorseAtBoost = 0
        var rowsWorseAfterGuard = 0
        var wordsWorseAtBoost = 0
        var wordsWorseAfterGuard = 0
        /// Rows made worse after the guard, counted once per source that explains a change in the row.
        var rowsWorseAfterGuardBySource: [String: Int] = [:]
        var rowsWorseAtBoostBySource: [String: Int] = [:]
    }

    struct WinResult: Codable, Equatable, Sendable {
        let id: String
        let vocab: String
        let spoken: String
        let expect: [String]
        let recogniser: String
        let boosted: String
        let guarded: String
        let foundInRecogniser: Int
        let foundAfterBoost: Int
        let foundAfterGuard: Int
    }

    struct WinSummary: Codable, Equatable, Sendable {
        var rows = 0
        var terms = 0
        var foundInRecogniser = 0
        var foundAfterBoost = 0
        var foundAfterGuard = 0
        /// Expected spellings the recogniser had right and the guarded text lost.
        var lostByBoost = 0
        /// Expected spellings the recogniser missed and the guarded text has.
        var gainedByBoost = 0

        func recall(_ found: Int) -> Double { terms == 0 ? 0 : Double(found) / Double(terms) }
    }

    // MARK: Harm

    static func scoreHarm(
        row: HarmRow, recogniser: String, boosted: String, guarded: String, vocabulary: SourcedVocabulary
    ) -> HarmResult {
        let atBoost = MadeWorseScorer.transition(reference: row.text, before: recogniser, after: boosted)
        let afterGuard = MadeWorseScorer.transition(reference: row.text, before: recogniser, after: guarded)
        return HarmResult(
            id: row.id, vocab: row.vocab, spoken: row.text, recogniser: recogniser, boosted: boosted, guarded: guarded,
            worseAtBoost: atBoost.worse, worseAfterGuard: afterGuard.worse,
            changesAtBoost: atBoost.worse > 0 ? changes(from: recogniser, to: boosted, vocabulary: vocabulary) : [],
            changesAfterGuard: afterGuard.worse > 0 ? changes(from: recogniser, to: guarded, vocabulary: vocabulary) : [])
    }

    static func summarise(harm results: [HarmResult]) -> HarmSummary {
        var summary = HarmSummary()
        for result in results {
            summary.rows += 1
            summary.wordsWorseAtBoost += result.worseAtBoost
            summary.wordsWorseAfterGuard += result.worseAfterGuard
            if result.worseAtBoost > 0 {
                summary.rowsWorseAtBoost += 1
                for source in Set(result.changesAtBoost.map(\.source)) { summary.rowsWorseAtBoostBySource[source, default: 0] += 1 }
            }
            if result.worseAfterGuard > 0 {
                summary.rowsWorseAfterGuard += 1
                for source in Set(result.changesAfterGuard.map(\.source)) { summary.rowsWorseAfterGuardBySource[source, default: 0] += 1 }
            }
        }
        return summary
    }

    /// The worst rows first: most words lost after the guard, then at the boost step, then by id for a stable list.
    static func worst(_ results: [HarmResult], limit: Int) -> [HarmResult] {
        results.filter { $0.worseAfterGuard > 0 || $0.worseAtBoost > 0 }
            .sorted { lhs, rhs in
                if lhs.worseAfterGuard != rhs.worseAfterGuard { return lhs.worseAfterGuard > rhs.worseAfterGuard }
                if lhs.worseAtBoost != rhs.worseAtBoost { return lhs.worseAtBoost > rhs.worseAtBoost }
                return lhs.id < rhs.id
            }
            .prefix(limit).map { $0 }
    }

    // MARK: Win

    static func scoreWin(
        row: WinRow, recogniser: String, boosted: String, guarded: String
    ) -> WinResult {
        func found(_ text: String) -> Int { row.expect.filter { containsTerm(text, term: $0) }.count }
        return WinResult(
            id: row.id, vocab: row.vocab, spoken: row.text, expect: row.expect, recogniser: recogniser,
            boosted: boosted, guarded: guarded, foundInRecogniser: found(recogniser), foundAfterBoost: found(boosted),
            foundAfterGuard: found(guarded))
    }

    static func summarise(win results: [WinResult]) -> WinSummary {
        var summary = WinSummary()
        for result in results {
            summary.rows += 1
            summary.terms += result.expect.count
            summary.foundInRecogniser += result.foundInRecogniser
            summary.foundAfterBoost += result.foundAfterBoost
            summary.foundAfterGuard += result.foundAfterGuard
            for term in result.expect {
                let before = containsTerm(result.recogniser, term: term)
                let after = containsTerm(result.guarded, term: term)
                if before && !after { summary.lostByBoost += 1 }
                if !before && after { summary.gainedByBoost += 1 }
            }
        }
        return summary
    }

    /// True when `term` appears in `text` as a whole word (or run of words), with the same capitals.
    static func containsTerm(_ text: String, term: String) -> Bool {
        let haystack = tokens(text), needle = tokens(term)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    // MARK: Attribution

    /// Regions where `to` differs from `from` (case and edge punctuation ignored), each explained by the
    /// vocabulary term whose spelling the new words make up, if any.
    static func changes(from: String, to: String, vocabulary: SourcedVocabulary) -> [Change] {
        regions(from: lowerTokens(from), to: lowerTokens(to)).map { region in
            let explained = explain(newWords: region.new, vocabulary: vocabulary)
            let source = explained?.source.rawValue ?? (region.new.isEmpty ? "deletion" : "unexplained")
            return Change(old: region.old.joined(separator: " "), new: region.new.joined(separator: " "),
                          term: explained?.term, source: source)
        }
    }

    private static func explain(newWords: [String], vocabulary: SourcedVocabulary) -> (term: String, source: VocabSource)? {
        guard !newWords.isEmpty else { return nil }
        let joined = newWords.joined()
        var partial: (term: String, source: VocabSource)?
        for term in vocabulary.context.terms {
            let source = vocabulary.sources[term.text.lowercased()] ?? .screen
            let termWords = lowerTokens(term.text)
            if termWords == newWords || termWords.joined() == joined { return (term.text, source) }
            for alias in term.aliases {
                let aliasWords = lowerTokens(alias)
                if aliasWords == newWords || aliasWords.joined() == joined { return (term.text, source) }
            }
            if partial == nil, newWords.contains(where: { termWords.contains($0) }) { partial = (term.text, source) }
        }
        return partial
    }

    struct Region: Equatable { let old: [String]; let new: [String] }

    /// Word-level longest-common-subsequence alignment; every maximal run of differing words is a region.
    static func regions(from old: [String], to new: [String]) -> [Region] {
        let n = old.count, m = new.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Region] = []
        var pendingOld: [String] = [], pendingNew: [String] = []
        func flush() {
            if !pendingOld.isEmpty || !pendingNew.isEmpty { result.append(Region(old: pendingOld, new: pendingNew)) }
            pendingOld = []; pendingNew = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                flush(); i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                pendingNew.append(new[j]); j += 1
            } else {
                pendingOld.append(old[i]); i += 1
            }
        }
        flush()
        return result
    }

    // MARK: Tokens

    /// Whitespace words with edge punctuation removed; inner dots and hyphens stay ("tryhushy.com").
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let word = String(raw).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return word.isEmpty ? nil : word
        }
    }

    static func lowerTokens(_ text: String) -> [String] { tokens(text.lowercased()) }
}
