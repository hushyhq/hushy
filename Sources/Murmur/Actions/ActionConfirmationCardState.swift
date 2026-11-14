import Foundation
import MurmurCore

/// One row in the multi-intent confirmation card — one proposed action plus its own
/// confirm/edit/cancel/execution state, independent of every other row (product-owner decision:
/// "each shown as its own row in one confirmation card, each individually confirmable").
struct ActionConfirmationRow: Identifiable, Equatable {
    enum RowStatus: Equatable {
        case pending
        case confirming
        case succeeded(undoToken: ActionUndoToken?)
        /// Nothing happened and trying again can work: Retry is offered.
        case failed(String)
        /// It may have happened and Hushy can't tell (a Shortcut that timed out). No Retry: a
        /// second run could do it twice. The line says it may already have run.
        case uncertain(String)
        /// Refused before anything happened because a detail is missing or doesn't exist (an
        /// event with no time, a calendar that isn't there). No Retry: repeating can't succeed.
        case blocked(String)
        case cancelled

        /// The line under the title for any of the three that didn't go through.
        var problemLine: String? {
            switch self {
            case .failed(let line), .uncertain(let line), .blocked(let line): line
            case .pending, .confirming, .succeeded, .cancelled: nil
            }
        }

        /// Whether the row may be sent to the executor again (Retry, or ⏎): never after an
        /// uncertain run or a refusal, only when nothing happened and the action is complete.
        var canRunAgain: Bool {
            switch self {
            case .pending, .failed: true
            case .confirming, .succeeded, .uncertain, .blocked, .cancelled: false
            }
        }
    }

    let id: UUID
    var action: ProposedAction
    var status: RowStatus = .pending
    /// Where Hushy put it when it chose the place (the default calendar or list); shown on the
    /// result so nothing it filled in is hidden.
    var placedIn: String?

    /// A short line under the title in place of the usual detail while the row is pending
    /// ("Heard “wen”" on the first "Did you mean…" row). Never replaces a failure reason.
    var hint: String?

    /// The one-step way forward a refused row offers: a list or calendar that isn't there can be
    /// swapped for the default, but only on the person's tick (`VoiceActionsController.acceptOffer`).
    /// Nil once it is taken or dismissed, and for every refusal Hushy has no way forward for.
    var offer: ActionRecovery?
    /// The offer while it is still a question: only a refused row asks one.
    var openOffer: ActionRecovery? {
        if case .blocked = status { offer } else { nil }
    }
    /// History's record of the refused attempt the offer recovers. What comes of taking the offer
    /// is written over it, so one request ends as one row.
    var recoveryRecordID: Int64?

    init(action: ProposedAction, hint: String? = nil) {
        id = action.id
        self.action = action
        self.hint = hint
        // An action that is missing something it can't run without says so on its own row,
        // before the person taps anything (`ActionPreflight`).
        if let problem = ActionPreflight.problem(in: action) {
            status = .blocked(ActionWording.line(for: problem))
        }
    }

    var isResolved: Bool {
        switch status {
        case .succeeded, .cancelled: true
        case .pending, .confirming, .failed, .uncertain, .blocked: false
        }
    }

    /// The executor refused or failed this row: the plain line, and the offer when there is one.
    /// `recordID` is History's note of the attempt.
    @MainActor
    mutating func refuse(_ error: Error, recordID: Int64?) {
        status = VoiceActionsController.rowStatus(for: error)
        offer = (error as? ActionExecutionError).flatMap(ActionRecovery.init(for:))
        if offer != nil { recoveryRecordID = recordID }
    }
}

/// The pill's Action-mode confirmation card: the utterance that triggered it, plus one row per
/// extracted action (1–3 per the product-owner's multi-intent decision). The card stays up until
/// every row is resolved (confirmed-and-executed, edited-then-confirmed, or dismissed) — never
/// auto-confirms on a timeout (docs/research/voice-actions.md §4.1, and explicit in the brief).
struct ActionConfirmationCardState: Equatable {
    var rows: [ActionConfirmationRow]
    /// Index of the row focused for keyboard navigation (Tab/arrow keys select a row; Return
    /// confirms all pending rows at once per the brief's "Return = confirm all" shortcut).
    var focusedIndex: Int = 0
    /// Set when the rows are alternatives for one thing that was heard ("Did you mean…"): the
    /// words as heard. Picking one row settles the others (`settleChoice(afterOpening:)`).
    private(set) var heardForChoice: String?

    init(actions: [ProposedAction]) {
        rows = actions.map { ActionConfirmationRow(action: $0) }
    }

    var isChoice: Bool { heardForChoice != nil }

    var allResolved: Bool { rows.allSatisfy(\.isResolved) }

    /// Nothing is pending, running or asked, and at least one row failed: the card is a failure
    /// toast ("Couldn't find … · Retry ✕"), which esc closes and which clears itself after a
    /// while. A refused row whose question is still open (`openOffer`) keeps the card, like a
    /// pending row; once that row is dismissed or its offer taken, it no longer does.
    var isFailureToast: Bool {
        var failed = false
        for row in rows {
            if row.openOffer != nil { return false }
            switch row.status {
            case .pending, .confirming: return false
            case .failed, .uncertain, .blocked: failed = true
            case .succeeded, .cancelled: continue
            }
        }
        return failed
    }
}

// MARK: - A list or calendar that isn't there: the default, on the person's tick

extension ActionConfirmationCardState {
    /// The one row of a card that is refused with an offer: the pill asks, ✓ takes it, and so
    /// does ⏎ while the card's first key window is open.
    var soleOfferRow: ActionConfirmationRow? {
        guard rows.count == 1, let row = rows.first, row.openOffer != nil else { return nil }
        return row
    }

    /// The card stays only because a question is open on it: a row offers the default and no row
    /// is waiting for a tick. It never clears itself (a timeout would lose the item), so it can
    /// sit for a long time: it answers keys in its first key window only, and by click after
    /// (`PillModel.keyScope(now:ownTextFieldFocused:)`).
    var waitsOnOffer: Bool {
        rows.contains { $0.openOffer != nil } && !rows.contains { $0.status == .pending }
    }
}

// MARK: - "Did you mean…": the closest installed apps instead of a dead end

extension ActionConfirmationCardState {
    /// One `.openLink` row per candidate app, closest first; the first row says what was heard.
    /// The rows name the app exactly as installed, so opening one is a sure match.
    init(choosingAmong apps: [String], heard: String, sourceText: String) {
        let actions = apps.prefix(AppNameMatcher.maxSuggestions).map {
            ProposedAction(kind: .openLink, title: "Open \($0)", appName: $0, sourceText: sourceText)
        }
        self.init(actions: actions)
        heardForChoice = heard
        guard !rows.isEmpty else { return }
        let heardText = "Heard \u{201C}\(heard)\u{201D}"
        // One candidate has no list to head, so the line itself says it is a guess.
        rows[0].hint = rows.count == 1 ? "\(heardText) · closest match" : heardText
    }

    /// Return on the card. An ordinary card confirms every pending row; a choice card opens only
    /// the closest one, since the rows are alternatives, not a list of things to do.
    var rowsToConfirmWithReturn: [ActionConfirmationRow] {
        let pending = rows.filter { $0.status == .pending }
        return isChoice ? Array(pending.prefix(1)) : pending
    }

    /// One alternative was opened: the others no longer apply.
    mutating func settleChoice(afterOpening id: UUID) {
        guard isChoice else { return }
        for index in rows.indices where rows[index].id != id && rows[index].status == .pending {
            rows[index].status = .cancelled
        }
    }
}
