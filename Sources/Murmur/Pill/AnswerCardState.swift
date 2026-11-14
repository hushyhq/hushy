import Foundation
import MurmurCore

/// The pill's answer card (ask your own stuff, summarize this): the question, then one of
/// thinking → an answer with its source → or a plain failure; and, while the card is open, a
/// voice follow-up that glows and listens (`.listening`) and continues the thread.
struct AnswerCardState: Equatable {
    enum Phase: Equatable {
        /// The model is working (purple shimmer in the footer).
        case thinking
        /// The answer is up.
        case answer(AnswerContent)
        /// "I couldn't find a grocery list." with a next step.
        case failure(AnswerFailureContent)
        /// Files found on this Mac (`FileFindEngine`): one, or a short list to pick from.
        case files(FileResultsContent)
        /// The chord is held while the card is open: lime rim, bars, the thread continues.
        case listening
    }

    /// What the card shows once there is an answer.
    struct AnswerContent: Equatable {
        var text: String
        var items: [String]
        /// "From your note 'Groceries' · Sep 26", or "Safari · 1,240 words" for a screen summary.
        var sourceLabel: String
        /// Where "Open source" goes: a Hushy note id, an app, or nothing (a screen summary).
        var sourceLink: SourceLink?
        /// True for a screen summary: no "Save as note"? No — saving a summary is useful; this
        /// only changes the glyph (viewfinder) and the source verb ("Show window").
        var isScreenSummary = false

        enum SourceLink: Equatable {
            case note(id: Int64)
            case url(URL)
        }

        /// The source is a Hushy note, which release builds cannot open (`FeatureFlags.meetings`).
        var sourceIsNote: Bool {
            if case .note = sourceLink { return true }
            return false
        }
    }

    struct AnswerFailureContent: Equatable {
        var message: String
        /// "Search Apple Notes?" — an offer the user can take with one tap, or nil.
        var suggestion: String?
        /// The offer runs the heard words through the action extractor again ("Try again"), rather
        /// than turning on Apple Notes.
        var retriesAction = false
    }

    /// The latest question (or the follow-up being asked).
    var question: String
    var phase: Phase
    /// Earlier turns of this thread, oldest first; the model sees the last three.
    var thread: [AskTurn] = []
    /// Copy was tapped: the card says "Copied" for a moment, then collapses.
    var copied = false
    /// What the shimmer row says while the model or the search works.
    var thinkingLabel = "Looking through your notes…"

    /// The card after "Search Apple Notes?" was refused: the same question, now saying why in the
    /// words `AppleNotesAccessNotice` uses, with the one tap left to try again.
    func refusedNotesAccess(_ result: AppleNotesAccessResult) -> AnswerCardState {
        var card = self
        card.phase = .failure(.init(message: result.message, suggestion: Self.tryAgain))
        return card
    }

    static let tryAgain = "Try again"

    var isThinking: Bool { phase == .thinking }
    var isListening: Bool { phase == .listening }

    var answer: AnswerContent? {
        if case .answer(let content) = phase { return content }
        return nil
    }

    /// Answer text plus items as lines, for Copy and Save as note.
    var copyText: String {
        guard let answer else { return "" }
        var lines = [answer.text]
        lines += answer.items.map { "- \($0)" }
        lines.append("— \(answer.sourceLabel)")
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Rough height for the panel (the card lays itself out; this just reserves room).
    var estimatedHeight: CGFloat {
        let base: CGFloat = 96
        switch phase {
        case .thinking, .listening: return base
        case .failure: return base + 12
        case .files(let content): return base + 18 + CGFloat(content.rows.count) * 44 + (content.rows.count == 1 ? 24 : 0)
        case .answer(let content):
            let textLines = CGFloat(max(1, (content.text.count + 55) / 56))
            return base + textLines * 17 + CGFloat(min(content.items.count, 8)) * 18 + (content.items.isEmpty ? 0 : 6)
        }
    }

    /// VoiceOver.
    var accessibilityText: String {
        switch phase {
        case .thinking: "Thinking about: \(question)"
        case .listening: "Listening for a follow-up"
        case .failure(let failure): failure.message
        case .files(let content): content.accessibilityText
        case .answer(let content): "\(content.text) \(content.items.joined(separator: ", ")). \(content.sourceLabel)"
        }
    }
}

/// "Added: Call Dana · Fri 9:00 · Undo": a Tier-1 action that already happened. Self-dismisses
/// after `ActionUndoWindow` seconds; Undo really reverts (deletes the reminder or event) and reads
/// "Undone". A practice chip (the voice-action practice in Settings) says "Would add: …" and has no Undo.
struct DoneChipState: Equatable {
    var title: String
    var detail: String?
    var kind: ProposedAction.Kind
    /// The record to undo, when the backend can (EventKit yes; links and Shortcuts no).
    var undoRecordID: Int64?
    /// True only once the item was really removed. Never set before the delete has succeeded.
    var undone = false
    /// The delete is running: the chip reads "Undoing…", neither done nor failed.
    var isUndoing = false
    /// Why the last Undo didn't work ("Couldn't undo. The event is still in Calendar."). The item
    /// is still there, so Undo is offered again.
    var undoFailure: String?
    /// The voice-action practice: nothing was created, so the title says what would happen and the
    /// chip never offers Undo.
    var isPractice = false

    var canUndo: Bool { undoRecordID != nil && !undone && !isUndoing && !isPractice }

    var accessibilityText: String {
        if undone { return "Undone." }
        if isUndoing { return "Undoing." }
        if let undoFailure { return "\(undoFailure) Undo available." }
        let line = [title, detail].compactMap { $0 }.joined(separator: ", ")
        if isPractice { return "Practice. \(line). Nothing was added." }
        return canUndo ? "\(line). Undo available." : line
    }
}
