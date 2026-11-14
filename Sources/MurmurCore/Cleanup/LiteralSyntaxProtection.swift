import Foundation

/// Keeps explicitly delimited literals out of spoken-language rule transforms.
///
/// Backtick spans use matching maximal delimiter runs, as in Markdown code spans. Escaped
/// backticks are ordinary characters. Unclosed runs remain ordinary input. In code context only,
/// balanced ASCII single- and double-quoted spans are also protected; typographic/curly quotes
/// are intentionally outside this syntax contract.
struct LiteralSyntaxProtection {
    let masked: String
    let endsInBacktickLiteral: Bool
    private let literals: [(token: String, value: String)]

    init(_ text: String, codeContext: Bool) {
        let characters = Array(text)
        let backtickSpans = Self.backtickSpans(in: characters)
        let spansByStart = Dictionary(uniqueKeysWithValues: backtickSpans.map { ($0.lowerBound, $0.upperBound) })
        var output = ""
        var saved: [(token: String, value: String)] = []
        var cursor = 0
        var namespace = "HUSHYLITERAL"
        while text.contains(namespace) { namespace += "X" }
        let trimmedEnd = characters.lastIndex(where: { !$0.isWhitespace })
        endsInBacktickLiteral = trimmedEnd.map { end in
            backtickSpans.contains { $0.upperBound - 1 == end }
        } ?? false

        while cursor < characters.count {
            if let endExclusive = spansByStart[cursor] {
                Self.save(characters, start: cursor, endExclusive: endExclusive,
                     namespace: namespace, saved: &saved, output: &output)
                cursor = endExclusive
                continue
            }

            let delimiter = characters[cursor]
            let isASCIIQuote = delimiter == "\"" || delimiter == "'"
            let boundary = cursor == 0 || !characters[cursor - 1].isLetter && !characters[cursor - 1].isNumber
            if codeContext && isASCIIQuote && boundary && !Self.isEscaped(characters, at: cursor) {
                if let endExclusive = Self.quotedSpanEnd(in: characters, from: cursor, delimiter: delimiter) {
                    Self.save(characters, start: cursor, endExclusive: endExclusive,
                         namespace: namespace, saved: &saved, output: &output)
                    cursor = endExclusive
                    continue
                }
            }
            output.append(delimiter)
            cursor += 1
        }

        masked = output
        literals = saved
    }

    func restore(_ text: String) -> String? {
        var output = text
        for literal in literals {
            guard output.components(separatedBy: literal.token).count == 2 else { return nil }
            output = output.replacingOccurrences(of: literal.token, with: literal.value)
        }
        return output
    }

    /// Returns a reason when a candidate changes, removes, adds, or reorders a balanced backtick
    /// span. This is a mechanical literal-preservation veto, not a semantic quality judgment.
    static func violation(candidate: String, draft: String) -> String? {
        let draftCharacters = Array(draft)
        let candidateCharacters = Array(candidate)
        let source = backtickSpans(in: draftCharacters).map { span in
            Array(String(draftCharacters[span]).utf8)
        }
        let answer = backtickSpans(in: candidateCharacters).map { span in
            Array(String(candidateCharacters[span]).utf8)
        }
        return source == answer ? nil : "changed backtick literal"
    }

    /// The same veto for a prompt written for an AI agent, where the model is asked to put identifiers, paths and
    /// commands in backticks. Every backtick span of the draft must still be there, whole and in order, and the
    /// answer may add spans only around what the speaker said: each word of the span (an underscore, dot, dash or
    /// capital letter starts a new one) is a spoken word, or several spoken words run together ("r f" for `rf`).
    /// A span around anything else, or a draft span that was changed or dropped, is still refused.
    static func violation(candidate: String, draft: String, allowingSpokenLiterals: Bool) -> String? {
        guard allowingSpokenLiterals else { return violation(candidate: candidate, draft: draft) }
        let draftCharacters = Array(draft)
        let candidateCharacters = Array(candidate)
        let source = backtickSpans(in: draftCharacters).map { String(draftCharacters[$0]) }
        let spoken = SpokenWords(draft)
        var kept = 0
        for span in backtickSpans(in: candidateCharacters) {
            let text = String(candidateCharacters[span])
            if kept < source.count, Array(text.utf8) == Array(source[kept].utf8) {
                kept += 1
            } else if !spoken.covers(spanContent(text)) || isOrdinaryProse(spanContent(text)) {
                return "changed backtick literal"
            }
        }
        return kept == source.count ? nil : "changed backtick literal"
    }

    /// The answer with every span the speaker did not have, and that wraps only ordinary English ("`son` at `agent`"), put
    /// back to plain words. A span of the draft, and any span that reads as code, stay. Code formatting is for what the
    /// speaker said as code: a file, a flag, a command, a name in camel case. The prompt register asks the model for
    /// backticks around "identifiers, paths and commands", and a small model reads that as licence for any noun.
    static func unwrappingOrdinarySpans(in candidate: String, draft: String) -> String {
        let characters = Array(candidate)
        let draftCharacters = Array(draft)
        let source = backtickSpans(in: draftCharacters).map { String(draftCharacters[$0]) }
        let spoken = SpokenWords(draft)
        var kept = 0
        var plain: [(Range<Int>, String)] = []
        for span in backtickSpans(in: characters) {
            let text = String(characters[span])
            if kept < source.count, Array(text.utf8) == Array(source[kept].utf8) {
                kept += 1
            } else if isOrdinaryProse(spanContent(text)), spoken.covers(spanContent(text)) {
                // Said, but not as code. (Words that were not said stay wrapped, and the checks refuse them.)
                plain.append((span, spanContent(text)))
            }
        }
        guard !plain.isEmpty else { return candidate }
        var result = characters
        for (range, content) in plain.reversed() { result.replaceSubrange(range, with: Array(content)) }
        return String(result)
    }

    private static let phraseWords: Set<String> = [
        "a", "an", "the", "at", "of", "to", "in", "on", "and", "or", "is", "it", "for", "with", "my", "your", "this", "that",
        "as", "by", "from", "so", "but", "not", "be", "are", "was",
    ]

    /// True when a span's content is only ordinary English words (or the name of an AI model or product): no dot, slash,
    /// dash, underscore, digit or other syntax, no capital inside a word, and every word an everyday word. `rf`,
    /// `getUserById`, `auth_client.py` and `npm run dev` are code; `agent`, `son at agent` and `Sonnet` are not.
    static func isOrdinaryProse(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "\u{2019}" }) else { return false }
        let words = trimmed.split(separator: " ").map(String.init)
        // Several words with no little word among them are a command ("npm run dev", "git status"), not a phrase.
        if words.count > 1, !words.contains(where: { phraseWords.contains($0.lowercased()) }) { return false }
        for word in words {
            if word.dropFirst().contains(where: \.isUppercase) { return false }
            let key = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            guard LearningLexicon.isCommonWord(key) || AIModelNames.isModelName(key) else { return false }
        }
        return true
    }

    /// What is between the delimiter runs of a span.
    private static func spanContent(_ span: String) -> String {
        String(span.drop(while: { $0 == "`" }).reversed().drop(while: { $0 == "`" }).reversed())
    }

    /// The words of a spoken text, for judging whether an identifier was said.
    private struct SpokenWords {
        private let words: [String]
        private static let longestRun = 6

        init(_ text: String) {
            words = SpokenWords.pieces(of: text)
        }

        /// Every piece of `content` is a spoken word or a run of up to six spoken words. Digits are left to the number
        /// checks, which judge them against what was said.
        func covers(_ content: String) -> Bool {
            let needed = SpokenWords.pieces(of: content).filter { !$0.allSatisfy(\.isNumber) }
            guard !needed.isEmpty else { return false }
            return needed.allSatisfy(isSpoken)
        }

        private func isSpoken(_ piece: String) -> Bool {
            for start in words.indices {
                var joined = ""
                for word in words[start..<min(words.count, start + Self.longestRun)] {
                    joined += word
                    if joined == piece { return true }
                    if joined.count >= piece.count { break }
                }
            }
            return false
        }

        /// Lowercase runs of letters or of digits; a case change from lower to upper starts a new one.
        static func pieces(of text: String) -> [String] {
            var result: [String] = []
            var current = ""
            var previous: Character?
            func flush() {
                if !current.isEmpty { result.append(current.lowercased()) }
                current = ""
            }
            for character in text {
                guard character.isLetter || character.isNumber else { flush(); previous = nil; continue }
                if let previous, previous.isNumber != character.isNumber || (previous.isLowercase && character.isUppercase) { flush() }
                current.append(character)
                previous = character
            }
            flush()
            return result
        }
    }

    /// Ranges include both the opening and closing delimiter runs.
    private static func backtickSpans(in characters: [Character]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var cursor = 0
        while cursor < characters.count {
            guard characters[cursor] == "`" else {
                cursor += 1
                continue
            }
            let runLength = backtickRunLength(in: characters, from: cursor)
            if isEscaped(characters, at: cursor) { cursor += runLength; continue }
            let openerEnd = cursor + runLength
            var search = openerEnd
            var close: Int?
            while search < characters.count {
                guard characters[search] == "`" else {
                    search += 1
                    continue
                }
                let candidateLength = backtickRunLength(in: characters, from: search)
                if isEscaped(characters, at: search) { search += candidateLength; continue }
                if candidateLength == runLength {
                    close = search + candidateLength
                    break
                }
                search += candidateLength
            }
            if let endExclusive = close {
                spans.append(cursor..<endExclusive)
                cursor = endExclusive
            } else {
                // An unmatched run is literal text. Skip the whole run so its own characters
                // cannot be reconsidered as shorter openers.
                cursor = openerEnd
            }
        }
        return spans
    }

    private static func backtickRunLength(in characters: [Character], from start: Int) -> Int {
        var end = start
        while end < characters.count && characters[end] == "`" { end += 1 }
        return end - start
    }

    private static func quotedSpanEnd(in characters: [Character], from start: Int, delimiter: Character) -> Int? {
        var cursor = start + 1
        while cursor < characters.count {
            if characters[cursor] == delimiter && !Self.isEscaped(characters, at: cursor) { return cursor + 1 }
            cursor += 1
        }
        return nil
    }

    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        var cursor = index
        var backslashes = 0
        while cursor > 0 && characters[cursor - 1] == "\\" {
            backslashes += 1
            cursor -= 1
        }
        return backslashes.isMultiple(of: 2) == false
    }

    private static func save(
        _ characters: [Character], start: Int, endExclusive: Int, namespace: String,
        saved: inout [(token: String, value: String)], output: inout String
    ) {
        let token = namespace + String(saved.count) + "TOKEN"
        saved.append((token, String(characters[start..<endExclusive])))
        output += token
    }
}
