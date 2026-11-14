import Foundation

/// Where the one-word repair (`FragmentRepair`) must not act: on a number.
///
/// The repair swaps the word before the cue for the word after it, which is right for a name or a
/// day ("send it to Mar I mean Maria") and wrong for a number, because a number is several words.
/// "five hundred dollars no wait five thousand dollars" lost "dollars" and took "five" in its place,
/// "five hundred five thousand dollars", which the number pass then read as $505,000. A number
/// beside the cue is taken back as a whole or not at all, and the rules cannot tell where the
/// retracted phrase begins, so the cue and both numbers are left for the model; the correction
/// bound (`CorrectionBound`) holds its answer to the numbers that were said.
///
/// The swap stays only where it is sound: both words are numbers and neither touches another
/// number word ("set it to six sorry seven"). A number swapped for a word, or a word for a number,
/// is never one slot.
enum FragmentRepairNumbers {
    /// True when swapping `abandoned` for `replacement` would cut a number phrase.
    /// `before` holds up to two words ahead of `abandoned`; `next` is the word after `replacement`.
    static func cutsANumber(abandoned: String, replacement: String, before: String, next: String) -> Bool {
        let gone = key(abandoned)
        let kept = key(replacement)
        let goneIsNumber = NumberPhrase.isNumberWord(gone)
        let keptIsNumber = NumberPhrase.isNumberWord(kept)
        guard goneIsNumber || keptIsNumber else { return false }
        guard goneIsNumber, keptIsNumber else { return true }
        return continuesBackward(before.split(whereSeparator: \.isWhitespace).map { key(String($0)) })
            || NumberPhrase.isNumberWord(key(next))
    }

    /// The words ahead end in a number, or in the "and" / "oh" that joins one ("hundred and", "four oh").
    private static func continuesBackward(_ words: [String]) -> Bool {
        guard let last = words.last else { return false }
        if NumberPhrase.isNumberWord(last) { return true }
        return ["and", "oh"].contains(last) && words.dropLast().last.map(NumberPhrase.isNumberWord) == true
    }

    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.punctuationCharacters))
    }
}
