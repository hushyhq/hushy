import Foundation

/// Spoken casing commands for code editors and terminals: "camel case get user by id" ->
/// `getUserById`, "snake case max retries" -> `max_retries`, "pascal case user profile" ->
/// `UserProfile`, "kebab case dry run" -> `dry-run`, "constant case max retries" or "constant max
/// retries" -> `MAX_RETRIES`.
///
/// Only runs when `CleanupOptions.isCodeContext` is true (see `TextCleaner.clean`): these commands
/// would otherwise mangle prose that happens to contain "camel case". Two modes:
///
/// - **Start mode**, when the command opens the utterance or a clause (after a comma, a full stop,
///   or another casing command): everything up to the next punctuation or casing keyword is the
///   identifier, so "camel case get user by id, then log it" converts "get user by id", unless the
///   next clause starts first (`CasingBoundaries.startLength`: "snake case user id and then retry").
/// - **Embedded mode**, when words come before it in the same clause ("call camel case get user by
///   id after saving"): the identifier ends at the first boundary word from the closed classes in
///   `CasingBoundaries`, because nothing else marks where it stops.
///
/// `TextCleaner.clean` runs `CodeSymbols` first, so a spoken "dot" or paren inside a casing phrase has
/// already become punctuation and ends the scan.
enum CasingCommands {
    enum Casing: String, CaseIterable {
        case camel = "camel case"
        case snake = "snake case"
        case pascal = "pascal case"
        case kebab = "kebab case"
        case constantCase = "constant case"
        case constant = "constant"

        static func matching(_ keyword: String) -> Casing? {
            let normalized = keyword.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return allCases.first { $0.rawValue == normalized }
        }
    }

    private enum Mode { case start, embedded }
    private struct Chain {
        let mode: Mode
    }

    private static let keywordPattern = "\\b(?:camel case|snake case|pascal case|kebab case|constant case|constant)\\b"
    private static let keywordRegex = try? NSRegularExpression(
        pattern: keywordPattern.replacingOccurrences(of: " ", with: "\\s+"), options: [.caseInsensitive])

    /// Words right before a casing keyword that make it an ordinary noun phrase ("the camel case
    /// style", "a constant value"), not a command. Only checked in embedded mode.
    private static let nounPhraseLeaders: Set<String> = CasingBoundaries.determiners
        .union(["a", "each", "every", "any", "one", "no", "another"])

    /// Applies every casing command in `text`.
    static func apply(_ text: String) -> String {
        guard let regex = keywordRegex else { return text }
        let ns = text as NSString
        let found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty else { return text }
        var out = ""
        var cursor = 0
        var previous: Chain?
        for match in found where match.range.location >= cursor {
            let start = match.range.location
            guard let casing = Casing.matching(ns.substring(with: match.range)) else { continue }
            let gap = ns.substring(with: NSRange(location: cursor, length: start - cursor))
            let chained = previous != nil && gap.allSatisfy { $0 == " " || $0 == "\t" }
            let before = ns.substring(to: start)
            let mode = chained ? (previous?.mode ?? .start) : (hasWordInClause(before) ? Mode.embedded : .start)
            if mode == .embedded, nounPhraseLeaders.contains(lastWord(of: before)) {
                previous = nil
                continue
            }
            let scan = scanWords(ns, from: NSMaxRange(match.range), regex: regex)
            let count = mode == .start ? CasingBoundaries.startLength(of: scan.words) : CasingBoundaries.length(of: scan.words)
            guard count > 0 else { previous = nil; continue }
            if chained, previous?.mode == .start, gap.isEmpty { out += " " }
            out += gap + convert(Array(scan.words.prefix(count)), to: casing)
            // Start mode swallows the blanks after a name that ran to the end of the clause; a name cut
            // short by `startLength` leaves the next clause's words (and their space) where they were.
            let ranToClauseEnd = count == scan.words.count
            cursor = mode == .start && ranToClauseEnd ? swallowTrailingBlanks(ns, from: scan.ends[count - 1]) : scan.ends[count - 1]
            previous = Chain(mode: mode)
        }
        return out + ns.substring(from: cursor)
    }

    static func convert(_ words: [String], to casing: Casing) -> String {
        let lower = words.map { $0.lowercased() }
        switch casing {
        case .camel:
            guard let first = lower.first else { return "" }
            return ([first] + lower.dropFirst().map(capitalize)).joined()
        case .pascal:
            return lower.map(capitalize).joined()
        case .snake:
            return lower.joined(separator: "_")
        case .kebab:
            return lower.joined(separator: "-")
        case .constant, .constantCase:
            return lower.map { $0.uppercased() }.joined(separator: "_")
        }
    }

    // MARK: Scanning

    /// Letters or digits earlier in the same clause: the command is inside a sentence.
    private static func hasWordInClause(_ before: String) -> Bool {
        let clause = before.split(omittingEmptySubsequences: false) { ",;:.!?\n".contains($0) }.last ?? ""
        return clause.contains { $0.isLetter || $0.isNumber }
    }

    private static func lastWord(of before: String) -> String {
        let token = before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        return token.lowercased().filter { $0.isLetter }
    }

    /// The alphanumeric words after `position`, each separated from the last by spaces, with the end
    /// offset of every word. Stops at punctuation, a line break, a word that continues with an
    /// apostrophe, hyphen or underscore, or the next casing keyword.
    private static func scanWords(_ ns: NSString, from position: Int, regex: NSRegularExpression) -> (words: [String], ends: [Int]) {
        var words: [String] = []
        var ends: [Int] = []
        var pos = position
        while true {
            let tokenStart = skipBlanks(ns, from: pos)
            guard tokenStart > pos else { break }
            var tokenEnd = tokenStart
            while tokenEnd < ns.length, isWordCharacter(ns.character(at: tokenEnd)) { tokenEnd += 1 }
            guard tokenEnd > tokenStart else { break }
            if tokenEnd < ns.length, "'\u{2019}-_".contains(Character(UnicodeScalar(ns.character(at: tokenEnd)) ?? " ")) { break }
            let rest = NSRange(location: tokenStart, length: ns.length - tokenStart)
            if regex.firstMatch(in: ns as String, options: [.anchored], range: rest) != nil { break }
            words.append(ns.substring(with: NSRange(location: tokenStart, length: tokenEnd - tokenStart)))
            ends.append(tokenEnd)
            pos = tokenEnd
        }
        return (words, ends)
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
    }

    /// Start mode swallows the blanks after the identifier (so "getUser" meets a following "(" or the
    /// next casing command), except before an operator, which keeps its space ("max_retries = 3").
    private static func swallowTrailingBlanks(_ ns: NSString, from position: Int) -> Int {
        let end = skipBlanks(ns, from: position)
        guard end < ns.length, let scalar = UnicodeScalar(ns.character(at: end)) else { return end }
        return operatorStarts.contains(Character(scalar)) ? position : end
    }

    private static let operatorStarts: Set<Character> = Set("=<>+*/&|{\"'#!%@^~-")

    private static func skipBlanks(_ ns: NSString, from position: Int) -> Int {
        var pos = position
        while pos < ns.length, ns.character(at: pos) == 32 || ns.character(at: pos) == 9 { pos += 1 }
        return pos
    }

    private static func capitalize(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
