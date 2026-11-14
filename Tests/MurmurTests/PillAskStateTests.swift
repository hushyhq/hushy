import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The answer card and the done chip as pill states: which keys they take, how big the panel
/// is, what VoiceOver reads, when they clear themselves, and the follow-up thread helpers.
@Suite("Pill — answer card and done chip")
@MainActor
struct PillAskStateTests {
    private static let groceries = AnswerCardState.AnswerContent(
        text: "You need four things.", items: ["oat milk", "eggs", "sourdough", "coffee beans"],
        sourceLabel: "From your note 'Groceries' · Sep 26", sourceLink: .note(id: 7))

    private static func answerState(phase: AnswerCardState.Phase) -> PillState {
        .answer(AnswerCardState(question: "what groceries do i need", phase: phase))
    }

    @Test("esc closes the answer card, ⏎ never; a follow-up being heard is finished by ⏎ and discarded by esc")
    func keys() {
        let model = PillModel()
        model.state = Self.answerState(phase: .answer(Self.groceries))
        #expect(model.keyScope(now: Date(), ownTextFieldFocused: false) == .dismiss)
        #expect(model.keyScope(now: Date(), ownTextFieldFocused: true) == .dismiss)
        var closed = false
        model.onAnswerClose = { closed = true }
        model.answer(.dismiss)
        #expect(closed)
        model.state = Self.answerState(phase: .listening)
        #expect(model.keyScope(now: Date(), ownTextFieldFocused: false) == .finish)
        #expect(PillKeyRouter.key(keyCode: 36, flags: [], scope: .dismiss) == nil)
    }

    @Test("the panel grows with the answer; the done chip is a one-line row")
    func panelSizes() {
        let thinking = PillPanel.size(for: Self.answerState(phase: .thinking))
        #expect(thinking.width == AnswerCard.width + 24)
        #expect(thinking.height == PillPanel.size.height + 96)
        let answered = PillPanel.size(for: Self.answerState(phase: .answer(Self.groceries)))
        #expect(answered.height > thinking.height)
        let chip = PillPanel.size(for: .actionDone(DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 1)))
        #expect(chip == PillPanel.rowSize)
        // Text rows and cards never stand vertical at a side edge.
        #expect(PillPanel.size(for: Self.answerState(phase: .thinking), anchor: .left).height == thinking.height)
        #expect(!PillLayout(anchor: .right).isVertical(.actionDone(DoneChipState(title: "x", kind: .openLink))))
    }

    @Test("the done chip clears itself after the undo window, 'Undone' after 1.4 s, a copied answer after 1.4 s")
    func selfDismiss() {
        let chip = DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 1)
        #expect(PillState.actionDone(chip).selfDismissDelay == ActionUndoWindow.duration)
        var undone = chip
        undone.undone = true
        #expect(PillState.actionDone(undone).selfDismissDelay == .milliseconds(1_400))
        #expect(Self.answerState(phase: .answer(Self.groceries)).selfDismissDelay == nil)
        var copied = AnswerCardState(question: "q", phase: .answer(Self.groceries))
        copied.copied = true
        #expect(PillState.answer(copied).selfDismissDelay == .milliseconds(1_400))
    }

    @Test("only a chip with something to undo takes clicks; the answer card always does")
    func interactive() {
        #expect(PillState.actionDone(DoneChipState(title: "x", kind: .createReminder, undoRecordID: 3)).isInteractive)
        #expect(!PillState.actionDone(DoneChipState(title: "Opened in Claude — press ↩", kind: .openLink)).isInteractive)
        #expect(Self.answerState(phase: .thinking).isInteractive)
    }

    @Test("VoiceOver reads the answer, its items and the source; the chip says Undo is available")
    func accessibility() {
        let model = PillModel()
        model.state = Self.answerState(phase: .answer(Self.groceries))
        #expect(model.accessibilityLabel == "You need four things. oat milk, eggs, sourdough, coffee beans. From your note 'Groceries' · Sep 26")
        model.state = .actionDone(DoneChipState(title: "Added: Call Dana", detail: "Fri 9:00", kind: .createReminder, undoRecordID: 1))
        #expect(model.accessibilityLabel == "Added: Call Dana, Fri 9:00. Undo available.")
        model.state = Self.answerState(phase: .failure(.init(message: "I couldn't find a grocery list.", suggestion: "Search Apple Notes?")))
        #expect(model.accessibilityLabel == "I couldn't find a grocery list.")
    }

    @Test("Copy text carries the answer, its items and the source line")
    func copyText() {
        let card = AnswerCardState(question: "q", phase: .answer(Self.groceries))
        #expect(card.copyText == "You need four things.\n- oat milk\n- eggs\n- sourdough\n- coffee beans\n— From your note 'Groceries' · Sep 26")
        #expect(AnswerCardState(question: "q", phase: .thinking).copyText == "")
    }

    @Test("the thread carries the current answer into the next turn; a cited list names itself")
    func threadHelpers() {
        var card = AnswerCardState(question: "what groceries do i need", phase: .answer(Self.groceries))
        card.thread = [AskTurn(question: "earlier", answer: "before")]
        let thread = VoiceActionsController.thread(after: card)
        #expect(thread.count == 2)
        #expect(thread.last == AskTurn(question: "what groceries do i need", answer: "You need four things.; oat milk; eggs; sourdough; coffee beans"))
        #expect(VoiceActionsController.thread(after: nil).isEmpty)
        #expect(VoiceActionsController.listName(cited: card) == "Groceries")
        var list = card
        list.phase = .answer(.init(text: "", items: ["bananas"], sourceLabel: "From your Reminders list 'Shopping'", sourceLink: nil))
        #expect(VoiceActionsController.listName(cited: list) == "Shopping")
        var screen = card
        screen.phase = .answer(.init(text: "gist", items: [], sourceLabel: "Safari · Page (300 words)", sourceLink: nil, isScreenSummary: true))
        #expect(VoiceActionsController.listName(cited: screen) == nil)
    }

    @Test("an answer's card content names the source and links a Hushy note")
    func content() {
        let source = OwnStuffItem(id: "note-7", kind: .note, title: "Groceries", body: "oat milk",
                                  date: ProposalFields.parseISO8601("2026-09-26T09:00:00-07:00"), openURL: URL(string: "hushy://note/7"))
        let content = VoiceActionsController.content(for: AskAnswer(text: "You need oat milk.", items: ["oat milk"], source: source))
        #expect(content.sourceLabel.hasPrefix("From your note 'Groceries' · "))
        #expect(content.sourceLink == .note(id: 7))
        #expect(!content.isScreenSummary)
    }

    @Test("open requests become open-link actions the policy treats as Tier 1")
    func openActions() {
        let app = VoiceActionsController.openAction(.app(name: "Slack"), utterance: "open slack")
        #expect(app.first?.kind == .openLink)
        #expect(app.first?.url == nil)
        #expect(app.first?.title == "Open Slack")
        // The done chip reads "Opened: Slack"; a detail of "Slack" would only repeat it.
        #expect(app.first.flatMap(VoiceActionsController.detail(for:)) == nil)
        let link = DeepLinkBuilder.build(service: .gmail, action: .open)!
        let opened = VoiceActionsController.openAction(.link(link), utterance: "open gmail")
        #expect(opened.first?.url == "https://mail.google.com/mail/u/0/")
        #expect(ActionDispatch.plan(opened, utterance: "open gmail", setting: .risky) == .actNow(opened[0]))
        #expect(VoiceActionsController.detail(for: opened[0]) == "mail.google.com")
    }
}
