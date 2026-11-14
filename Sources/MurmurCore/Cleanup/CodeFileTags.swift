import Foundation

/// Turns a spoken file reference into an "@name.ext" tag, matching how Cursor/Windsurf chat
/// resolves a file mention: "at index dot tsx" or "tag file index tsx" -> "@index.tsx".
///
/// Only fires when the named file actually exists in the project vocabulary (see
/// `ProjectVocabulary.matchFile`) — otherwise "at" and "tag file" are common enough words/phrases
/// in ordinary dictation ("I'll be at index", "tag file as reviewed") that guessing would corrupt
/// far more sentences than it helps. By the time this runs, `CodeSymbols` has already turned a
/// spoken "dot" into a literal "." (see `TextCleaner.clean`'s ordering), so the candidate name
/// already looks like "index.tsx" or "index tsx" (extension still separated by a space when the
/// speaker said the extension as a second word without "dot").
enum CodeFileTags {
    /// Matches "at <candidate>" or "tag file <candidate>", where `<candidate>` is a short
    /// run of words/digits/dots that could plausibly be a file name (bounded to a handful of
    /// tokens so it can't run away and swallow the rest of an unrelated sentence).
    private static let pattern = "\\b(?:at|tag file)\\s+([a-zA-Z0-9]+(?:[. ][a-zA-Z0-9]+){1,3})\\b"

    static func apply(_ text: String, vocabulary: ProjectVocabulary) -> String {
        guard !vocabulary.fileNames.isEmpty else { return text }
        return Regex.replace(text, pattern) { whole, groups in
            guard groups.count >= 2 else { return whole }
            guard let tag = resolvedTag(for: groups[1], in: vocabulary) else { return whole }
            return "@\(tag)"
        }
    }

    /// Tries the candidate as spoken first ("index.tsx"), then with its last space turned into a
    /// dot ("index tsx" -> "index.tsx") for a speaker who said the extension as a separate word
    /// without an explicit "dot" — `CodeSymbols` already converts an explicit "dot" upstream.
    private static func resolvedTag(for candidate: String, in vocabulary: ProjectVocabulary) -> String? {
        if let match = vocabulary.matchFile(candidate) { return match }
        guard let lastSpace = candidate.range(of: " ", options: .backwards) else { return nil }
        let joined = candidate.replacingCharacters(in: lastSpace, with: ".")
        return vocabulary.matchFile(joined)
    }
}
