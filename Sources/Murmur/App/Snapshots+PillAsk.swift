import MurmurCore
import SwiftUI

/// Founder review set for the answer card and the done chip (ask-actions, 2026-09-28):
/// `pill-ask-<state>` close up, and `pill-ask-anchor-<bottom|left|right>-<state>` placed on the
/// mock display so the card opens toward the centre. States: thinking, answer (a list with a
/// source), answer-text (a sentence), followup (the card open, the chord held: lime rim, bars),
/// copied, failure (with "Search Apple Notes?"), failure-refused (that offer refused by macOS), summary (a screen summary), done (the Tier-1
/// chip with Undo), done-undone.
extension Snapshots {
    static func renderPillAsk(scheme: ColorScheme, directory: URL) async {
        let levels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        for (name, state) in askStates() {
            let pill = PillModel()
            pill.state = state
            pill.setLevels(levels)
            let view = PillView(model: pill)
                .padding(40)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: "pill-ask-\(name)", scheme: scheme, size: CGSize(width: 560, height: 360),
                          directory: directory, fixedSize: true)
            for anchor in [PillAnchor.bottom, .left, .right] {
                let anchored = PillModel()
                anchored.state = state
                anchored.setLevels(levels)
                await capture(anchoredPill(anchored, at: anchor).environment(\.colorScheme, scheme),
                              name: "pill-ask-anchor-\(anchor.rawValue)-\(name)", scheme: scheme,
                              size: mockDisplay.size, directory: directory, fixedSize: true)
            }
        }
    }

    private static func askStates() -> [(String, PillState)] {
        let groceries = AnswerCardState.AnswerContent(
            text: "You need four things this weekend.",
            items: ["oat milk", "eggs", "sourdough", "coffee beans"],
            sourceLabel: "From your note 'Groceries' · Sep 26", sourceLink: .note(id: 1))
        let pricing = AnswerCardState.AnswerContent(
            text: "You decided to ship on Monday, with the release notes first. Dana owns the launch page.",
            items: [], sourceLabel: "From your note 'Launch sync' · Sep 24", sourceLink: .note(id: 2))
        let summary = AnswerCardState.AnswerContent(
            text: "A proposal to move the launch to mid-October so the pricing page and the voice-actions eval land first.",
            items: ["Launch moves from Oct 2 to Oct 16", "Pricing page needs a Teams row", "Eval bar: tool select ≥ 94%"],
            sourceLabel: "Safari · Launch plan (1,240 words)", sourceLink: nil, isScreenSummary: true)
        var followUp = AnswerCardState(question: "what about sunday", phase: .listening)
        followUp.thread = [AskTurn(question: "what groceries do i need this weekend", answer: groceries.text)]
        var copied = AnswerCardState(question: "what groceries do i need this weekend", phase: .answer(groceries))
        copied.copied = true
        return [
            ("thinking", .answer(AnswerCardState(question: "what groceries do i need this weekend", phase: .thinking))),
            ("answer", .answer(AnswerCardState(question: "what groceries do i need this weekend", phase: .answer(groceries)))),
            ("answer-text", .answer(AnswerCardState(question: "what did we decide about the launch", phase: .answer(pricing)))),
            ("followup", .answer(followUp)),
            ("copied", .answer(copied)),
            ("failure", .answer(AnswerCardState(
                question: "what groceries do i need", phase: .failure(.init(
                    message: "I couldn't find a grocery list in your notes, reminders or calendar.", suggestion: "Search Apple Notes?"))))),
            ("failure-refused", .answer(AnswerCardState(
                question: "what groceries do i need", phase: .failure(.init(message: "", suggestion: nil)))
                .refusedNotesAccess(.notPermitted))),
            ("summary", .answer(AnswerCardState(question: "summarize this", phase: .answer(summary)))),
            ("done", .actionDone(DoneChipState(title: "Added: Call Dana", detail: "Fri 9:00 AM", kind: .createReminder, undoRecordID: 1))),
            ("done-opened", .actionDone(DoneChipState(title: "Opened in Claude — press ↩", detail: "why is the sky blue", kind: .openLink))),
            ("done-undone", .actionDone(DoneChipState(title: "Added: Call Dana", detail: "Fri 9:00 AM", kind: .createReminder, undoRecordID: 1, undone: true))),
        ]
    }
}
