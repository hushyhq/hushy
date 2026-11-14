import Foundation
import NaturalLanguage

/// A narrow spelling correction for names after ASR has finished. A phonetic near miss alone
/// never changes speech: the surrounding words must also put it in a name position.
public enum InstalledNameFixer {
    private struct NameShape {
        let text: String
        let words: [String]
        let frontmostOnly: Bool
    }

    public static func fix(_ text: String, settings: PipelineSettings) -> String {
        guard !text.isEmpty else { return text }
        // The person's own Dictionary words count as names too, whether or not the word is an ordinary one ("Codex").
        let installed = FeatureFlags.installedNames ? settings.installedNameTerms().map(\.text) : []
        let own = settings.personalizer.dictionary.map(\.term)
        var seen = Set<String>()
        let frontmostOrdinary = FeatureFlags.installedNames ? settings.installedApps
            .filter { $0.bundleID == settings.frontmostBundleID }.map(\.name) : []
        let frontmostShapes = nameShapes(frontmostOrdinary, allowsOrdinaryWords: true, frontmostOnly: true)
            .filter { InstalledNamePolicy.isOrdinary($0.text) }
        let names = (nameShapes(own, allowsOrdinaryWords: true)
            + nameShapes(installed, allowsOrdinaryWords: false) + frontmostShapes)
            .filter { seen.insert($0.text.lowercased()).inserted }
        guard !names.isEmpty else { return text }
        let matches = Regex.matchesCaseSensitive(text, "[A-Za-z][A-Za-z'’-]*")
        let tokens = matches.compactMap { match -> (word: String, range: Range<String.Index>)? in
            guard let range = Range(match.range, in: text) else { return nil }
            return (String(text[range]), range)
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var changes: [(Range<String.Index>, String)] = []
        var used = Set<Int>()
        for index in tokens.indices {
            guard !used.contains(index) else { continue }
            let heard = tokens[index].word.lowercased()
            let heardIsCommon = LearningLexicon.isCommonWord(heard)
            guard !settings.personalizer.protectsHeardWord(tokens[index].word) else { continue }
            let candidates = names.filter { name in
                let first = name.words[0].lowercased()
                guard heardIsCommon || name.frontmostOnly else { return false }
                // A frontmost ordinary-word app must not steal a lowercase common word
                // ("with male" → "with Mail"). A capitalized name misspelling can still help.
                if name.frontmostOnly && heardIsCommon && tokens[index].word.first?.isUppercase != true {
                    return false
                }
                // "Mews" and "Muse" share a phonetic key but need three character edits.
                // Permit that extra edit only for the frontmost ordinary-name candidate.
                let distanceLimit = name.frontmostOnly ? 3 : 2
                guard first != heard, abs(first.count - heard.count) <= distanceLimit,
                      ContextSpellingFixer.levenshtein(heard, first) <= distanceLimit else { return false }
                let heardSound = ContextSpellingFixer.phoneticKey(heard)
                let nameSound = ContextSpellingFixer.phoneticKey(first)
                return heardSound == nameSound || heardSound + "*" == nameSound || nameSound + "*" == heardSound
            }
            let complete = candidates.filter { name in
                guard index + name.words.count <= tokens.count else { return false }
                for offset in 1..<name.words.count where tokens[index + offset].word.caseInsensitiveCompare(name.words[offset]) != .orderedSame {
                    return false
                }
                for offset in 1..<name.words.count {
                    let gap = text[tokens[index + offset - 1].range.upperBound..<tokens[index + offset].range.lowerBound]
                    guard !gap.isEmpty, gap.allSatisfy(\.isWhitespace) else { return false }
                }
                return true
            }
            guard !complete.isEmpty else { continue }
            let longest = complete.map { $0.words.count }.max() ?? 1
            let best = complete.filter { $0.words.count == longest }
            guard best.count == 1, let name = best.first else { continue }
            let end = index + longest - 1
            let heardPhrase = String(text[tokens[index].range.lowerBound..<tokens[end].range.upperBound])
            guard !settings.keepHeard.blocks(heardKey: VocabularySwap.key(heardPhrase),
                                            writtenKey: VocabularySwap.key(name.text)) else { continue }
            let previous = index > 0 ? tokens[index - 1].word.lowercased() : nil
            let next = end + 1 < tokens.count ? tokens[end + 1].word.lowercased() : nil
            let before = index > 0 ? String(text[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound]) : ""
            let after = end + 1 < tokens.count
                ? String(text[tokens[end].range.upperBound..<tokens[end + 1].range.lowerBound])
                : String(text[tokens[end].range.upperBound...])
            let clauseStart = index == 0 || before.contains(where: { ".!?;".contains($0) })
            let phraseEnd = next == nil || after.contains(where: { ".!?;,".contains($0) })
            let previousInClause = clauseStart || !before.allSatisfy(\.isWhitespace) ? nil : previous
            let nextInPhrase = phraseEnd ? nil : next
            // A determiner makes this a common noun even inside an otherwise plausible phrase.
            if let previousInClause,
               (["the", "a", "an", "our", "your", "my", "their", "its", "his", "her",
                 "this", "that", "these", "those"].contains(previousInClause)
                || previousInClause.hasSuffix("'s") || previousInClause.hasSuffix("’s")) { continue }
            let tailIsObjectBoundary = nextInPhrase == nil || ["to", "about", "for", "and", "but"].contains(nextInPhrase!)
            let addressed = previousInClause.map {
                ["ask", "asks", "asked", "asking", "tell", "tells", "told", "telling"].contains($0)
            } == true && tailIsObjectBoundary
            let direct = previousInClause.map { ["open", "launch", "quit"].contains($0) } == true
                && tailIsObjectBoundary
            let appCue = (previousInClause == "app" || nextInPhrase == "app")
                && (nextInPhrase == "app" || tailIsObjectBoundary || isPredicateVerb(nextInPhrase))
            let frontmost = settings.installedApps.contains {
                $0.name == name.text && $0.bundleID == settings.frontmostBundleID
            } && previousInClause.map { ["in", "with", "using"].contains($0) } == true
                && tailIsObjectBoundary
            let verbFollowedByPluralNoun: Bool = {
                guard end + 2 < tokens.count, isFiniteVerb(nextInPhrase) else { return false }
                let noun = tokens[end + 2]
                let gap = text[tokens[end + 1].range.upperBound..<noun.range.lowerBound]
                return gap.allSatisfy(\.isWhitespace) && isPlural(noun.word)
                    && lexicalClass(at: noun.range.lowerBound, in: tagger) == .noun
            }()
            let subject = clauseStart && isFiniteVerb(nextInPhrase) && !verbFollowedByPluralNoun
            // The complete installed name is a strong cue anywhere, except in a larger noun phrase.
            let precededByAdjective = previousInClause != nil
                && lexicalClass(at: tokens[index - 1].range.lowerBound, in: tagger) == .adjective
            let followedByNoun = nextInPhrase != nil
                && lexicalClass(at: tokens[end + 1].range.lowerBound, in: tagger) == .noun
            let completeName = longest > 1 && !precededByAdjective && !followedByNoun
            guard frontmost || (!name.frontmostOnly && (addressed || direct || appCue || subject || completeName)) else { continue }
            let range = tokens[index].range.lowerBound..<tokens[end].range.upperBound
            changes.append((range, name.text))
            for consumed in index...end { used.insert(consumed) }
        }
        var output = text
        for (range, replacement) in changes.reversed() { output.replaceSubrange(range, with: replacement) }
        return output
    }

    /// A name as the fixer compares it: the whole text and its words. Names whose first word is under four letters,
    /// or that run past four words, are left out, and so are installed app names that are ordinary words.
    private static func nameShapes(_ known: [String], allowsOrdinaryWords: Bool,
                                   frontmostOnly: Bool = false) -> [NameShape] {
        known.compactMap { name -> NameShape? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first, first.count >= 4, words.count <= 4,
                  allowsOrdinaryWords || !InstalledNamePolicy.isOrdinary(trimmed) else { return nil }
            return NameShape(text: trimmed, words: words, frontmostOnly: frontmostOnly)
        }
    }

    private static func isFiniteVerb(_ word: String?) -> Bool {
        guard let word else { return false }
        return subjectVerbs.contains(word)
    }

    private static let subjectVerbs: Set<String> = [
        "say", "says", "said", "saying", "write", "writes", "wrote", "written", "writing",
        "think", "thinks", "thought", "thinking", "suggest", "suggests", "suggested", "suggesting",
        "answer", "answers", "answered", "answering", "reply", "replies", "replied", "replying",
        "respond", "responds", "responded", "responding", "ask", "asks", "asked", "asking",
        "tell", "tells", "told", "telling", "recommend", "recommends", "recommended", "recommending",
        "explain", "explains", "explained", "explaining", "refuse", "refuses", "refused", "refusing",
    ]

    private static func lexicalClass(at index: String.Index, in tagger: NLTagger) -> NLTag? {
        tagger.tag(at: index, unit: .word, scheme: .lexicalClass).0
    }

    private static func isPlural(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.count > 2 && lower.hasSuffix("s") && !lower.hasSuffix("ss")
    }

    private static func isPredicateVerb(_ word: String?) -> Bool {
        isFiniteVerb(word) || ["is", "was", "has", "are", "were"].contains(word)
    }
}
