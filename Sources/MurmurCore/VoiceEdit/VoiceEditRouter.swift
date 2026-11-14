import Foundation

/// Reads what the words spoken over a selection look like, before any model runs.
///
/// The router never edits anything. It answers one cheap question: could these words be an
/// instruction about the selection at all? Words with no sign of one ("Thanks, see you at nine")
/// are dictated over the selection at once, with no model call and no added wait. Words that could
/// be one go to the model, which decides (`VoiceEditor`, the `kind` field) — so the rules only ever
/// skip the model for plain dictation, and never decide that something is an edit.
///
/// Cost: one pass over the spoken words plus a set lookup per word of the selection, O(n + m).
public struct VoiceEditSignals: Sendable, Equatable {
    /// The words begin with an editing verb ("make", "change", "fix", "turn", "rewrite"…) after any
    /// "please", "can you", "Hushy".
    public var opener: Bool
    /// The words are only a target style ("shorter", "more professional", "in bullet points").
    public var styleOnly: Bool
    /// The words point at the selection ("this", "it", "the paragraph").
    public var pointsAtSelection: Bool
    /// A word of three letters or more, other than the verb, also appears in the selection.
    public var quotesSelection: Bool
    /// A common dictation start that only looks like an editing verb ("make sure", "change of plans").
    public var dictationIdiom: Bool
    public var words: Int

    /// Instructions are short. Longer speech over a selection is new text.
    public static let longestInstruction = 30

    /// Whether the model should be asked. False means: dictate over the selection.
    public var mightBeInstruction: Bool {
        guard words > 0, words <= Self.longestInstruction, !dictationIdiom else { return false }
        return opener || styleOnly
    }

    /// The rules-only answer, kept for measurement (`murmur-eval voice-edit --detector rules`): an
    /// opener or a style, and something that ties the words to the selection or keeps them short.
    public var rulesAnswer: SpokenOverSelection {
        guard mightBeInstruction else { return .replacement }
        if styleOnly || pointsAtSelection || quotesSelection || words <= 6 { return .instruction }
        return .replacement
    }
}

public enum VoiceEditRouter {
    public static func signals(spoken: String, selection: String) -> VoiceEditSignals {
        let all = tokens(spoken)
        var rest = all[...]
        while let first = rest.first, leadIns.contains(first) { rest = rest.dropFirst() }
        if rest.starts(with: ["can", "you"]) || rest.starts(with: ["could", "you"]) || rest.starts(with: ["would", "you"]) {
            rest = rest.dropFirst(2)
            while let first = rest.first, leadIns.contains(first) { rest = rest.dropFirst() }
        }
        let head = Array(rest)
        let opener = head.first.map(editVerbs.contains) ?? false
        let pair = head.prefix(2).joined(separator: " ")
        let idiom = dictationIdioms.contains(pair) || (head.first.map { dictationOpeners.contains($0) } ?? false)
        let styleOnly = !head.isEmpty && head.count <= 6 && isStyleOnly(head)
        let pointing = all.contains { pointers.contains($0) }
            || all.joined(separator: " ").range(of: pointerPhrases, options: .regularExpression) != nil
        let selected = Set(tokens(selection))
        let quoted = head.dropFirst().contains { $0.count >= 3 && !fillerWords.contains($0) && selected.contains($0) }
        return VoiceEditSignals(opener: opener, styleOnly: styleOnly, pointsAtSelection: pointing,
                                quotesSelection: quoted, dictationIdiom: idiom, words: all.count)
    }

    /// Lowercased words, apostrophes kept inside words.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private static func isStyleOnly(_ head: [String]) -> Bool {
        let words = head.filter { !styleGlue.contains($0) }
        guard !words.isEmpty else { return false }
        return words.allSatisfy { styleWords.contains($0) }
    }

    static let leadIns: Set<String> = ["please", "hushy", "ok", "okay", "now", "just", "hey", "um", "uh", "so", "and", "also"]

    static let editVerbs: Set<String> = [
        "make", "change", "replace", "swap", "fix", "correct", "turn", "rewrite", "rephrase", "reword",
        "shorten", "lengthen", "expand", "simplify", "summarize", "summarise", "translate", "convert",
        "format", "capitalize", "capitalise", "lowercase", "uppercase", "remove", "delete", "drop", "cut",
        "add", "insert", "put", "spell", "polish", "tighten", "clean", "proofread", "edit", "trim", "split",
        "merge", "combine", "reorder", "sort", "number", "tone", "soften", "condense", "redo",
    ]

    /// Two-word starts that are ordinary sentences, not instructions.
    static let dictationIdioms: Set<String> = [
        "make sure", "change of", "change is", "turn left", "turn right", "add on", "put simply",
        "drop me", "drop by", "number one", "sort of", "fix is", "edit is", "cut off",
    ]

    /// First words that start ordinary sentences even after "please" ("please find attached…").
    static let dictationOpeners: Set<String> = ["find", "see", "let", "thanks", "thank", "hi", "hello", "dear"]

    static let pointers: Set<String> = [
        "this", "it", "that", "these", "those", "selection", "selected", "paragraph", "sentence", "sentences",
        "text", "email", "message", "everything", "word", "words", "line", "lines", "list", "bullets", "title",
    ]
    static let pointerPhrases = "\\b(all of it|the whole thing|the above)\\b"

    static let styleWords: Set<String> = [
        "shorter", "longer", "short", "concise", "briefer", "professional", "formal", "casual", "friendlier",
        "friendly", "warmer", "politer", "polite", "clearer", "simpler", "punchier", "nicer", "softer", "firmer",
        "bullet", "bullets", "points", "list", "numbered", "spanish", "french", "german", "hindi", "english",
        "italian", "portuguese", "japanese", "chinese", "uppercase", "lowercase", "caps", "title", "case",
        "paragraph", "paragraphs", "grammar", "tone", "less", "more", "much", "bit", "little", "way", "too",
    ]
    static let styleGlue: Set<String> = ["a", "in", "as", "into", "to", "the", "and", "but", "with", "please", "make", "it", "this"]

    /// Short words that tie nothing to the selection even when they appear in it.
    static let fillerWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "into", "from", "more", "less", "word", "words", "all",
        "make", "sound", "into", "bit", "way", "please", "instead", "just", "also", "then",
    ]
}
