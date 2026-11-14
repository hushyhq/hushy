import Foundation

/// A closed grammar of spoken symbols for code lines, comments and shell commands, applied only in a
/// code context (`CleanupOptions.isCodeContext`). It works on the words of one line:
///
/// - `equals` `=`, `double equals` `==`, `colon equals` `:=`, `fat arrow` `=>`;
/// - `comma` `,`, `semicolon` `;`, `colon` `:`, `colon slash slash` `://`;
/// - `open`/`close` `bracket` and `brace`; `underscore` between words; `slash` between path parts;
/// - quotes (`CodeQuotes`) and flags (`CodeFlags`);
/// - a single digit word right after `=` becomes a digit ("equals five" -> `= 5`).
///
/// "dot", "open paren", "close paren" and "arrow" stay with `CodeSymbols`, which runs next.
///
/// The rule for every symbol word is the same: when it could be ordinary speech in its position it
/// stays a word. A symbol word after a determiner or a noun-leading word ("the colon", "add comma"),
/// before a word that names it as a noun ("comma separated"), or with nothing to its left to attach to
/// ("equals" opening the sentence, "it equals zero") is left alone. Inside a comment (the line opened
/// with a `CodeComments` delimiter) only `underscore` and `slash` convert, because a comment is prose
/// and "the count equals zero" there is a sentence.
enum CodeSymbolGrammar {
    struct Piece {
        var text: String
        var gluesLeft = false
        var gluesRight = false
    }

    private enum Kind {
        case equals, doubleEquals, walrus, fatArrow, comma, semicolon, colon, urlScheme
        case openBracket, closeBracket, openBrace, closeBrace, underscore, slash
    }

    /// Longest phrase first, so "colon slash slash" and "colon equals" win over a bare "colon".
    private static let phrases: [(words: [String], kind: Kind)] = [
        (["colon", "slash", "slash"], .urlScheme), (["colon", "equals"], .walrus),
        (["double", "equals"], .doubleEquals), (["fat", "arrow"], .fatArrow),
        (["open", "square", "bracket"], .openBracket), (["close", "square", "bracket"], .closeBracket),
        (["open", "curly", "brace"], .openBrace), (["close", "curly", "brace"], .closeBrace),
        (["open", "bracket"], .openBracket), (["close", "bracket"], .closeBracket),
        (["open", "brace"], .openBrace), (["close", "brace"], .closeBrace),
        (["forward", "slash"], .slash), (["equals"], .equals), (["semicolon"], .semicolon),
        (["comma"], .comma), (["colon"], .colon), (["underscore"], .underscore), (["slash"], .slash),
    ]

    /// Converts the spoken symbols in `text`. The first line may open with a comment delimiter.
    /// With a `vault`, every quoted string is swapped for a placeholder that the later stages cannot
    /// see into; the caller restores them (`CodeQuotes.Vault.restore`) when those stages are done.
    static func apply(_ text: String, vault: CodeQuotes.Vault? = nil) -> String {
        text.components(separatedBy: "\n").enumerated().map { offset, line in
            if offset == 0, let comment = CodeComments.split(line) {
                return comment.delimiter + convert(comment.body, isComment: true, vault: vault)
            }
            return convert(line, isComment: false, vault: vault)
        }.joined(separator: "\n")
    }

    /// Removes the space before "(" after a call name. Two kinds of evidence, either is enough:
    /// - the name itself is code (`cache.value (`, `get_user (`, `getUser (`);
    /// - the name stands where a call goes, with its arguments in one piece: it opens the line, or
    ///   follows `=`, an opener, a comma, or a statement keyword ("print (x)", "total = sum (values)",
    ///   "return parse (line)"), and the parenthesis holds names, numbers and strings, never a phrase.
    /// A plain word inside a sentence keeps its space, so "get user (id)" and "see below (two options)"
    /// are unchanged, and so are control keywords ("if (x)", "for (item)").
    static func tightenCalls(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: "([\\w\\]\\)]*(?:\\.[A-Za-z_]\\w*|_\\w+|[a-z0-9][A-Z]\\w*)) \\("
        ) else { return text }
        return text.components(separatedBy: "\n").map { line in
            guard !CodeComments.startsWithDelimiter(line) else { return line }
            let tightened = expression.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1(")
            return tightenStatementCalls(tightened)
        }.joined(separator: "\n")
    }

    private static let callPattern = try? NSRegularExpression(
        pattern: "(^\\s*|[=(\\[{,]\\s*|\\b[A-Za-z]+\\s+)([A-Za-z_][A-Za-z0-9_]*) \\(((?:[^()\\n]|\\([^()\\n]*\\))*)\\)")

    private static func tightenStatementCalls(_ line: String) -> String {
        guard let callPattern else { return line }
        let ns = line as NSString
        var out = ""
        var cursor = 0
        for match in callPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let lead = ns.substring(with: match.range(at: 1))
            let name = ns.substring(with: match.range(at: 2))
            let arguments = ns.substring(with: match.range(at: 3))
            guard isCallPosition(lead: lead, name: name), hasOnlyCodeArguments(arguments) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += "\(lead)\(name)(\(arguments))"
            cursor = NSMaxRange(match.range)
        }
        return out + ns.substring(from: cursor)
    }

    /// The name is where a call goes and is not a keyword or a function word.
    private static func isCallPosition(lead: String, name: String) -> Bool {
        let lowerName = name.lowercased()
        guard !CodeGrammarSets.controlKeywords.contains(lowerName),
              !CodeSymbolWords.functionWords.contains(lowerName),
              !CodeGrammarSets.subjects.contains(lowerName) else { return false }
        let trimmed = lead.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if let last = trimmed.last, "=([{,".contains(last) { return true }
        return CodeGrammarSets.callLeaders.contains(trimmed.lowercased())
    }

    /// Every comma-separated argument is one piece (a name, a number, a string, a member access).
    private static func hasOnlyCodeArguments(_ arguments: String) -> Bool {
        arguments.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { piece in
            !piece.trimmingCharacters(in: .whitespaces).contains(" ")
        }
    }

    // MARK: Line conversion

    private static func convert(_ line: String, isComment: Bool, vault: CodeQuotes.Vault?) -> String {
        let original = line.split(separator: " ").map(String.init)
        guard !original.isEmpty else { return line }
        let tokens = isComment ? original : CodeQuotes.pair(original, vault: vault)
        var state = LineState(tokens: tokens, isComment: isComment)
        var changed = tokens != original
        var index = 0
        while index < tokens.count {
            if let result = state.rewrite(at: index) {
                state.pieces += result.pieces
                index += result.consumed
                changed = true
            } else {
                state.pieces.append(Piece(text: tokens[index]))
                index += 1
            }
        }
        // Untouched code (indentation, trailing blanks, runs of spaces) must survive byte for byte.
        guard changed else { return line }
        let lead = line.prefix { $0 == " " }
        let trail = line.reversed().prefix { $0 == " " }
        return String(lead) + join(state.pieces) + String(trail)
    }

    private static func join(_ pieces: [Piece]) -> String {
        var result = ""
        for (offset, piece) in pieces.enumerated() {
            if offset > 0, !pieces[offset - 1].gluesRight, !piece.gluesLeft { result += " " }
            result += piece.text
        }
        return result
    }

    // MARK: Per-line state and rules

    private struct LineState {
        let tokens: [String]
        let lower: [String]
        let isComment: Bool
        var pieces: [Piece] = []
        var sawScheme = false

        init(tokens: [String], isComment: Bool) {
            self.tokens = tokens
            self.lower = tokens.map { CodeTokens.bare($0) }
            self.isComment = isComment
        }

        mutating func rewrite(at index: Int) -> (pieces: [Piece], consumed: Int)? {
            if !isComment, let flag = CodeFlags.flag(at: index, in: lower, previous: index > 0 ? lower[index - 1] : nil) {
                return ([Piece(text: flag.text)], flag.consumed)
            }
            if !isComment, lower[index] == "dash", let hyphen = hyphen(at: index) { return hyphen }
            for phrase in CodeSymbolGrammar.phrases where matches(phrase.words, at: index) {
                if isComment, phrase.kind != .underscore, phrase.kind != .slash { continue }
                let end = index + phrase.words.count
                if let result = emit(phrase.kind, at: index, end: end) { return result }
            }
            return nil
        }

        private func matches(_ words: [String], at index: Int) -> Bool {
            index + words.count <= lower.count && Array(lower[index..<(index + words.count)]) == words
        }

        /// More openers than closers ("open paren", "open bracket", "open brace") before `index`.
        private func isInsideOpener(_ index: Int) -> Bool {
            let shapes: Set<String> = ["paren", "parenthesis", "bracket", "brace", "square", "curly"]
            var depth = 0
            for position in 0..<index where position + 1 < lower.count && shapes.contains(lower[position + 1]) {
                if lower[position] == "open" { depth += 1 } else if lower[position] == "close" { depth -= 1 }
            }
            return depth > 0
        }

        private var lastPieceEndsOperand: Bool {
            guard let last = pieces.last?.text.last else { return false }
            return last.isLetter || last.isNumber || "_)]}\"'`/".contains(last)
        }

        /// There is something to the left to attach to: a word or closed operand in the same clause.
        private func hasLeftOperand(_ index: Int) -> Bool {
            guard index > 0, lastPieceEndsOperand else { return false }
            return !",;:".contains(tokens[index - 1].last ?? " ")
        }

        private mutating func emit(_ kind: Kind, at index: Int, end: Int) -> (pieces: [Piece], consumed: Int)? {
            var previous = index > 0 ? lower[index - 1] : ""
            // Inside an open bracket or parenthesis a lone "a" is a name ("open paren a comma b"), not the
            // article: an argument list has no noun phrase to attach "a comma" to.
            if previous == "a", isInsideOpener(index) { previous = "" }
            let following = end < lower.count ? lower[end] : nil
            let consumed = end - index
            switch kind {
            case .equals, .doubleEquals, .walrus:
                if kind == .doubleEquals, CodeSymbolWords.declarationQualifiers.contains(previous) { return nil }
                return assignment(kind, at: index, end: end, previous: previous, following: following)
            case .fatArrow:
                guard hasLeftOperand(index), let following, !CodeSymbolWords.nounLeaders.contains(previous),
                      !CodeSymbolWords.fatArrowFollowers.contains(following) else { return nil }
                return ([Piece(text: "=>")], consumed)
            case .comma, .semicolon, .colon:
                return separator(kind, at: index, consumed: consumed, previous: previous, following: following)
            case .urlScheme:
                guard index > 0, CodeTokens.isWordLike(previous), following != nil else { return nil }
                sawScheme = true
                return ([Piece(text: "://", gluesLeft: true, gluesRight: true)], consumed)
            case .openBracket, .openBrace, .closeBracket, .closeBrace:
                return bracket(kind, previous: previous, following: following, consumed: consumed)
            case .underscore:
                return underscore(previous: previous, following: following, consumed: consumed, hasPrevious: index > 0)
            case .slash:
                return slash(at: index, previous: previous, following: following, consumed: consumed)
            }
        }

        private func assignment(
            _ kind: Kind, at index: Int, end: Int, previous: String, following: String?
        ) -> (pieces: [Piece], consumed: Int)? {
            guard hasLeftOperand(index), let following, !CodeSymbolWords.statementSubjects.contains(previous),
                  !CodeSymbolWords.proseObjectLeaders.contains(following) else { return nil }
            let mark = kind == .equals ? "=" : (kind == .doubleEquals ? "==" : ":=")
            var pieces = [Piece(text: mark)]
            var consumed = end - index
            let afterNumber = end + 1 < lower.count ? lower[end + 1] : ""
            if let digit = CodeSymbolWords.digitWords[following], !CodeSymbolWords.unitWords.contains(afterNumber) {
                pieces.append(Piece(text: digit))
                consumed += 1
            }
            return (pieces, consumed)
        }

        private func separator(
            _ kind: Kind, at index: Int, consumed: Int, previous: String, following: String?
        ) -> (pieces: [Piece], consumed: Int)? {
            guard hasLeftOperand(index), !CodeSymbolWords.nounLeaders.contains(previous) else { return nil }
            if let following, CodeSymbolWords.nounFollowers.contains(following) { return nil }
            let mark = kind == .comma ? "," : (kind == .semicolon ? ";" : ":")
            // The colon before a port stays tight inside a URL or after localhost ("localhost:8080").
            // Two numbers around a colon are a port mapping, a ratio or a time ("8080:80").
            let isPortColon = kind == .colon && (sawScheme || previous == "localhost" || CodeTokens.isDigits(previous))
                && following.map(CodeTokens.isDigits) == true
            return ([Piece(text: mark, gluesLeft: true, gluesRight: isPortColon)], consumed)
        }

        private func bracket(_ kind: Kind, previous: String, following: String?, consumed: Int) -> (pieces: [Piece], consumed: Int)? {
            if CodeSymbolWords.nounLeaders.contains(previous) { return nil }
            // "open bracket key" is a subscript (`cache[key]`); "key" only names the keyboard key after
            // a determiner, which the noun-leader check above already catches.
            if let following, following != "key", CodeSymbolWords.nounFollowers.contains(following) { return nil }
            switch kind {
            case .closeBracket: return ([Piece(text: "]", gluesLeft: true)], consumed)
            case .closeBrace: return ([Piece(text: "}", gluesLeft: true)], consumed)
            case .openBrace: return ([Piece(text: "{", gluesRight: true)], consumed)
            default:
                let last = pieces.last?.text.last
                let attaches = last.map { $0.isLetter || $0.isNumber || "_)]".contains($0) } == true
                    && !CodeGrammarSets.spacedBeforeBracket.contains(previous)
                return ([Piece(text: "[", gluesLeft: attaches, gluesRight: true)], consumed)
            }
        }

        private func underscore(previous: String, following: String?, consumed: Int, hasPrevious: Bool) -> (pieces: [Piece], consumed: Int)? {
            guard hasPrevious, let following, CodeTokens.isWordLike(following),
                  !CodeSymbolWords.functionWords.contains(following),
                  !CodeSymbolWords.underscoreVerbLeaders.contains(previous),
                  let last = previous.last, last.isLetter || last.isNumber else { return nil }
            return ([Piece(text: "_", gluesLeft: true, gluesRight: true)], consumed)
        }

        private func slash(at index: Int, previous: String, following: String?, consumed: Int) -> (pieces: [Piece], consumed: Int)? {
            // A function word between two separators is a path part ("src slash a slash b"), never the article.
            let isSegment = isPathSegment(at: index - 1)
            guard index > 0, CodeTokens.isPathLike(previous), previous != "slash",
                  isSegment || !CodeSymbolWords.nounLeaders.contains(previous),
                  isSegment || !CodeSymbolWords.functionWords.contains(previous),
                  !CodeGrammarSets.subjects.contains(previous) else { return nil }
            guard let following else {
                // A trailing slash after a path word: "logs slash" -> "logs/".
                return ([Piece(text: "/", gluesLeft: true)], consumed)
            }
            // A path that ends in a slash and is followed by ordinary words ("cd logs slash and then ls").
            // The words before must show a path: a directory command, or a slash already written in it.
            if CodeSymbolWords.functionWords.contains(following), !isPathSegment(at: index + 1) {
                guard endsKnownPath(at: index) else { return nil }
                return ([Piece(text: "/", gluesLeft: true)], consumed)
            }
            guard CodeTokens.isPathLike(following), following != "slash",
                  !CodeGrammarSets.slashNounFollowers.contains(following) else { return nil }
            return ([Piece(text: "/", gluesLeft: true, gluesRight: true)], consumed)
        }

        /// A hyphen inside a name or path: "user dash profile" -> `user-profile`. The word is a name only
        /// where there is evidence for it: a separator joins it to the path already written or to the words
        /// that follow ("src slash user dash profile", "login dash page dot tsx"), or it is the argument of
        /// a file or name command ("mkdir date dash picker", "cd my dash app"). A "dash" after an article, or
        /// before a function word or a number word ("a dash of salt", "press dash to go back") is the mark.
        private func hyphen(at index: Int) -> (pieces: [Piece], consumed: Int)? {
            guard index > 0, index + 1 < lower.count else { return nil }
            let previous = lower[index - 1], following = lower[index + 1]
            let articles: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "no"]
            guard CodeTokens.isPathLike(previous), CodeTokens.isWordLike(following), !articles.contains(previous),
                  !CodeSymbolWords.functionWords.contains(following), !CasingBoundaries.isClauseWord(following),
                  CodeSymbolWords.digitWords[following] == nil, !["dash", "slash", "dot", "underscore"].contains(following),
                  !CodeGrammarSets.subjects.contains(previous) else { return nil }
            let isNameArgument = index >= 2 && CodeGrammarSets.nameTakers.contains(lower[index - 2])
            let joinedBefore = isPathSegment(at: index - 1)
            let isFunctionWord = CodeSymbolWords.functionWords.contains(previous)
            let joinedAfter = index + 2 < lower.count && CodeGrammarSets.separators.contains(lower[index + 2])
            guard isNameArgument || joinedBefore || (joinedAfter && !isFunctionWord) else { return nil }
            return ([Piece(text: "-", gluesLeft: true, gluesRight: true)], 1)
        }

        /// The word at `position` is a path part: it follows a written "/", "-" or "_" ("src/user"), or a
        /// separator word is spoken right before or after it ("a slash b").
        private func isPathSegment(at position: Int) -> Bool {
            guard position >= 0, position < lower.count else { return false }
            if let last = pieces.last, last.text == tokens[position], pieces.count >= 2,
               ["/", "-", "_"].contains(pieces[pieces.count - 2].text) { return true }
            let after = position + 1 < lower.count && CodeGrammarSets.separators.contains(lower[position + 1])
            let before = position >= 1 && CodeGrammarSets.separators.contains(lower[position - 1])
            return after && before
        }

        /// The word before a "slash" is a path: it follows a directory command ("cd logs"), or the path
        /// already holds a written slash ("src/app").
        private func endsKnownPath(at index: Int) -> Bool {
            if pieces.count >= 2, pieces[pieces.count - 2].text == "/" { return true }
            return index >= 2 && CodeGrammarSets.directoryCommands.contains(lower[index - 2])
        }
    }
}

/// Lists used only by `CodeSymbolGrammar`; kept out of the main file to hold it under the size limit.
private enum CodeGrammarSets {
    static let spacedBeforeBracket: Set<String> = [
        "return", "in", "if", "elif", "while", "for", "and", "or", "not", "yield", "await", "else",
        "case", "is", "from", "import", "of", "to",
    ]

    /// Words that open a control structure: never a call name, so "if (x)" keeps its space.
    static let controlKeywords: Set<String> = [
        "if", "elif", "else", "for", "while", "switch", "return", "in", "not", "and", "or", "is", "await", "yield",
        "assert", "with", "catch", "case", "guard", "when", "match", "until", "unless", "new", "import", "from",
        "as", "do", "then", "lambda", "raise", "except", "throw", "of", "to",
    ]

    /// Statement keywords that can stand right before a call ("return parse (line)", "await fetch (url)").
    static let callLeaders: Set<String> = [
        "return", "await", "yield", "not", "and", "or", "in", "is", "if", "elif", "while", "assert", "raise",
        "else", "new", "throw", "lambda", "case",
    ]

    /// Subject pronouns: "we slash prices" is the verb, never a path part.
    static let subjects: Set<String> = ["i", "we", "you", "they", "he", "she", "who", "what", "which"]

    /// Commands that take a directory: the word after one is a path, so a "slash" after it is a separator
    /// even where an ordinary word follows ("cd logs slash and then ls"). A closed table of shell commands.
    static let directoryCommands: Set<String> = [
        "cd", "ls", "mkdir", "rmdir", "rm", "cp", "mv", "cat", "tree", "touch", "du", "chmod", "chown", "open",
        "find", "rsync", "scp", "pushd", "stat", "zip", "unzip", "tar", "code",
    ]

    /// Spoken separators that join the parts of a name or a path.
    static let separators: Set<String> = ["slash", "dot", "dash", "underscore"]

    /// Commands whose next word is a file, a directory or a name that may be hyphenated.
    static let nameTakers: Set<String> = directoryCommands.union([
        "install", "checkout", "branch", "clone", "import", "from", "switch",
    ])

    /// After "slash" these show it is the key or the mark, not a path separator ("the slash key").
    static let slashNounFollowers: Set<String> = [
        "key", "keys", "character", "symbol", "command", "commands", "mark", "fiction", "escape",
    ]
}
