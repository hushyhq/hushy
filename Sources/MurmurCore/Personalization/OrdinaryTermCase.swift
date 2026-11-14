import Foundation
import NaturalLanguage

/// A Dictionary word that is also ordinary English ("Notion", "Linear", "Next", "Initiative") was written with its
/// capitals everywhere: "I have no Notion of what they want", "let's meet Next week". On the accuracy-v1 harm rows
/// that took key-term exact from 97% to 33% under the Dictionary condition. A change that only adds or removes
/// capitals on such a word is now kept only where the sentence names the product or the person: after a cue word
/// (`productCues`: "in", "on", "open", "ask", "with"…) not followed by a noun ("in linear time" stays), or before "app".
/// Everything else about the Dictionary (a different spelling, a heard alias, a name that is not an English word)
/// is unchanged.
public enum OrdinaryTermCase {
    /// Words before a product ("in Notion", "open Linear") or a person ("ask Rose about it", "with Grace"). Each still
    /// needs the next word not to be a noun ("in linear time", "with rose petals" stay as written). Not "to": "I want
    /// to keynote the event" is a verb.
    static let productCues: Set<String> = [
        "in", "on", "into", "using", "via", "from", "open", "launch",
        "ask", "asked", "tell", "told", "with", "cc", "call", "email", "message", "thanks", "dear", "hi", "hey",
    ]

    /// Is `term` made only of ordinary English words? Then its capitals are a product's, not the word's.
    /// Only plain capitalized spellings ("Notion", "Next Door"): a spelling with inner capitals ("iOS", "GitHub") or
    /// all capitals is the product's own and always applies.
    public static func isOrdinary(_ term: String) -> Bool {
        let spelled = term.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        guard !spelled.isEmpty, spelled.allSatisfy({ $0.allSatisfy(\.isLetter) }),
              spelled.allSatisfy({ $0.dropFirst().allSatisfy(\.isLowercase) }) else { return false }
        return spelled.map { $0.lowercased() }.allSatisfy(LearningLexicon.isCommonWord)
    }

    /// `applied` is `original` after a pass that may have recased ordinary terms. Each word whose only change is its
    /// case, where that word belongs to an ordinary term in `terms`, goes back to `original`'s casing unless a product
    /// cue stands before it. Returns the text and how many words went back.
    public static func restore(original: String, applied: String, terms: [String]) -> (text: String, restored: Int) {
        guard original != applied else { return (applied, 0) }
        let ordinaryWords = Set(terms.filter(isOrdinary).flatMap {
            $0.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        })
        guard !ordinaryWords.isEmpty else { return (applied, 0) }
        let before = tokens(original), after = tokens(applied)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = applied
        var result = applied
        var replacements: [(Range<String.Index>, String)] = []
        for (oldIndex, index) in samePositions(before, after) {
            let old = before[oldIndex].word, new = after[index].word
            guard old != new, old.lowercased() == new.lowercased(), ordinaryWords.contains(new.lowercased()) else { continue }
            if isProductPosition(index: index, tokens: after, in: applied, tagger: tagger) { continue }
            replacements.append((after[index].range, old))
        }
        for (range, word) in replacements.reversed() { result.replaceSubrange(range, with: word) }
        return (result, replacements.count)
    }

    /// The same for the recogniser boost: a case-only change of an ordinary word goes back to what the recogniser
    /// wrote. The Dictionary pass after cleanup recases it where a product cue stands.
    static func keepRecogniserCase(original: String, boosted: String, terms: [String]) -> String {
        let ordinaryWords = Set(terms.filter(isOrdinary).flatMap {
            $0.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        })
        guard !ordinaryWords.isEmpty else { return boosted }
        let before = tokens(original), after = tokens(boosted)
        var result = boosted
        for (oldIndex, index) in samePositions(before, after).reversed() {
            let old = before[oldIndex].word, new = after[index].word
            if old != new, old.lowercased() == new.lowercased(), ordinaryWords.contains(new.lowercased()) {
                result.replaceSubrange(after[index].range, with: old)
            }
        }
        return result
    }

    private static func isProductPosition(
        index: Int, tokens: [(word: String, range: Range<String.Index>)], in text: String, tagger: NLTagger
    ) -> Bool {
        let next = index + 1 < tokens.count ? tokens[index + 1] : nil
        if next?.word.lowercased() == "app" { return true }
        guard index > 0 else { return false }
        let previous = tokens[index - 1]
        let gap = text[previous.range.upperBound..<tokens[index].range.lowerBound]
        guard gap.allSatisfy(\.isWhitespace), productCues.contains(previous.word.lowercased()) else { return false }
        guard let next else { return true }
        let afterGap = text[tokens[index].range.upperBound..<next.range.lowerBound]
        if afterGap.contains(where: { ".,;:!?".contains($0) }) { return true }
        let (tag, _) = tagger.tag(at: next.range.lowerBound, unit: .word, scheme: .lexicalClass)
        return tag != .noun
    }

    /// Pairs of word positions that hold the same word, ignoring case (LCS alignment, `BoostGuard.align`).
    private static func samePositions(
        _ before: [(word: String, range: Range<String.Index>)], _ after: [(word: String, range: Range<String.Index>)]
    ) -> [(Int, Int)] {
        let regions = BoostGuard.align(before.map { $0.word.lowercased() }, after.map { $0.word.lowercased() })
        var pairs: [(Int, Int)] = []
        var oldIndex = 0
        for region in regions {
            switch region {
            case .same(let range):
                for index in range { pairs.append((oldIndex, index)); oldIndex += 1 }
            case .changed(let old, _):
                oldIndex = old.upperBound
            }
        }
        return pairs
    }

    private static func tokens(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        Regex.matchesCaseSensitive(text, "[\\p{L}\\p{N}][\\p{L}\\p{N}'’]*").compactMap { match in
            Range(match.range, in: text).map { (String(text[$0]), $0) }
        }
    }
}
