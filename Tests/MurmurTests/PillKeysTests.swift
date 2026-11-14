import AppKit
import Carbon.HIToolbox
import CoreGraphics
import MurmurCore
import SwiftUI
import Testing
@testable import Murmur

/// ⏎/esc for the pill's question rows, taken through the existing event tap only while those rows
/// are showing — never otherwise (DECISIONS 2026-09-28 "Pill keys").
@Suite("Pill keys — scoped ⏎/esc for confirm rows and the password-field row")
@MainActor
struct PillKeysTests {
    private func route(_ keyCode: Int, _ flags: CGEventFlags = [], _ scope: PillKeyScope) -> PillKey? {
        PillKeyRouter.key(keyCode: keyCode, flags: flags, scope: scope)
    }

    @Test("with no question showing, no key is ever taken")
    func noScopeTakesNothing() {
        for code in [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_ANSI_C, kVK_Space] {
            #expect(route(code, [], .none) == nil)
            #expect(route(code, .maskCommand, .none) == nil)
        }
    }

    @Test("confirm rows: ⏎ and keypad Enter confirm all, esc dismisses all")
    func confirmScope() {
        #expect(route(kVK_Return, [], .confirm) == .confirm)
        #expect(route(kVK_ANSI_KeypadEnter, .maskNumericPad, .confirm) == .confirm)
        #expect(route(kVK_Escape, [], .confirm) == .dismiss)
    }

    @Test("the password-field row takes esc only; ⏎ still reaches the app")
    func dismissScope() {
        #expect(route(kVK_Escape, [], .dismiss) == .dismiss)
        #expect(route(kVK_Return, [], .dismiss) == nil)
    }

    @Test("modified keys and every other key pass through untouched", arguments: [PillKeyScope.confirm, .dismiss])
    func modifiedKeysPass(scope: PillKeyScope) {
        for flags: CGEventFlags in [.maskCommand, .maskShift, .maskAlternate, .maskControl] {
            #expect(route(kVK_Return, flags, scope) == nil)
            #expect(route(kVK_Escape, flags, scope) == nil)
        }
        #expect(route(kVK_ANSI_A, [], scope) == nil)
        #expect(route(kVK_Tab, [], scope) == nil)
    }

    @Test("⌘C is never taken globally: held text reaches the clipboard only through the Copy button")
    func commandCNeverTaken() {
        for scope in [PillKeyScope.none, .confirm, .dismiss, .finish] {
            #expect(route(kVK_ANSI_C, .maskCommand, scope) == nil)
        }
    }

    @Test("an action being heard: ⏎ finishes it even with the chord still held, esc discards it")
    func finishScope() {
        let chord: CGEventFlags = [.maskSecondaryFn, .maskControl]
        #expect(route(kVK_Return, [], .finish) == .confirm)
        #expect(route(kVK_Return, chord, .finish) == .confirm, "fn+⌃ is still down while the user presses ⏎")
        #expect(route(kVK_ANSI_KeypadEnter, .maskNumericPad, .finish) == .confirm)
        #expect(route(kVK_Return, .maskCommand, .finish) == .confirm, "⌘⏎ finishes too, like hands-free")
        #expect(route(kVK_Escape, [], .finish) == .dismiss)
        #expect(route(kVK_Escape, chord, .finish) == .dismiss)
        #expect(route(kVK_Space, [], .finish) == nil)
        #expect(route(kVK_ANSI_A, chord, .finish) == nil)
    }

    @Test("while working, esc cancels (even with the chord still down) and Return is never taken")
    func cancelOnlyScope() {
        let chord: CGEventFlags = [.maskSecondaryFn, .maskControl]
        #expect(route(kVK_Escape, [], .cancelOnly) == .dismiss)
        #expect(route(kVK_Escape, chord, .cancelOnly) == .dismiss)
        #expect(route(kVK_Return, [], .cancelOnly) == nil)
        #expect(route(kVK_Return, chord, .cancelOnly) == nil)
        #expect(route(kVK_ANSI_KeypadEnter, .maskNumericPad, .cancelOnly) == nil)
        // The key is still the pill's while the chord is down, listening: held actions are unchanged.
        #expect(PillState.actionListening.keyScope == .finish)
        #expect(route(kVK_Return, chord, PillState.actionListening.keyScope) == .confirm)
    }

    // MARK: Scope per pill state

    @Test("scope follows the pill: every state that waits on the user answers a key")
    func scopePerState() {
        let card = PillOutcomeTests.card(rows: 2)
        #expect(PillState.actionConfirm(card).keyScope == .confirm)
        var resolved = card
        for index in resolved.rows.indices { resolved.rows[index].status = .cancelled }
        #expect(PillState.actionConfirm(resolved).keyScope == .dismiss, "esc can always close a lingering card")
        #expect(PillState.held(copied: false).keyScope == .dismiss)
        #expect(PillState.held(copied: true).keyScope == .none)
        #expect(PillState.actionListening.keyScope == .finish)
        #expect(PillState.actionProcessing.keyScope == .cancelOnly, "Working…: esc only, ⏎ reaches the app")
        let chip = DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 1)
        #expect(PillState.actionDone(chip).keyScope == .dismiss)
        let answer = AnswerCardState(question: "q", phase: .answer(.init(text: "a", items: [], sourceLabel: "s")))
        #expect(PillState.answer(answer).keyScope == .dismiss)
        #expect(PillState.answer(AnswerCardState(question: "q", phase: .listening)).keyScope == .finish)
        for state: PillState in [.idle, .listening, .processing(), .copied(reason: .pasteFailed),
                                 .done(words: 3), .error("x")] {
            #expect(state.keyScope == .none, "\(state)")
        }
    }

    @Test("the held chord says fn + control; the idle hint names the chosen action key whatever the dictation key")
    func chordKeys() {
        #expect(ActionHotkeyMonitor.chordKeys == ["fn", "control"])
        #expect(ActionHotkeyMonitor.chordText == "fn + control")
        let pill = PillModel()
        pill.triggerGlyph = "⌥"
        pill.hoveredIdleControl = .action
        #expect(pill.idleHint.keys == ["control"])
        pill.actionKeyCap = "option"
        #expect(pill.idleHint.keys == ["option"])
        pill.hoveredIdleControl = .dictate
        #expect(pill.idleHint.keys == ["⌥"])
    }

    // MARK: The card's key window (8 s after it appears or was last hovered)

    private func pendingCardPill(at start: Date) -> PillModel {
        let pill = PillModel()
        pill.state = .actionConfirm(PillOutcomeTests.card(rows: 2))
        pill.renewCardKeys(now: start) // what showing the card does, with a fixed clock
        return pill
    }

    @Test("a new card takes ⏎ for 8 s, then only esc still dismisses it")
    func cardKeysExpire() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let pill = pendingCardPill(at: start)
        #expect(pill.keyScope(now: start.addingTimeInterval(7.9), ownTextFieldFocused: false) == .confirm)
        let expired = pill.keyScope(now: start.addingTimeInterval(8), ownTextFieldFocused: false)
        #expect(expired == .dismiss, "a lingering card never eats an Enter meant for Slack or Messages")
        #expect(PillKeyRouter.key(keyCode: kVK_Return, flags: [], scope: expired) == nil)
        #expect(PillKeyRouter.key(keyCode: kVK_Escape, flags: [], scope: expired) == .dismiss,
                "esc can't send anything, so it always clears the card")
        #expect(PillModel.cardKeyWindow == .seconds(8))
    }

    @Test("hovering the card renews the window")
    func hoverRenews() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let pill = pendingCardPill(at: start)
        pill.renewCardKeys(now: start.addingTimeInterval(20)) // the pointer came back to the card
        #expect(pill.keyScope(now: start.addingTimeInterval(27), ownTextFieldFocused: false) == .confirm)
        #expect(pill.keyScope(now: start.addingTimeInterval(28.5), ownTextFieldFocused: false) == .dismiss)
    }

    @Test("the action being heard needs no key window")
    func noWindowForOtherStates() {
        let pill = PillModel()
        let late = Date().addingTimeInterval(60)
        pill.state = .actionListening
        #expect(pill.keyScope(now: late, ownTextFieldFocused: true) == .finish,
                "an action being heard is finished by ⏎ wherever focus is, like hands-free dictation")
    }

    @Test("showing a card starts the window; updating its rows doesn't restart it")
    func showingStartsWindow() {
        let pill = PillModel()
        #expect(pill.cardKeysUntil == nil)
        pill.state = .actionConfirm(PillOutcomeTests.card(rows: 2))
        let first = pill.cardKeysUntil
        #expect(first != nil)
        var card = PillOutcomeTests.card(rows: 2)
        card.rows[0].status = .confirming
        pill.state = .actionConfirm(card)
        #expect(pill.cardKeysUntil == first)
        pill.state = .idle
        #expect(pill.cardKeysUntil == nil)
    }

    @Test("⏎ is never taken while a text field in Hushy's own window has focus; esc still dismisses")
    func ownChatBox() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let pill = pendingCardPill(at: start)
        let scope = pill.keyScope(now: start, ownTextFieldFocused: true)
        #expect(scope == .dismiss)
        #expect(PillKeyRouter.key(keyCode: kVK_Return, flags: [], scope: scope) == nil)
        #expect(PillKeyRouter.key(keyCode: kVK_Escape, flags: [], scope: scope) == .dismiss)
    }

    @Test("Hushy's own focused text input is detected from the first responder")
    func ownTextInputDetection() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        #expect(OwnTextFocus.isTextInput(NSTextField()))
        #expect(OwnTextFocus.isTextInput(NSTextView()))
        #expect(OwnTextFocus.isTextInput(editor))
        #expect(!OwnTextFocus.isTextInput(NSButton()))
        #expect(!OwnTextFocus.isTextInput(nil))
    }

    @Test("the footer shows ⏎/esc key caps only while the keys work")
    func footerPromisesOnlyLiveKeys() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let pill = pendingCardPill(at: start)
        #expect(pill.cardKeysLive(now: start.addingTimeInterval(1)))
        #expect(!pill.cardKeysLive(now: start.addingTimeInterval(9)))
    }

    // MARK: Answering

    @Test("⏎ confirms all and esc dismisses all on a confirm card")
    func answerConfirmCard() {
        let pill = PillModel()
        var confirmed = 0
        var cancelled = 0
        pill.onActionConfirmAll = { confirmed += 1 }
        pill.onActionCancelAll = { cancelled += 1 }
        pill.state = .actionConfirm(PillOutcomeTests.card(rows: 3))
        pill.answer(.confirm)
        pill.answer(.dismiss)
        #expect(confirmed == 1 && cancelled == 1)
    }

    @Test("⏎ stops an action being heard and runs it; esc discards it")
    func answerActionListening() {
        let pill = PillModel()
        var stopped = 0
        var discarded = 0
        pill.onActionStopListening = { stopped += 1 }
        pill.onActionDiscardListening = { discarded += 1 }
        pill.state = .actionListening
        pill.answer(.confirm)
        #expect(stopped == 1 && discarded == 0)
        pill.answer(.dismiss)
        #expect(discarded == 1)
        // A follow-up being heard on the answer card is the same utterance flow.
        pill.state = .answer(AnswerCardState(question: "q", phase: .listening))
        pill.answer(.confirm)
        pill.answer(.dismiss)
        #expect(stopped == 2 && discarded == 2)
    }

    @Test("after Stop, esc cancels action processing and Return never executes twice")
    func answerActionProcessing() {
        let pill = PillModel()
        var cancelled = 0
        pill.onActionCancelProcessing = { cancelled += 1 }
        pill.state = .actionProcessing
        pill.answer(.confirm)
        #expect(cancelled == 0)
        pill.answer(.dismiss)
        #expect(cancelled == 1)
    }

    @Test("esc clears the done chip and a finished answer")
    func answerRows() {
        let pill = PillModel()
        var closed = 0
        pill.onAnswerClose = { closed += 1 }
        pill.state = .actionDone(DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 1))
        pill.answer(.confirm)
        #expect(pill.state != .idle, "⏎ never undoes: the chip only clears")
        pill.answer(.dismiss)
        #expect(pill.state == .idle)
        pill.state = .answer(AnswerCardState(question: "q", phase: .answer(.init(text: "a", items: [], sourceLabel: "s"))))
        pill.answer(.confirm)
        #expect(closed == 0, "the answer card has no default action")
        pill.answer(.dismiss)
        #expect(closed == 1)
    }

    @Test("esc dismisses the held row without copying anything")
    func answerHeldRow() {
        let pill = PillModel()
        var dismissed = 0
        var copies: [String] = []
        pill.onDismiss = { dismissed += 1 }
        pill.onCopy = { copies.append($0) }
        pill.present(.held(copied: false), text: "hunter2")
        pill.answer(.confirm)
        pill.answer(.dismiss)
        #expect(dismissed == 1)
        #expect(copies.isEmpty)
    }

    // MARK: Layout per anchor

    @Test("the capsule sits on the anchored edge; rows, cards and tooltips open toward the centre")
    func layoutPerAnchor() {
        #expect(PillLayout(anchor: .bottom).alignment == .bottom)
        #expect(PillLayout(anchor: .top).alignment == .top)
        #expect(PillLayout(anchor: .left).alignment == .leading)
        #expect(PillLayout(anchor: .right).alignment == .trailing)
        #expect(PillLayout(anchor: .top).opensDownward)
        #expect(!PillLayout(anchor: .left).opensDownward)
        #expect(PillLayout(anchor: .left).sidePadding == PillGeometry.sideShadowPad)
        #expect(PillLayout(anchor: .bottom).sidePadding == 0)
        #expect(PillLayout(anchor: .bottom).stackEdge == .leading, "card and footer share the left edge")
        #expect(PillLayout(anchor: .top).stackEdge == .leading)
        #expect(PillLayout(anchor: .right).stackEdge == .trailing)
    }
}

/// Paste-and-send is gone (founder decision 2026-09-28): ⏎ and ⌘⏎ during hands-free both just
/// finish and paste — Hushy never presses Return after a paste on its own. ⌘⏎ is still taken, so
/// it can't reach the app mid-dictation and send a half-written message there.
@Suite("Hands-free finish keys — no paste-and-send")
struct HandsFreeFinishKeyTests {
    @Test("⏎, keypad Enter and ⌘⏎ all finish a latched dictation the same way", arguments: [
        (kVK_Return, CGEventFlags()), (kVK_ANSI_KeypadEnter, CGEventFlags.maskNumericPad),
        (kVK_Return, CGEventFlags.maskCommand),
    ])
    func finishKeys(keyCode: Int, flags: CGEventFlags) {
        #expect(HotkeyMonitor.finishesLatched(keyCode: keyCode, flags: flags, isLatched: true))
        #expect(HotkeyEvent.finishLatched == .finishLatched, "no send flag exists any more")
    }

    @Test("outside hands-free, Return is never taken")
    func notLatched() {
        #expect(!HotkeyMonitor.finishesLatched(keyCode: kVK_Return, flags: [], isLatched: false))
        #expect(!HotkeyMonitor.finishesLatched(keyCode: kVK_ANSI_A, flags: [], isLatched: true))
    }
}
