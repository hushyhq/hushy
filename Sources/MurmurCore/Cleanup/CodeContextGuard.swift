import Foundation

/// What a model rewrite may not change in text dictated into a code editor or terminal.
///
/// A code app gets the same grammar repair as anywhere else (see `ToneSettings.plan`), but part of what is
/// said there is code: a command, a flag, a path, an identifier, a version, a quoted string. The rules draft
/// already wrote those the way they are typed (`CodeSymbolGrammar`, `CasingCommands`, `CodeFileTags`) and, in a code
/// app, left the capital and the final stop off (`TextCleaner`). The model must hand code back exactly. This guard
/// reads the draft by shape, one line at a time, never by a list of words or commands:
///
/// - A line that is a command or a statement stays exactly as the rules draft has it. A line is a **statement** when
///   it holds an operator on its own (`=`, `==`, `=>`, `->`, `&&`, `+=`) or ends in `;`, `{` or `}`. A line is a
///   **command** when it does not read as a sentence: outside quoted spans and code-shaped tokens it holds no word
///   from a closed grammatical class (articles and determiners, pronouns, auxiliaries and the copula, question words,
///   negation, prepositions and conjunctions, subordinators) and no contraction. Those sets are the ones the cleanup
///   code already has (`closedClasses`). When a line is unclear it reads as a command, because the cost of that is a
///   missed repair and the cost of the other mistake is a changed command.
/// - In any other line (prose), a quoted string or a backtick span in the draft appears in the answer unchanged.
/// - In a prose line a token that is code-shaped appears in the answer unchanged, in the same order, and the answer holds
///   no code-shaped token the draft did not (a new identifier, a digit, a hyphenated word, a quote, a bracket). A token
///   is code-shaped when it holds a digit, a symbol (`_ - / \ . : ; = < > ( ) [ ] { } @ # $ % ^ & * + | ~ ` or a quote), a
///   capital letter after its first letter (camelCase, PascalCase, an acronym), or an apostrophe that is not inside a word.
///   A newcomer is allowed when it only writes out words the line said, as they are typed (`writtenForm`: "use effect" to
///   `useEffect`, "node_env" to `NODE_ENV`, "TRY95" to `TRY-95`), the same repair the model makes in any other app; and an
///   acronym the model capitalises ("csv" to "CSV", "prs" to "PRs"), because the draft held the word. Before 2026-11-11
///   every newcomer was refused, and 128 of 171 Terminal fallbacks in the accuracy eval were correct identifier repairs.
/// - The answer has the line breaks the draft has, and each protected token is checked in its own line.
///
/// Everything else is prose and the model may repair it: fillers, restarts, run-ons, grammar, capitals, the final stop.
/// Its objection is "changed code-context text", a local check: `SpanRepair` puts back only the span at fault and keeps
/// the rest of the answer.
///
/// Known limits, kept on purpose:
/// - A line ending in a semicolon is a statement even when it is prose, so it gets no repair.
/// - A full stop, comma, question mark or exclamation mark after a protected token in a prose line is allowed (a sentence
///   ends there), so `build/cache.` passes where `build/cache` was dictated.
/// - Inside one prose line a protected token is bound to the line, not to its sentence, and an identical token that
///   appears twice can swap places.
/// - A command written as a sentence ("check the logs") is prose, and a plain-word command that happens to hold a
///   closed-class word (a shell `for ... in`, `if ... then`) is read as prose.
/// - A plain-word command inside a prose line ("run git push origin main, then check the logs") is protected only
///   through its code-shaped tokens.
public enum CodeContextGuard {
    /// The reason carries no text: the dictation may be private code.
    static let reason = "changed code-context text"

    private static let symbols = Set("_-/\\.:;=<>()[]{}@#$%^&*+|~`\"")
    private static let operators = Set("=<>+*/%&|^~")
    private static let trailingPunctuation = Set(".,!?")
    private static let edgePunctuation = Set(".,!?;:\"'()[]{}")

    /// The closed grammatical classes, from the sets the cleanup code already keeps: determiners and function words
    /// (`CodeSymbolWords.functionWords`), pronouns (`QuestionPunctuation.pronounSubjects`), auxiliaries
    /// (`QuestionPunctuation.auxiliaries`), question words (`QuestionPunctuation.whWords`), negation
    /// (`CriticalTokenGuard.negationWords`) and subordinators (`RetractionGuard.notAnItem`).
    static let closedClasses: Set<String> = CodeSymbolWords.functionWords
        .union(QuestionPunctuation.pronounSubjects).union(QuestionPunctuation.auxiliaries)
        .union(QuestionPunctuation.whWords).union(CriticalTokenGuard.negationWords).union(RetractionGuard.notAnItem)

    // MARK: Reading a line

    /// True when the line is a command or a statement: the model gets none of it to rewrite.
    public static func readsAsCommand(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && (isStatement(trimmed) || !readsAsSentence(trimmed))
    }

    static func readsAsSentence(_ line: String) -> Bool {
        var outside = line
        for span in literalSpans(in: line) { outside = outside.replacingOccurrences(of: span, with: " ") }
        return outside.split(whereSeparator: \.isWhitespace).contains { piece in
            let word = String(piece).trimmingCharacters(in: CharacterSet(charactersIn: String(edgePunctuation)))
            guard !word.isEmpty, !isCodeShaped(trimmedOfSentencePunctuation(String(piece))) else { return false }
            return closedClasses.contains(word.lowercased()) || word.dropFirst().contains("'") && !word.hasSuffix("'")
        }
    }

    static func isStatement(_ line: String) -> Bool {
        if let last = line.last, ";{}".contains(last) { return true }
        var tokens = line.split(whereSeparator: \.isWhitespace)
        // A comment marker opening the line (`//`, `///`, `#`, `/*`, `*`) is not an operator: the comment is read on its own.
        if let first = tokens.first, first.count <= 3, first.allSatisfy({ "/#*".contains($0) }) { tokens.removeFirst() }
        return tokens.contains { token in
            !token.contains(where: { $0.isLetter || $0.isNumber }) && token.contains(where: operators.contains)
        }
    }

    // MARK: The check

    /// Only Polished repairs prose in a code app. Cleaned up (a mode someone chose, or a language Polished is not written
    /// for) keeps the rules draft exactly as it always has: the model's answer is used only when it changes nothing.
    static func violation(answer: String, draft: String, repairsGrammar: Bool) -> String? {
        guard repairsGrammar else { return answer == draft ? nil : reason }
        return violation(answer: answer, draft: draft)
    }

    static func violation(answer: String, draft: String) -> String? {
        let draftLines = lines(draft), answerLines = lines(answer)
        guard draftLines.count == answerLines.count else { return reason }
        for (was, now) in zip(draftLines, answerLines) where lineViolation(answer: now, draft: was) {
            return reason
        }
        return nil
    }

    private static func lines(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    }

    private static func lineViolation(answer: String, draft: String) -> Bool {
        if readsAsCommand(draft) { return answer.trimmingCharacters(in: .whitespaces) != draft.trimmingCharacters(in: .whitespaces) }
        if literalSpans(in: draft).contains(where: { !answer.contains($0) }) { return true }
        let was = tokens(in: draft), now = tokens(in: answer)
        let plainWords = Set(was.filter { !isCodeShaped($0) }.map { $0.lowercased() })
        let draftCode = Set(was.filter(isCodeShaped))
        // Spelled capitals the recogniser wrote ("PNPM") may come back as a plain lower-case word ("pnpm").
        let spelledLowered = Set(was.filter { isCodeShaped($0) && isSpelledCapitals($0) }.map { $0.lowercased() })
        // Each code-shaped token of the answer is a code-shaped token of the draft or the written form of words said there
        // (`writtenForm`), in the draft's order, and together they account for every code-shaped token of the draft.
        var position = 0
        for token in now where isCodeShaped(token) || spelledLowered.contains(token) {
            if isAcronym(token), !draftCode.contains(token), plainWords.contains(token.lowercased()) { continue }
            guard let unit = (position..<was.count).lazy.compactMap({ start -> Range<Int>? in
                was[start] == token ? start..<(start + 1) : writtenForm(token, of: was, from: start).map { start..<$0 }
            }).first else { return true }
            if was[position..<unit.lowerBound].contains(where: isCodeShaped) { return true }
            position = unit.upperBound
        }
        return was[position...].contains(where: isCodeShaped)
    }

    // MARK: Writing out what was said

    /// Words that only say a symbol inside an identifier ("node underscore env", "readme dot md"), and the symbol.
    private static let symbolWords: [String: String] = [
        "underscore": "_", "dot": ".", "dash": "-", "hyphen": "-", "slash": "/", "backslash": "\\", "colon": ":",
    ]
    /// The most draft tokens one written token may stand for.
    private static let longestSpokenRun = 6

    /// Where the run of draft tokens that `token` writes out ends, when it starts at `start`: the run's letters and digits,
    /// read in order and with the symbol words left out, are the token's own (`spokenKey`). "use effect" is `useEffect`,
    /// "node underscore env" is `NODE_ENV`, "TRY95" is `TRY-95`, "rl v9" is `rl-v9`. Nil when no run does.
    ///
    /// The draft held these words, so the model only wrote them the way they are typed, as it may anywhere else; the later
    /// checks still judge the answer as a whole. What it may not do: change a digit or the separator between two digits
    /// ("3.5" to "3,5", "2.3.1" to "2.31"), rewrite one code-shaped draft token other than as `isRespelling` allows, or
    /// change a code-shaped draft token inside a longer run.
    static func writtenForm(_ token: String, of draft: [String], from start: Int) -> Int? {
        let target = spokenKey(token)
        // A symbol word may open the run only when the token opens with that symbol ("slash api" for `/api`).
        guard !target.isEmpty, start < draft.count,
              !isSymbolWord(draft[start]) || symbolWords[draft[start].lowercased()].map({ token.hasPrefix($0) }) == true
        else { return nil }
        var said = ""
        for end in start..<min(draft.count, start + longestSpokenRun) {
            let word = draft[end]
            if !isSymbolWord(word) { said += spokenKey(word) }
            guard target.hasPrefix(said) else { return nil }
            guard said == target, !isSymbolWord(word) else { continue }
            let run = Array(draft[start...end])
            guard digitSeparators(token) == digitSeparators(run.joined(separator: " ")) else { return nil }
            if run.count == 1, isCodeShaped(word), word != token, !isRespelling(token, of: word) { return nil }
            if run.count > 1, run.contains(where: { piece in
                guard isCodeShaped(piece), !token.contains(piece) else { return false }
                guard let found = token.range(of: piece, options: .caseInsensitive) else { return true }
                // Inside a longer run only spelled capitals may change case ("slash API/V2/users" as `/api/v2/users`).
                return !isRespelling(String(token[found]), of: piece, capitalising: false)
            }) { return nil }
            return end + 1
        }
        return nil
    }

    private static func isSymbolWord(_ word: String) -> Bool { symbolWords[word.lowercased()] != nil }

    /// Letters all in capitals, as the recogniser writes spelled letters ("PNPM", "IOS", "V30").
    private static func isSpelledCapitals(_ token: String) -> Bool {
        token.contains(where: \.isLetter) && !token.contains(where: \.isLowercase)
    }

    /// The letters and digits of a token, lowercased: what saying it gives.
    static func spokenKey(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The characters between two digits, in order ("2.3.1" has ". .", "TRY-95" has none, "5 0" has a space).
    private static func digitSeparators(_ text: String) -> [String] {
        Regex.matches(text, "(?<=\\p{N})[^\\p{L}\\p{N}]+(?=\\p{N})").compactMap { $0.string(at: 0, in: text) }
    }

    /// A code-shaped draft token written another way that only says it as typed. The draft's case and symbols are the
    /// recogniser's and the rules' defaults, not the speaker's, in three ways only:
    /// - a hyphen between its letters and its digits ("TRY95" to "TRY-95", the form `CorrectionBound.lettersBesideDigits`
    ///   already reads as said);
    /// - spelled capitals in any case ("V30" to "v30", "IOS" to "iOS", "PNPM" to "pnpm", "API/V2" to "api/v2");
    /// - a lower-case run of letters in capitals ("node_env" to "NODE_ENV", "readme.md" to "README.md"), except in a path.
    /// Any other change of its case or its symbols ("--force" to "--Force", "getUserById" to "getUserByID",
    /// "parse_input.py" to "parse-input.py") is a change of code.
    private static func isRespelling(_ token: String, of word: String, capitalising: Bool = true) -> Bool {
        let unhyphenated = token.replacingOccurrences(
            of: "(?<=\\p{L})-(?=\\p{N})|(?<=\\p{N})-(?=\\p{L})", with: "", options: .regularExpression)
        if unhyphenated == word { return true }
        guard unhyphenated.count == word.count, unhyphenated.lowercased() == word.lowercased() else { return false }
        // A path keeps the file system's case ("api/v2/users" is not "API/v2/users"); spelled capitals are the recogniser's.
        let isPath = word.contains(where: { "/\\".contains($0) })
        let written = letterRuns(unhyphenated), said = letterRuns(word)
        return written.count == said.count && zip(written, said).allSatisfy { now, was in
            now == was || isSpelledCapitals(was) || (capitalising && !isPath && was == was.lowercased() && now == was.uppercased())
        }
    }

    private static func letterRuns(_ text: String) -> [String] {
        Regex.matches(text, "\\p{L}+").compactMap { $0.string(at: 0, in: text) }
    }

    /// An acronym, or its plural ("PRs", "APIs").
    private static func isAcronym(_ token: String) -> Bool {
        let stem = token.count > 2 && token.hasSuffix("s") ? String(token.dropLast()) : token
        return stem.count >= 2 && stem.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    // MARK: Tokens

    private static func trimmedOfSentencePunctuation(_ piece: String) -> String {
        var core = Substring(piece)
        while let last = core.last, trailingPunctuation.contains(last) { core = core.dropLast() }
        return String(core)
    }

    /// Whitespace-separated tokens without the sentence punctuation after them.
    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let core = trimmedOfSentencePunctuation(String(piece))
            return core.isEmpty ? nil : core
        }
    }

    static func isCodeShaped(_ token: String) -> Bool {
        if token.contains(where: \.isNumber) || token.contains(where: symbols.contains) { return true }
        if token.dropFirst().contains(where: \.isUppercase) { return true }
        let characters = Array(token)
        return characters.indices.contains { index in
            guard characters[index] == "'" || characters[index] == "\u{2018}" else { return false }
            let before = index > 0 && characters[index - 1].isLetter
            let after = index + 1 < characters.count && characters[index + 1].isLetter
            return !(before && after)
        }
    }

    /// Backtick spans, double-quoted strings and single-quoted strings that open at a word boundary.
    static func literalSpans(in text: String) -> [String] {
        let patterns = ["`[^`\\n]+`", "\"[^\"\\n]+\"", "(?<![A-Za-z0-9])'[^'\\n]+'(?![A-Za-z0-9])"]
        let whole = NSRange(text.startIndex..., in: text)
        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: whole).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }
    }
}
