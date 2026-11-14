import Foundation

/// Keeps quoted spans out of every step of the tone pass, word rules and formatting alike: a person who
/// says `Say “I'm gonna leave” verbatim` wants the quoted words kept exactly.
///
/// One principle decides every doubt: when the code cannot tell whether a mark closes a quotation, it
/// protects MORE, never less. Text left as spoken is always acceptable; text changed inside a quotation
/// never is.
///
/// - Double quotes (“ ” and straight ") nest: a span runs until every opener has been closed, and mixed
///   marks pair up (“ … " is a span). A straight " opens only after a space, a line start or an opening
///   bracket or quote, so 5" is not an opener. A span with no end runs to the end of the text.
/// - Single quotes open as follows. A curly ‘ always opens, whatever precedes it. A straight ' opens only at
///   the start of a word, and only when a quoted word can follow: not a decade ('90s) and not an elision
///   ('n', 'til, 'cause, 'em, 'twas), which are apostrophes. A mark may close or may be a
///   possessive (the students’ notes), so the span runs to the LAST plausible closing mark anywhere after
///   the opener, across line breaks: a ’ or ' that is not followed by a letter or digit and does not follow
///   a space. A ’ that is followed by a letter is inside a word (don’t, ’n’, ’90s) and is never a quote
///   mark. With no plausible closing mark the pairing is uncertain, so the span runs to the end of the
///   text, like an unclosed double quote.
struct ToneQuoteMasking {
    let masked: String
    private let spans: [(token: String, value: String)]

    init(_ text: String) {
        let characters = Array(text)
        var namespace = "HUSHYQUOTE"
        while text.contains(namespace) { namespace += "X" }
        var output = ""
        var saved: [(token: String, value: String)] = []
        var cursor = 0
        for (range, _) in Self.ranges(in: characters) {
            output += String(characters[cursor..<range.lowerBound])
            let token = namespace + String(saved.count) + "TOKEN"
            saved.append((token, String(characters[range])))
            output += token
            cursor = range.upperBound
        }
        output += String(characters[cursor...])
        masked = output
        spans = saved
    }

    /// The quoted spans of `text`, whole, in order.
    static func quotedSpans(in text: String) -> [String] {
        let characters = Array(text)
        return ranges(in: characters).filter(\.isQuotation).map { String(characters[$0.range]) }
    }

    /// The text with every span put back, or nil when a placeholder did not survive the steps in between.
    func restore(_ text: String) -> String? {
        var output = text
        for span in spans {
            guard output.components(separatedBy: span.token).count == 2 else { return nil }
            output = output.replacingOccurrences(of: span.token, with: span.value)
        }
        return output
    }

    // MARK: Finding spans

    /// What is masked: every quotation, and the lone apostrophe of a decade or elision ('90s, 'cause). The
    /// apostrophe is masked so that the literal protection that runs after this step does not read it as the
    /// opening of a quoted string and swallow the text up to the next apostrophe. Only quotations count as quoted
    /// spans (`isQuotation`).
    private static func ranges(in characters: [Character]) -> [(range: Range<Int>, isQuotation: Bool)] {
        var result: [(Range<Int>, Bool)] = []
        var cursor = 0
        while cursor < characters.count {
            if let end = spanEnd(in: characters, from: cursor) {
                result.append((cursor..<end, true))
                cursor = end
            } else if isLoneApostrophe(characters, at: cursor) {
                result.append((cursor..<(cursor + 1), false))
                cursor += 1
            } else {
                cursor += 1
            }
        }
        return result
    }

    /// A straight ' at the start of a word that is a decade or an elision, so not a quote opener.
    private static func isLoneApostrophe(_ characters: [Character], at index: Int) -> Bool {
        characters[index] == "'" && startsWord(characters, at: index) && !quotedWordFollows(characters, after: index)
    }

    private static func spanEnd(in characters: [Character], from start: Int) -> Int? {
        switch characters[start] {
        case "\u{201C}": return doubleEnd(in: characters, from: start)
        case "\"" where opensStraight(characters, at: start): return doubleEnd(in: characters, from: start)
        // A curly left quote is unambiguous: it opens a span whatever precedes it (“Say‘I'm…’”).
        case "\u{2018}": return singleEnd(in: characters, from: start)
        // A straight ' is also an apostrophe, so it opens a span only at the start of a word and only when
        // something that can be a quoted word follows (not a decade or an elision: '90s, 'n', 'til, 'cause).
        case "'" where startsWord(characters, at: start) && quotedWordFollows(characters, after: start):
            return singleEnd(in: characters, from: start)
        default: return nil
        }
    }

    /// Elisions written with a leading apostrophe: they start a word but never a quotation.
    private static let elisions: Set<String> = [
        "n", "til", "till", "cause", "cos", "coz", "em", "twas", "tis", "twere", "twill", "twould", "bout", "round",
        "nother", "kay", "cept", "member", "scuse", "tween", "neath", "gainst", "fraid", "nuff", "sup",
    ]

    /// Whether what follows the straight ' at `index` can be a quoted word: a letter that is not an elision, or a
    /// number that is not a decade ('90s, '90).
    private static func quotedWordFollows(_ characters: [Character], after index: Int) -> Bool {
        var end = index + 1
        guard end < characters.count else { return false }
        if characters[end].isNumber {
            var digits = 0
            while end < characters.count, characters[end].isNumber { digits += 1; end += 1 }
            let hasS = end < characters.count && (characters[end] == "s" || characters[end] == "S")
            let afterS = hasS ? end + 1 : end
            let isDecade = digits == 2 && (afterS >= characters.count || !(characters[afterS].isLetter || characters[afterS].isNumber))
            return !isDecade
        }
        guard characters[end].isLetter else { return true }
        var word = ""
        while end < characters.count, characters[end].isLetter { word.append(characters[end]); end += 1 }
        return !elisions.contains(word.lowercased())
    }

    private static func startsWord(_ characters: [Character], at index: Int) -> Bool {
        index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber)
    }

    /// A straight " opens after nothing, a space, a line break or an opening bracket or quote.
    private static func opensStraight(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return previous.isWhitespace || "([{\u{201C}\u{2018}".contains(previous)
    }

    private static func doubleEnd(in characters: [Character], from start: Int) -> Int {
        var depth = 1
        var cursor = start + 1
        while cursor < characters.count {
            switch characters[cursor] {
            case "\u{201C}": depth += 1
            case "\u{201D}": depth -= 1
            case "\"": if opensStraight(characters, at: cursor) { depth += 1 } else { depth -= 1 }
            default: break
            }
            if depth == 0 { return cursor + 1 }
            cursor += 1
        }
        return characters.count
    }

    private static func singleEnd(in characters: [Character], from start: Int) -> Int {
        var last: Int?
        var cursor = start + 1
        while cursor < characters.count {
            if closesSingle(characters, at: cursor) { last = cursor + 1 }
            cursor += 1
        }
        return last ?? characters.count
    }

    /// A ’ or ' that follows something other than a space and is not followed by a letter or digit.
    private static func closesSingle(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "\u{2019}" || characters[index] == "'" else { return false }
        guard !characters[index - 1].isWhitespace else { return false }
        guard index + 1 < characters.count else { return true }
        return !(characters[index + 1].isLetter || characters[index + 1].isNumber)
    }
}
