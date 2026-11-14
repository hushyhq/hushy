import Foundation

/// Which tokens of a text name something in code: the shape `CanonicalTypedGuard` reads when it compares the typed
/// paths and file names of an answer with what was said.
///
/// A named-code token holds a letter and is a flag (`--parallel`, `-m`), has a dot, a slash or an underscore inside it
/// (`auth.swift`, `src/utils`, `user_id`), or has a capital after its first letter in a word that also has a lowercase
/// letter (`getUserById`). A bare number, a decimal, a hyphenated word, a contraction and an acronym are not.
///
/// This used to be a guard on the answer of a prose app that "reads code" (the Claude desktop app). It is not any more:
/// the AI apps are where people dictate prompts in plain English, so they are prose apps with full cleanup, and a
/// word such as "GitHub" or "PRs" in the model's answer must not refuse it (founder, 2026-10-23).
enum CodeTokenGuard {
    private static let trailingPunctuation = Set(".,!?;:\"')]}")
    private static let leadingPunctuation = Set("\"'([{")

    /// The named-code tokens of `text`, in order, without the punctuation around them.
    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            var core = Substring(piece)
            while let last = core.last, trailingPunctuation.contains(last) { core = core.dropLast() }
            while let first = core.first, leadingPunctuation.contains(first) { core = core.dropFirst() }
            return isNamedCode(String(core)) ? String(core) : nil
        }
    }

    static func isNamedCode(_ token: String) -> Bool {
        guard token.contains(where: \.isLetter), !token.contains("`") else { return false }
        if token.hasPrefix("-"), token.dropFirst().drop(while: { $0 == "-" }).first?.isLetter == true { return true }
        let characters = Array(token)
        let hasJoiner = characters.indices.contains { index in
            guard "._/".contains(characters[index]), index > 0, index + 1 < characters.count else { return false }
            let before = characters[index - 1], after = characters[index + 1]
            return (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
        }
        return hasJoiner || token.dropFirst().contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
    }
}
