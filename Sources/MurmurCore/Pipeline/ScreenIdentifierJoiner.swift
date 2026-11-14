import Foundation

/// Writes an on-screen identifier the way the screen spells it when the recogniser wrote the same characters in other
/// pieces: "RL V9", "rl v nine" or "Rl-v9" become "rl-v9" when "rl-v9" is on screen. The match is exact on letters and
/// digits (spoken digits read as digits), so it never changes a number or guesses at a near miss; the identifier in the
/// draft is then a protected term the cleanup model may not respell (`ProtectedTermGuard`).
///
/// A span that holds an ordinary English word is left alone ("try 95 times" stays when "TRY-95" is on screen), unless
/// the recogniser wrote that word in capitals the way the identifier does ("TRY 95"). The first word of a span may be a
/// spelled letter's name ("our LV9" for "rl-v9", `LetterName`) only when the span also holds a heard token of letters and
/// digits, so an ordinary "our" is never part of one. Cost: words × `maxSpan` × identifiers, each step a prefix check,
/// twice where a word is a letter's name.
public enum ScreenIdentifierJoiner {
    /// The most recogniser words one identifier is matched across ("r l v nine" is four).
    static let maxSpan = 6

    public static func join(_ text: String, terms: [String]) -> String {
        let identifiers = terms.filter { ScreenTermShape.kind(of: $0) == .identifier }
            .map(Identifier.init).filter { !$0.key.isEmpty }
        guard !identifiers.isEmpty, !text.isEmpty else { return text }
        // nil marks a chunk with no letter or digit (a dash, an ellipsis): no identifier is matched across it.
        let words: [Word?] = Regex.matchesCaseSensitive(text, "\\S+").compactMap { match in
            Range(match.range, in: text).map { Word(text: text, range: $0) }
        }
        var replacements: [(Range<String.Index>, String)] = []
        var index = 0
        while index < words.count {
            if let found = match(at: index, words: words, identifiers: identifiers)
                ?? letterNameMatch(at: index, words: words, identifiers: identifiers),
               let first = words[index], let last = words[found.end] {
                let range = first.core.lowerBound..<last.core.upperBound
                if text[range] != found.surface { replacements.append((range, found.surface)) }
                index = found.end + 1
            } else {
                index += 1
            }
        }
        var output = text
        for (range, surface) in replacements.reversed() { output.replaceSubrange(range, with: surface) }
        return output
    }

    private struct Identifier {
        let surface: String
        let key: String
        /// Key offsets where the screen puts a separator between two digits ("2.3" in "v2.3"). A span must break there
        /// too, so "v 23" never becomes "v2.3".
        let digitBreaks: Set<Int>

        init(_ surface: String) {
            self.surface = surface
            var key = "", breaks = Set<Int>(), separated = false
            for char in surface.lowercased() {
                guard (char.isLetter || char.isNumber) && char.isASCII else { separated = true; continue }
                if separated, char.isNumber, key.last?.isNumber == true { breaks.insert(key.count) }
                key.append(char)
                separated = false
            }
            self.key = key
            digitBreaks = breaks
        }
    }

    /// The span read with its first word as a letter's name, unless what follows is an on-screen identifier on its own
    /// ("are LV9 ready" stays when "LV9" is on screen too).
    private static func letterNameMatch(at start: Int, words: [Word?], identifiers: [Identifier]) -> (end: Int, surface: String)? {
        guard let letter = words[start].flatMap({ LetterName.letter(for: $0.lowerCore) }), start + 1 < words.count,
              match(at: start + 1, words: words, identifiers: identifiers) == nil else { return nil }
        return match(at: start, words: words, identifiers: identifiers, openingLetter: letter)
    }

    /// `openingLetter` reads the first word as the letter whose name it sounds like ("our" for R, `LetterName`).
    private static func match(
        at start: Int, words: [Word?], identifiers: [Identifier], openingLetter: String? = nil
    ) -> (end: Int, surface: String)? {
        guard let opening = words[start], !opening.isJoiner else { return nil }
        var key = ""
        var breaks = Set<Int>()
        var pendingTens = false
        for end in start..<min(words.count, start + maxSpan) {
            guard let word = words[end] else { return nil }
            // Punctuation between two words ends the span: "rl. V9" is two things.
            if end > start, words[end - 1]?.hasTrailingPunctuation == true || word.hasLeadingPunctuation { return nil }
            // "one oh seven" is 107: "oh" is a zero only right after a digit.
            let spokenZero = word.lowerCore == "oh" && key.last?.isNumber == true
            let letter = end == start ? openingLetter.map { Piece.text(Identifier($0)) } : nil
            guard let piece = letter ?? (spokenZero ? Piece.unit(0) : word.piece) else { return nil }
            if key.last?.isNumber == true, piece.startsWithDigit { breaks.insert(key.count) }
            switch piece {
            case .joiner:
                pendingTens = false
            case .tens(let value):
                key += String(value)
                pendingTens = true
            case .unit(let value) where pendingTens && value < 10:
                breaks.remove(key.count)
                key = String(key.dropLast()) + String(value)
                pendingTens = false
            case .unit(let value):
                key += String(value)
                pendingTens = false
            case .text(let value):
                breaks.formUnion(value.digitBreaks.map { $0 + key.count })
                key += value.key
                pendingTens = false
            }
            // "ninety" may still become "95": its zero is only provisional.
            let prefixes = pendingTens ? [key, String(key.dropLast())] : [key]
            guard identifiers.contains(where: { identifier in prefixes.contains { identifier.key.hasPrefix($0) } })
            else { return nil }
            guard !word.isJoiner, let identifier = identifiers.first(where: { $0.key == key && $0.digitBreaks.isSubset(of: breaks) })
            else { continue }
            let span = words[start...end].compactMap { $0 }
            // A heard word that is itself code-shaped ("gpt4o" in "gpt4o mini") says the span is the identifier.
            let anchored = span.contains { word in
                word.coreText.contains(where: \.isLetter) && word.coreText.contains(where: \.isNumber)
                    && ScreenTermShape.isIdentifier(word.coreText)
            }
            // A word read as a letter's name needs the anchor: "our LV9" is rl-v9, "our plan" is never anything.
            guard anchored || (openingLetter == nil && span.allSatisfy({ isSafe($0, in: identifier.surface) })) else { return nil }
            return (end, identifier.surface)
        }
        return nil
    }

    /// An ordinary English word in the span may only be part of the identifier when the recogniser wrote it in capitals
    /// and the identifier spells it in capitals too. Digits, number words, spoken joiners, single letters and tokens with
    /// digits or symbols inside are fine. The words "a" and "I" never are: "a 320 gig drive" stays when "A320" is on screen.
    private static func isSafe(_ word: Word, in surface: String) -> Bool {
        let core = word.coreText
        if word.lowerCore == "a" || word.lowerCore == "i" { return false }
        if core.count == 1 || word.isJoiner || word.lowerCore == "oh" || SpokenNumber.value(word.lowerCore) != nil { return true }
        if core.contains(where: { !$0.isLetter }) { return true }
        guard LearningLexicon.isCommonWord(word.lowerCore) else { return true }
        return core.allSatisfy(\.isUppercase) && surface.contains(core)
    }

    private enum Piece {
        case joiner
        case tens(Int)
        case unit(Int)
        /// A written piece keeps its own separators between digits ("2.3").
        case text(Identifier)

        var startsWithDigit: Bool {
            switch self {
            case .joiner: false
            case .tens, .unit: true
            case .text(let value): value.key.first?.isNumber == true
            }
        }
    }

    private struct Word {
        let core: Range<String.Index>
        let coreText: String
        let lowerCore: String
        let hasLeadingPunctuation: Bool
        let hasTrailingPunctuation: Bool

        init?(text: String, range: Range<String.Index>) {
            let chunk = text[range]
            guard let first = chunk.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = chunk.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
            core = first..<chunk.index(after: last)
            coreText = String(text[core])
            lowerCore = coreText.lowercased()
            hasLeadingPunctuation = first != range.lowerBound
            hasTrailingPunctuation = core.upperBound != range.upperBound
        }

        var isJoiner: Bool { SpokenJoiner.words.contains(lowerCore) }

        /// What this word adds to the key: its letters and digits, a spoken number, or nothing for a spoken joiner.
        var piece: Piece? {
            if isJoiner { return .joiner }
            if let number = SpokenNumber.value(lowerCore) { return number >= 20 ? .tens(number) : .unit(number) }
            let value = Identifier(coreText)
            return value.key.isEmpty ? nil : .text(value)
        }
    }

    /// The words the recogniser writes for a spelled letter's name, at the start of a span only: "R L V nine" heard as
    /// "our LV9" (the founder's "Let's release rl-v9", 2026-11-11). A closed class, the names of the letters, not a list
    /// of phrases. Single letters are themselves already; "a" and "I" are left out, as `isSafe` leaves them out.
    enum LetterName {
        static let letters: [String: String] = [
            "are": "r", "our": "r", "ar": "r", "el": "l", "ell": "l", "vee": "v", "bee": "b", "be": "b", "see": "c",
            "sea": "c", "cee": "c", "dee": "d", "eff": "f", "gee": "g", "aitch": "h", "jay": "j", "kay": "k", "em": "m",
            "en": "n", "pea": "p", "pee": "p", "queue": "q", "cue": "q", "ess": "s", "tea": "t", "tee": "t", "you": "u",
            "why": "y", "ex": "x", "zed": "z", "zee": "z",
        ]

        static func letter(for word: String) -> String? { letters[word] }
    }

    private enum SpokenJoiner {
        static let words: Set<String> = ["dash", "hyphen", "underscore", "dot"]
    }

    enum SpokenNumber {
        static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                            "nineteen"]
        static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                           "eighty": 80, "ninety": 90]

        static func value(_ word: String) -> Int? {
            if let unit = units.firstIndex(of: word) { return unit }
            return tens[word]
        }
    }
}
