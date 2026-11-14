import Foundation

/// Whether one on-screen term names something or names something in code: the only kinds of screen term worth boosting
/// for the recogniser and protecting in cleanup. Ordinary words and UI labels are neither, which keeps out the
/// 2026-10-24 swaps ("text" → "Next", "middle" → "metal").
public enum ScreenTermShape {
    public enum Kind: String, Sendable, Equatable {
        /// A person, product, place or acronym: "Siobhan", "VS Code", "Wembanyama".
        case name
        /// A code-like token: "rl-v9", "TRY-95", "gpt4o", "v2.3", "user_id", "auth.swift", "useEffect".
        case identifier
    }

    /// `.identifier` when the term is one token that holds a letter and a digit (not a quantity such as "3pm" or "1st"),
    /// or is a named-code token (`CodeTokenGuard.isNamedCode`: a joiner inside it or a capital after a lowercase letter);
    /// `.name` when it is capitalized and some word of it is not ordinary English; nil otherwise.
    public static func kind(of term: String) -> Kind? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= ContextExtractor.minTermLength, trimmed.count <= 64 else { return nil }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 1, isIdentifier(trimmed) { return .identifier }
        if words.count == 1, isAbbreviation(trimmed) { return nil }
        guard words.count <= 3, words.allSatisfy({ $0.first?.isUppercase == true }) else { return nil }
        return words.contains(where: isDistinctive) ? .name : nil
    }

    public static func isNameOrCodeLike(_ term: String) -> Bool { kind(of: term) != nil }

    /// Digits and letters inside one token, or a named-code shape. Abbreviations with a dot after every letter
    /// ("e.g.", "U.S.") are not code.
    static func isIdentifier(_ token: String) -> Bool {
        guard token.contains(where: \.isLetter) else { return false }
        if token.contains(where: \.isNumber) { return !isQuantity(token) }
        if isAbbreviation(token) { return false }
        return CodeTokenGuard.isNamedCode(token)
    }

    /// A dot after single letters: "e.g.", "U.S.".
    static func isAbbreviation(_ token: String) -> Bool {
        token.contains(".") && token.split(whereSeparator: { ".-_/".contains($0) }).allSatisfy { $0.count == 1 }
    }

    /// A number with a short unit or ordinal after it: "3pm", "1st", "90s", "10kg".
    static func isQuantity(_ token: String) -> Bool {
        let digits = token.prefix(while: \.isNumber)
        let rest = token.dropFirst(digits.count)
        return !digits.isEmpty && rest.count <= 3 && rest.allSatisfy(\.isLetter)
    }

    private static func isDistinctive(_ word: String) -> Bool {
        let key = word.lowercased()
        return !ContextExtractor.commonWordDenylist.contains(key) && !ScreenBoostPolicy.uiLabelDenylist.contains(key)
            && !LearningLexicon.isCommonWord(key)
    }
}
