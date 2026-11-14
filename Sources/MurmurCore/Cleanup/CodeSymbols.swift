import Foundation

/// Spoken words for punctuation that reads naturally in speech but must type as a symbol in
/// code: "dot" -> ".", "open paren"/"close paren" -> "(" / ")", "arrow" -> "->". Only meaningful
/// in a code context (see `CleanupOptions.isCodeContext`); in prose "dot" and "arrow" are
/// ordinary words, and a code editor still gets ordinary sentences ("the dot on the map",
/// "the arrow points left"): `CodeDotArrow` keeps those words.
enum CodeSymbols {
    static func apply(_ text: String) -> String {
        var out = openParens(text)
        // A closing paren keeps one space before a following word ("(x) then y"), but still
        // collapses before punctuation and at the end ("(x).name", "(x)").
        out = Regex.replace(out, "\\s*\\bclose paren(?:thesis)?\\b\\s+(?=[A-Za-z0-9]|=>)", with: ") ")
        out = Regex.replace(out, "\\s*\\bclose paren(?:thesis)?\\b\\s*", with: ")")
        return CodeDotArrow.apply(out)
    }

    /// Keeps exactly one leading space when the match isn't at the very start of the text, so a call
    /// still reads "get user (id)", not "get user(id", but never a trailing space, so the argument sticks
    /// to it. After another opener there is no space at all ("[(a)]", "((a))"): the previous character is
    /// an opening bracket, so the new one belongs right against it. Repeats because a run of openers
    /// ("open paren open paren") leaves the second one without a character before it in the same pass.
    private static func openParens(_ text: String) -> String {
        var out = text
        for _ in 0..<4 {
            let next = Regex.replace(out, "(^|\\S)\\s*\\bopen paren(?:thesis)?\\b\\s*") { _, groups in
                let before = groups.count > 1 ? groups[1] : ""
                if before.isEmpty { return "(" }
                return openers.contains(before) ? "\(before)(" : "\(before) ("
            }
            if next == out { break }
            out = next
        }
        return out
    }

    private static let openers: Set<String> = ["(", "[", "{"]
}
