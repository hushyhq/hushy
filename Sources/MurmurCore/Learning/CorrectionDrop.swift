import Foundation

/// Why the looks at a field taught nothing. Fixed words and numbers only: never a word that was
/// spoken or typed.
public enum CorrectionDrop: Sendable, Equatable {
    /// The learning gate refused (here that is a look taken too long after the paste).
    case refused(LearningRefusal)
    /// No look could read the field's text.
    case unreadable
    /// The dictation was still there as typed.
    case unchanged
    /// The field was empty: sent or cleared before a look saw a change.
    case cleared
    /// Fewer words than `CorrectionCapture.minInsertedWords`.
    case tooFewWords(Int)
    /// The dictation could not be found in what the field held (under 60% of its words left in
    /// order, a field too long to search, or other text in its place).
    case notLocated
    /// More of the dictation changed than `CorrectionCapture.maxChangedShare`: a rewrite.
    case shareChanged(percent: Int)
    /// More separate changes than `CorrectionCapture.maxEditRuns`.
    case editRuns(Int)
    /// Every change read as a rewrite (an ordinary word for another), which is never learned.
    case rewrite(changes: Int)
    /// The only fix was a word the person was still typing: the look before showed that word with a
    /// different spelling, and no later look showed it finished.
    case notSettled
    /// A dictation of one or two words whose change was not the one shape learned from: one
    /// word for one word that reads as misheard, the text around it untouched, and an earlier
    /// look that held the dictation exactly once.
    case shortNoFix(words: Int)
    /// A dictation of one or two words whose fix was seen on too few looks, or was undone.
    case shortNotSettled(words: Int)
}

/// What the looks at a field gave: something to learn from, or the reason there was nothing.
public enum CorrectionDerivation: Sendable, Equatable {
    case capture(CorrectionCapture)
    case dropped(CorrectionDrop)

    public var capture: CorrectionCapture? {
        if case .capture(let capture) = self { return capture }
        return nil
    }
}
