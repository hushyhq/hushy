import Foundation

/// What became of one pasted dictation as far as learning from the person's edits goes: one log
/// line per dictation, so "why did that edit teach nothing?" can be answered from the log alone.
///
/// Like `PasteDiagnosis`, it carries fixed words, numbers and the app's bundle id (cut down to
/// letters, digits, dots and hyphens) and nothing else: never a word that was spoken or typed, a
/// field's value, a window title or a learned term.
public struct LearningDiagnosis: Sendable, Equatable {
    public enum NotWatched: String, Sendable, Equatable {
        /// The dictation was not saved, so there is nothing to tie a verdict to.
        case notSaved = "not-saved"
        /// It was not pasted (copied instead, cancelled, held for a password field).
        case notInserted = "not-inserted"
        /// A spoken "press return" followed the paste: the field is gone by the first look.
        case spokenReturn = "spoken-return"
    }

    public enum Stopped: String, Sendable, Equatable {
        /// The watcher was cancelled.
        case cancelled
        /// The dictation was deleted, retried or pasted again while it was watched.
        case superseded
        /// There was no edit-observation record for the dictation.
        case noRecord = "no-record"
        /// The watcher ended before its verdict look.
        case noVerdict = "no-verdict"
    }

    public enum NotLearning: String, Sendable, Equatable {
        /// Learning was switched off, or the app excluded, while the watcher waited.
        case switchedOff = "switched-off"
        /// The caller asked for the verdict only.
        case notAsked = "not-asked"
    }

    public enum Outcome: Sendable, Equatable {
        case notWatched(NotWatched)
        case stopped(Stopped)
        case refused(LearningRefusal)
        case notLearning(NotLearning)
        /// No look could read the field. `atLook` is the first look that failed (1 is the first);
        /// nil means there was no field to look at from the start.
        case unreadable(atLook: Int?)
        /// Every readable look still held the dictation as typed.
        case noChange
        case dropped(CorrectionDrop)
        /// A change was understood but nothing was written.
        case notRecorded(CorrectionRecord.Skip)
        /// Written, not yet used: `seen` of the `needed` edits that put it into use.
        case candidate(items: Int, seen: Int, needed: Int)
        case learned(items: Int)
        case kept(items: Int, learned: Int = 0, reactivated: Int = 0)
        /// The same fix to something already in use: noted, nothing new.
        case alreadyLearned(items: Int)
        /// Writing failed (the error itself is logged separately, at error level).
        case failed
    }

    public var bundleID: String?
    public var outcome: Outcome
    /// The verdict look's answer (`DictationEditObservation.Verdict`/`Coverage` raw values), once taken.
    public var verdict: String?
    public var coverage: String?
    /// Looks taken at the field, and how many of them read text.
    public var looks = 0
    public var readable = 0
    /// Of the looks, how many the field's own change reports asked for, and how many of those held the text the
    /// moment before the field emptied (a chat box sending). Both are left off the line while there were none.
    public var changeLooks = 0
    public var beforeClear = 0
    /// Before-and-after pairs kept in memory (only when memory is on in this build).
    public var pairs: Int?

    public init(bundleID: String?, outcome: Outcome) {
        self.bundleID = bundleID
        self.outcome = outcome
    }

    /// The log line.
    public var line: String {
        var parts = ["learning", "app=\(PasteDiagnosis.bundleToken(bundleID))"] + outcomeTokens
        if let verdict { parts.append("verdict=\(PasteDiagnosis.identifier(verdict))") }
        if let coverage { parts.append("coverage=\(PasteDiagnosis.identifier(coverage))") }
        if case .notWatched = outcome { return parts.joined(separator: " ") }
        parts += ["looks=\(looks)", "readable=\(readable)"]
        if changeLooks > 0 { parts += ["on-change=\(changeLooks)", "before-clear=\(beforeClear)"] }
        if let pairs { parts.append("pairs=\(pairs)") }
        return parts.joined(separator: " ")
    }

    private var outcomeTokens: [String] {
        switch outcome {
        case .notWatched(let why): ["result=not-watched", "why=\(why.rawValue)"]
        case .stopped(let why): ["result=stopped", "why=\(why.rawValue)"]
        case .refused(let why): ["result=refused", "why=\(Self.token(why))"]
        case .notLearning(let why): ["result=not-learning", "why=\(why.rawValue)"]
        case .unreadable(let look): ["result=unreadable", "at=\(look.map { "look-\($0)" } ?? "start")"]
        case .noChange: ["result=no-change"]
        case .dropped(let drop): ["result=dropped"] + Self.tokens(drop)
        case .notRecorded(let why): ["result=not-recorded", "why=\(why.rawValue)"]
        case .candidate(let items, let seen, let needed): ["result=candidate", "items=\(items)", "progress=\(seen)/\(needed)"]
        case .learned(let items): ["result=learned", "items=\(items)"]
        case .kept(let items, let learned, let reactivated): ["result=kept-heard", "items=\(items)", "learned=\(learned)", "reactivated=\(reactivated)"]
        case .alreadyLearned(let items): ["result=already-learned", "items=\(items)"]
        case .failed: ["result=failed"]
        }
    }

    static func token(_ refusal: LearningRefusal) -> String {
        switch refusal {
        case .disabled: "disabled"
        case .excludedApp: "excluded-app"
        case .secureField: "secure-field"
        case .denylistedApp: "denylisted-app"
        case .codeContext: "code-context"
        case .nonEnglish: "non-english"
        case .tooLate: "too-late"
        }
    }

    /// The rule that dropped a change, with the number it was judged by and the limit.
    static func tokens(_ drop: CorrectionDrop) -> [String] {
        switch drop {
        case .refused(let why): ["why=\(token(why))"]
        case .unreadable: ["why=unreadable"]
        case .unchanged: ["why=unchanged"]
        case .cleared: ["why=field-cleared"]
        case .tooFewWords(let words): ["why=few-words", "words=\(words)", "min=\(CorrectionCapture.minInsertedWords)"]
        case .notLocated: ["why=not-located"]
        case .shareChanged(let percent):
            ["why=share-changed", "share=\(percent)", "limit=\(Int(CorrectionCapture.maxChangedShare * 100))"]
        case .editRuns(let runs): ["why=edit-runs", "runs=\(runs)", "limit=\(CorrectionCapture.maxEditRuns)"]
        case .rewrite(let changes): ["why=rewrite", "changes=\(changes)"]
        case .notSettled: ["why=not-settled"]
        case .shortNoFix(let words): ["why=short-no-fix", "words=\(words)"]
        case .shortNotSettled(let words): ["why=short-not-settled", "words=\(words)", "min-looks=\(ShortDictationCapture.minStableReads)"]
        }
    }
}
