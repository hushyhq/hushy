import Foundation
import NaturalLanguage

/// When the one-word repair (`FragmentRepair`) may swap a word for the one after its cue.
///
/// The swap takes the word before the cue out and keeps the word after it. "I mean" is often a
/// filler, so it swaps only closed-class values or two names. A word cut off as a strict prefix
/// of its replacement also swaps with any cue. Other cues retain the like-for-like
/// rule. A replacement repeating a word just before the first is a restarted frame
/// ("doctor okafor no wait doctor okoye"), not a swap.
///
/// A word's kind is a day, month or number by its spelling, else its class from the system tagger.
/// The word is tagged on its own
/// with a capital, because the ASR gives names in lower case and the tagger reads a lower-case "dana" as a verb.
/// A noun, an adjective or a name counts; a verb, adverb, pronoun, particle or interjection does not.
enum FragmentRepairKinds {
    /// True when `replacement` may stand for `abandoned`. `before` holds up to two words ahead of `abandoned`.
    static func areAlike(abandoned: String, replacement: String, before: String, cue: String) -> Bool {
        let gone = key(abandoned)
        let kept = key(replacement)
        guard !gone.isEmpty, !kept.isEmpty else { return false }
        if gone.count >= 2, kept.count > gone.count, kept.hasPrefix(gone) { return true }
        let restartsTheFrame = before.split(whereSeparator: \.isWhitespace).contains { key(String($0)) == kept }
        guard !restartsTheFrame else { return false }
        if cue == "i mean" || cue.hasSuffix(" i mean") {
            return isClosedClassValue(gone) && isClosedClassValue(kept)
                || isNamedEntity(gone) && isNamedEntity(kept)
        }
        return namesAValue(gone) && namesAValue(kept)
    }

    private static func isClosedClassValue(_ word: String) -> Bool {
        if NumberPhrase.isNumberWord(word) { return true }
        switch Token(text: word).kind {
        case .number, .weekday, .month: return true
        default: return false
        }
    }

    private static func namesAValue(_ word: String) -> Bool {
        if NumberPhrase.isNumberWord(word) { return true }
        if let kind = Token(text: word).kind, kind != .word { return true }
        return isNounLike(word)
    }

    private static func isNounLike(_ word: String) -> Bool {
        let text = word.capitalized
        let range = text.startIndex..<text.endIndex
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        tagger.setLanguage(.english, range: range)
        if isNamedEntity(tagger, in: text) { return true }
        let tag = tagger.tag(at: text.startIndex, unit: .word, scheme: .lexicalClass).0
        return tag == .noun || tag == .adjective
    }

    private static func isNamedEntity(_ word: String) -> Bool {
        let text = word.capitalized
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        return isNamedEntity(tagger, in: text)
    }

    private static func isNamedEntity(_ tagger: NLTagger, in text: String) -> Bool {
        let names: Set<NLTag> = [.personalName, .placeName, .organizationName]
        return tagger.tag(at: text.startIndex, unit: .word, scheme: .nameType).0.map(names.contains) ?? false
    }

    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.punctuationCharacters))
    }
}
