import Foundation

/// An installation is evidence that a name exists, not that ordinary speech named it.
/// Keep ambiguous names out of unconditional recognition hints and cleanup protection.
public enum InstalledNamePolicy {
    // These distinctive product names are useful vocabulary even though two are dictionary words.
    private static let distinctiveNames: Set<String> = ["figma", "linear", "supabase", "obsidian"]

    public static func isOrdinary(_ name: String) -> Bool {
        let spelling = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = spelling.lowercased()
        guard !key.isEmpty, !distinctiveNames.contains(key) else { return false }
        let words = key.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        if words.count <= 2 && words.allSatisfy(LearningLexicon.isCommonWord) { return true }
        guard words.count == 1, key.allSatisfy(\.isLetter) else { return false }
        // Single-letter prefixes are product spellings (Xcode, RStudio, iTerm), even
        // when the lexicon contains the letter. Camel case must mark exactly the
        // ordinary-word boundary (TextEdit); other internal capitals stay distinctive.
        let letters = Array(key)
        let original = Array(spelling)
        let capitals = original.indices.filter { $0 > 0 && original[$0].isUppercase }
        guard letters.count >= 4 else { return false }
        return (2...letters.count - 2).contains { split in
            (capitals.isEmpty || (original.first?.isUppercase == true && capitals == [split]))
                && LearningLexicon.isCommonWord(String(letters[..<split]))
                && LearningLexicon.isCommonWord(String(letters[split...]))
        }
    }

    /// A CTC preference for an installed name is insufficient on its own. Without app
    /// syntax, require the same narrow spelling and sound evidence as the name fixer.
    static func supportsReplacement(heard: String, name: String, previous: String?, next: String?) -> Bool {
        guard !heard.isEmpty else { return false }
        if hasExplicitAppCue(previous: previous, next: next) { return true }
        guard abs(heard.count - name.count) <= 2,
              ContextSpellingFixer.levenshtein(heard, name) <= 2 else { return false }
        let heardSound = ContextSpellingFixer.phoneticKey(heard)
        let nameSound = ContextSpellingFixer.phoneticKey(name)
        return heardSound == nameSound || heardSound + "*" == nameSound || nameSound + "*" == heardSound
    }

    /// Strong app syntax with an object boundary. "Open text edit history" is a noun phrase,
    /// whereas "open text edit" plausibly names the app. A frontmost window alone is insufficient.
    static func hasExplicitAppCue(previous: String?, next: String?) -> Bool {
        if previous == "app" || next == "app" { return true }
        return previous.map { ["open", "launch", "quit"].contains($0) } == true
            && (next == nil || ["and", "then", "please"].contains(next))
    }
}
