import Foundation
import os

enum Whitespace {
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Regex {
    /// Case-insensitive replacement helper; `template` may use `$1` style references.
    static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: true) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func firstMatch(_ text: String, _ pattern: String) -> NSTextCheckingResult? {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: true) else {
            return nil
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func matches(_ text: String, _ pattern: String) -> [NSTextCheckingResult] {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: true) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Case-sensitive variant of `matches`, for patterns (camelCase/snake_case identifiers,
    /// sentence-initial capitalization) where case is the signal being matched, not incidental.
    static func matchesCaseSensitive(_ text: String, _ pattern: String) -> [NSTextCheckingResult] {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: false) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func escape(_ literal: String) -> String {
        NSRegularExpression.escapedPattern(for: literal)
    }

    /// Replaces every match with the result of `transform(wholeMatch, captureGroups)`, where
    /// `captureGroups[0]` is the whole match and `captureGroups[i]` is capture group `i` (empty
    /// string for a group that didn't participate). Lets a rule inspect and parse the matched
    /// text — parsing number words into an integer, for example — rather than only substituting
    /// a fixed template. Returning the input `wholeMatch` unchanged is how a rule declines a
    /// candidate match it can't confidently handle.
    static func replace(_ text: String, _ pattern: String, transform: (String, [String]) -> String) -> String {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: true) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let whole = nsText.substring(with: match.range)
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : nsText.substring(with: range)
            }
            result += transform(whole, groups)
            lastEnd = match.range.location + match.range.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    /// Same as `escape`, named for use inside a pattern passed to the case-sensitive helpers
    /// below, so a reader isn't misled into thinking `.caseInsensitive` still applies.
    static func escapeCaseSensitive(_ literal: String) -> String {
        NSRegularExpression.escapedPattern(for: literal)
    }

    /// Case-sensitive replacement, for the rare rule (filler removal) where matching "ER" the
    /// acronym as if it were "er" the hesitation sound would corrupt real words.
    static func replaceCaseSensitive(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: false) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

extension NSTextCheckingResult {
    func string(at index: Int, in text: String) -> String? {
        let nsRange = range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }
}

enum Punctuation {
    /// The closed dotfile names, as a regex alternation (longest first).
    private static let dotfileNames = SpokenPathTokens.dotfiles.sorted { $0.count > $1.count }.joined(separator: "|")

    /// Final pass: fixes spacing, doubled punctuation and capitalization left behind by earlier
    /// rules. `capitalize` is false for a code-editor/terminal target (see
    /// `CleanupOptions.isCodeContext`): punctuation there is syntax, so identifiers must keep
    /// their spoken casing exactly (an identifier a `CasingCommands` command just built, or a
    /// literal spoken word) rather than have its first letter forced uppercase.
    static func tidy(_ text: String, capitalize: Bool = true, preserveSyntax: Bool = false) -> String {
        if preserveSyntax { return text }
        let literals = LiteralSyntaxProtection(text, codeContext: false)
        var out = literals.masked
        // Preserve semicolons: they separate clauses or encode literal structure. Replacing one
        // with a comma can introduce a comma splice or corrupt code and labelled fields.
        // The one exception is a converted dotfile (".bashrc", ".env.local"): its dot is part of the
        // name and the space before it separates it from the word before.
        out = Regex.replace(out, "[ ]+([,.;:!?])(?!(?<=\\.)(?:\(dotfileNames))(?![A-Za-z0-9_-]))", with: "$1")
        out = Regex.replace(out, ",\\s*([.!?])", with: "$1")
        // Repeated dots can be an intentional ellipsis, not duplicate punctuation.
        out = Regex.replace(out, "([.!?])\\s*,+(?=\\s|$)", with: "$1")
        out = Regex.replace(out, ",{2,}", with: ",")
        out = Regex.replace(out, "^[\\s,;:]+", with: "")
        out = Regex.replace(out, "[ ]*\\n[ ]*", with: "\n")
        out = Regex.replace(out, "[ ]{2,}", with: " ")
        if capitalize { out = SentenceAbbreviations.loweringStrayPrepositions(capitalizeSentences(out)) }
        return literals.restore(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? text
    }

    /// Uppercases the first letter of the text and of each sentence / line. A word that already
    /// has an uppercase letter after its first ("iPhone", "macOS", "eBay", "gRPC") is the
    /// speaker's or the model's deliberate casing and is left as it is, and so is a converted
    /// technical token ("p99", "us-east-1", "--force", "package.json").
    static func capitalizeSentences(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var capitalizeNext = true
        var abbreviation: SentenceAbbreviations.Kind?
        var previous: Character = " "
        for (index, char) in chars.enumerated() {
            // A converted dotfile at the start of a sentence stays as typed: ".vimrc is stale".
            if capitalizeNext, ConvertedTokenShape.startsDotfile(chars, at: index) {
                result.append(char)
                capitalizeNext = false
                previous = char
                continue
            }
            if capitalizeNext, char.isLetter {
                result.append(contentsOf: sentenceStart(char, at: index, in: chars, after: abbreviation))
                capitalizeNext = false
            } else {
                result.append(char)
                if char.isLetter || char.isNumber { capitalizeNext = false }
            }
            if char == "\n" {
                capitalizeNext = true
                abbreviation = nil
            } else if char == " ", ".!?".contains(previous) {
                capitalizeNext = true
                abbreviation = previous == "." ? SentenceAbbreviations.kind(endingAt: index - 1, in: chars) : nil
            }
            previous = char
        }
        return result
    }

    /// The first letter of a sentence, upper case, unless it keeps its own casing ("iPhone", "p99") or follows an
    /// abbreviation ("p.m. on Thursday", "e.g. a screwdriver"), where it continues the sentence: it stays as it is,
    /// and a title-cased "On" a model wrote after "p.m." goes back to lower case.
    private static func sentenceStart(
        _ char: Character, at index: Int, in chars: [Character], after abbreviation: SentenceAbbreviations.Kind?
    ) -> String {
        if let abbreviation, SentenceAbbreviations.keepsContinuing(abbreviation, wordAt: index, in: chars) {
            return SentenceAbbreviations.isTitleCasedContinuation(wordAt: index, in: chars) ? char.lowercased() : String(char)
        }
        if SentenceAbbreviations.isSpacedMeridiemHalf(wordAt: index, in: chars) { return String(char) }
        let keepsCase = hasInnerUppercase(chars, from: index) || ConvertedTokenShape.startsCaseSensitiveToken(chars, at: index)
        return keepsCase ? String(char) : char.uppercased()
    }

    /// True when the letter/digit run that starts at `start` has an uppercase letter after its first character.
    private static func hasInnerUppercase(_ chars: [Character], from start: Int) -> Bool {
        var index = start + 1
        while index < chars.count, chars[index].isLetter || chars[index].isNumber {
            if chars[index].isUppercase { return true }
            index += 1
        }
        return false
    }

    /// Strips trailing sentence punctuation, e.g. for list items.
    static func stripTrailing(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?"))
    }

    static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep acronyms and proper nouns ("I", "NASA", "Sarah") untouched.
        let firstWord = text.prefix { $0.isLetter }
        if firstWord == "I" || (firstWord.count > 1 && firstWord == firstWord.uppercased()) {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }
}


/// Compiled patterns, built once per (pattern, options) and reused: cleanup runs dozens of
/// regex passes per dictation, and compiling them each time cost ~9× the actual matching.
/// NSRegularExpression is immutable and safe to share across threads.
enum RegexCache {
    private struct Key: Hashable {
        let pattern: String
        let caseInsensitive: Bool
    }

    private static let cache = OSAllocatedUnfairLock<[Key: NSRegularExpression]>(uncheckedState: [:])

    static func compiled(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = Key(pattern: pattern, caseInsensitive: caseInsensitive)
        if let hit = cache.withLockUnchecked({ $0[key] }) { return hit }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return nil
        }
        cache.withLockUnchecked { $0[key] = regex }
        return regex
    }
}
