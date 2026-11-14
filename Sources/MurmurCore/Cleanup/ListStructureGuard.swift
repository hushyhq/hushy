import Foundation

/// Safety net for the list style contract (`.claude/DECISIONS.md` 2026-09-27 "List style
/// contract", `docs/product/VOICE-AGENT-DIRECTION.md` §3.2).
///
/// The contract lives in the prompts: keep the transcript's layout — an inline series stays prose
/// and the model never adds line breaks, bullets or numbering. Lists come from the rules: the
/// signal is whatever they already turned into a list — `ListFormatter`'s ordinals ("first, …
/// second, …"), "bullet", and introduced series ("shopping list,", "the list is:", "three
/// things:") — so a draft with list lines is signalled and one without is not. That keeps the outcome the same whether the model
/// was asked, which backend answered, or how many items were said.
///
/// This guard only fires when a model answer *adds* list structure (a "- "/"1. " item line, or
/// any line break) to a draft that had none. It never judges a signalled list, and it never
/// rewrites the answer: the rules draft is used instead and the log says
/// `why=rejected-by-guard(list-without-signal)`, so how often the model breaks the contract is
/// countable. Polished uses the same rule until a notes-like target class reaches
/// `CleanupOptions` (see the DECISIONS entry).
enum ListStructureGuard {
    static let reason = "list-without-signal"

    static func violation(answer: String, draft: String, allowingParagraphBreaks: Bool = false) -> String? {
        addsStructure(answer: answer, draft: draft, allowingParagraphBreaks: allowingParagraphBreaks) ? reason : nil
    }

    /// True when `answer` has list items or line breaks and `draft` had neither. With `allowingParagraphBreaks`
    /// (Task 142's paragraph experiment, off in the app) a blank line between paragraphs is not a line break
    /// that counts: only a single line break, or an item line, does.
    static func addsStructure(answer: String, draft: String, allowingParagraphBreaks: Bool = false) -> Bool {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.contains("\n"), itemLineCount(trimmedDraft) == 0 else { return false }
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if itemLineCount(trimmedAnswer) > 0 { return true }
        guard trimmedAnswer.contains("\n") else { return false }
        return !(allowingParagraphBreaks && isOnlyParagraphBreaks(trimmedAnswer))
    }

    /// Require sentence boundaries and at least six words of prose on both sides. One final
    /// standalone sign-off word is allowed after prose; allowing two words would also admit
    /// a short item such as "Red apples." after an otherwise valid paragraph.
    /// Word identity is checked separately by OutputGuard; this only classifies structure.
    static func isOnlyParagraphBreaks(_ text: String) -> Bool {
        let breaks = Regex.matches(text, "\\n+")
        guard !breaks.isEmpty, breaks.allSatisfy({ $0.range.length >= 2 }) else { return false }
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard paragraphs.count == breaks.count + 1 else { return false }
        for (index, paragraph) in paragraphs.enumerated() {
            guard let first = paragraph.first, first.isUppercase || first.isNumber else { return false }
            let body = paragraph.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
            guard let last = body.last, ".?!".contains(last) else { return false }
            guard Regex.firstMatch(paragraph, "^(?:[-•*]|[A-Za-z][.)]|\\d{1,2}[.)])\\s+") == nil else { return false }
            let words = paragraph.split(whereSeparator: \.isWhitespace).count
            let isFinalSignOff = index == paragraphs.count - 1 && words == 1 && first.isLetter
                && paragraph.count > 2 && index > 0
                && paragraphs[index - 1].split(whereSeparator: \.isWhitespace).count >= 6
            guard words >= 6 || isFinalSignOff else { return false }
        }
        return true
    }

    /// Lines that open with a bullet ("- ", "• ", "* ") or a number marker ("1. ", "2) ").
    static func itemLineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { line in
            Regex.firstMatch(line, "^\\s*(?:[-•*]|\\d{1,2}[.)])\\s+\\S") != nil
        }.count
    }
}
