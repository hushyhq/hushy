import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The voice-action pill (founder, 2026-10-10): as small as dictation's pill, a tick and a cancel,
/// no row of key caps, and no state without a way out. Everything here is pure: parts, sizes,
/// words and keys.
@Suite("Voice action pill")
@MainActor
struct ActionPillTests {
    private static let reminder = ProposedAction(kind: .createReminder, title: "Oat milk", sourceText: "x")

    private static func card(_ status: ActionConfirmationRow.RowStatus) -> ActionConfirmationCardState {
        var card = ActionConfirmationCardState(actions: [reminder])
        card.rows[0].status = status
        return card
    }

    // MARK: Listening

    @Test("latched, the pill is cancel, bolt, meter, tick and nothing else")
    func latchedParts() {
        #expect(ActionPillLayout.listening(.latched(cancelKey: "control")).parts == [.cancel, .bolt, .meter, .send])
        #expect(ActionPillLayout.listening(.latched(cancelKey: nil)).parts == [.cancel, .bolt, .meter, .send])
        #expect(ActionPillLayout.listening(.latched(cancelKey: nil)).fixedSize == nil)
    }

    @Test("latched, it is dictation's hands-free capsule with a bolt and no timer")
    func latchedWidth() {
        let width = ActionPillLayout.listening(.latched(cancelKey: "control")).width
        #expect(width == ActionPillLayout.dictationHandsFreeWidthWithoutTimer + ActionPillLayout.boltWidth + ActionPillLayout.spacing)
        #expect(width == 143)
        // The bar it replaces was about 350 pt with its key caps; dictation's pill with a timer is about 163.
        #expect(width < 163)
        #expect(ActionPillLayout.height == 30)
        #expect(ActionPillLayout.buttonDiameter == 20, "the same hit target as dictation's ✕ and ✓")
    }

    @Test("the meter is dictation's own nine 3 pt bars")
    func meter() {
        #expect(ActionPillLayout.meterWidth == 51)
    }

    @Test("with the chord held it is dictation's Listening capsule: bolt and bars, no buttons")
    func heldParts() {
        let layout = ActionPillLayout.listening(.held)
        #expect(layout.parts == [.bolt, .meter])
        #expect(layout.fixedSize == PillMetrics.listening)
        #expect(layout.width == PillMetrics.listening.width)
        let content = ActionPillLayout.boltWidth + ActionPillLayout.spacing + ActionPillLayout.meterWidth
        #expect(content <= PillMetrics.listening.width - 2 * ActionPillLayout.endPadding, "the bolt and bars fit inside it")
    }

    @Test("the model says held only while the chord is down; a double tap names its cancelling key")
    func listeningMode() {
        let pill = PillModel()
        #expect(pill.actionListeningMode == .latched(cancelKey: nil))
        pill.actionCancelKey = "control"
        #expect(pill.actionListeningMode == .latched(cancelKey: "control"))
        pill.actionCancelKey = nil
        pill.actionChordHeld = true
        #expect(pill.actionListeningMode == .held)
    }

    @Test("the controller marks the held chord, and clears it when listening ends")
    func controllerMarksHeld() throws {
        let hotkeys = ActionHotkeyMonitor()
        let pill = PillModel()
        let integrity = SpeechModelIntegrity(
            fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: "hushy-test-\(UUID().uuidString)")
        let controller = VoiceActionsController(
            hotkeys: hotkeys, pill: pill, speech: SpeechEngine(status: SpeechModelStatus(), integrity: integrity),
            modelStatus: SpeechModelStatus(), store: try Store(), calendarBackend: FakeCalendarBackend(),
            shortcutsBackend: FakeShortcutsBackend())

        controller.beginListeningForTests(handsFree: true)
        #expect(pill.actionListeningMode == .latched(cancelKey: "control"))
        controller.discardListening()
        #expect(pill.state == .idle)

        controller.beginListeningForTests(handsFree: false)
        #expect(pill.actionListeningMode == .held)
        controller.discardListening()
        #expect(!pill.actionChordHeld)

        // Started from the pill's ⚡ button: nothing is held, so the pill must carry ✕ and ✓.
        controller.beginListeningForTests(handsFree: false, chordHeld: false)
        #expect(pill.actionListeningMode == .latched(cancelKey: nil))
        #expect(ActionPillLayout.listening(pill.actionListeningMode).parts.contains(.send))
        controller.stopListening()
        #expect(!pill.actionChordHeld)
        #expect(pill.state != .actionListening)
    }

    // MARK: Keys and hover

    @Test("the keys work exactly as before: return sends, esc cancels, chord held or not")
    func keysUnchanged() {
        let scope = PillState.actionListening.keyScope
        #expect(scope == .finish)
        let chord: CGEventFlags = [.maskSecondaryFn, .maskControl]
        for flags in [CGEventFlags(), chord] {
            #expect(PillKeyRouter.key(keyCode: kVK_Return, flags: flags, scope: scope) == .confirm)
            #expect(PillKeyRouter.key(keyCode: kVK_ANSI_KeypadEnter, flags: flags, scope: scope) == .confirm)
            #expect(PillKeyRouter.key(keyCode: kVK_Escape, flags: flags, scope: scope) == .dismiss)
        }
        #expect(PillKeyRouter.key(keyCode: kVK_Return, flags: [], scope: PillState.actionProcessing.keyScope) == nil)
        #expect(PillKeyRouter.key(keyCode: kVK_Escape, flags: chord, scope: PillState.actionProcessing.keyScope) == .dismiss)
    }

    @Test("a hover names the key: Cancel esc (or the action key), Send return")
    func hoverHints() {
        #expect(PillHint.cancelAction().compact == "Cancel [esc]")
        #expect(PillHint.cancelAction(alsoKey: "control").compact == "Cancel [esc] or [control]")
        #expect(PillHint.runAction.compact == "Send [return]")
        let tokens = TooltipBubble.tokens(PillHint.cancelAction(alsoKey: "option").compact)
        #expect(tokens.map(\.text) == ["Cancel", "esc", "or", "option"])
        #expect(tokens.map(\.isKey) == [false, true, false, true])
    }

    @Test("dictation's own hints are untouched")
    func dictationHints() {
        #expect(PillHint.cancel.compact == "Cancel [esc]")
        #expect(PillHint.finish.compact == "Done [⏎]")
        #expect(PillHint.saveNote.compact == "Stop and save")
    }

    @Test("VoiceOver gets a label for each button and the key in its hint")
    func accessibility() {
        #expect(ActionPillAccessibility.cancelLabel == "Cancel action")
        #expect(ActionPillAccessibility.sendLabel == "Stop and run the action")
        #expect(ActionPillAccessibility.sendHint == "Return sends.")
        #expect(ActionPillAccessibility.cancelHint(alsoKey: nil) == "Escape cancels.")
        #expect(ActionPillAccessibility.cancelHint(alsoKey: "control") == "Escape or one tap of control cancels.")
        let pill = PillModel()
        pill.state = .actionListening
        #expect(pill.accessibilityLabel == "Listening for an action")
        pill.state = .actionProcessing
        #expect(pill.accessibilityLabel == "Working on the action. Press Escape to cancel.")
    }

    // MARK: Working

    @Test("working is cancel, bolt, dots: smaller than the listening pill, and ✕ stays first")
    func workingParts() {
        #expect(ActionPillLayout.working.parts == [.cancel, .bolt, .dots])
        #expect(ActionPillLayout.working.width == 87)
        #expect(ActionPillLayout.working.width < ActionPillLayout.listening(.latched(cancelKey: nil)).width)
        #expect(ActionPillLayout.working.parts.first == ActionPillLayout.listening(.latched(cancelKey: nil)).parts.first)
    }

    @Test("the working label waits for a long wait, then says the same words as before")
    func workingLabel() {
        #expect(ActionWorkingPhase.label(after: 0) == nil)
        #expect(ActionWorkingPhase.label(after: 4.9) == nil)
        #expect(ActionWorkingPhase.label(after: 5) == "Working on it…")
        #expect(ActionWorkingPhase.labelDelay == WritingPhase.stillDelay)
    }

    @Test("entering working stamps its start; leaving clears it")
    func workingStart() {
        let pill = PillModel()
        #expect(pill.actionProcessingStartedAt == nil)
        pill.state = .actionProcessing
        #expect(pill.actionProcessingStartedAt != nil)
        pill.state = .idle
        #expect(pill.actionProcessingStartedAt == nil)
    }

    // MARK: Results

    @Test("the done chip keeps its time and place for a hover, and for VoiceOver")
    func doneDetail() {
        var chip = DoneChipState(title: "Added: Dentist", detail: "Oct 11 at 3:00 PM · Home", kind: .createEvent, undoRecordID: 1)
        #expect(PillState.actionDone(chip).hoverDetail == "Oct 11 at 3:00 PM · Home")
        #expect(chip.accessibilityText == "Added: Dentist, Oct 11 at 3:00 PM · Home. Undo available.")
        #expect(chip.canUndo, "Undo is still one click")
        chip.isUndoing = true
        #expect(PillState.actionDone(chip).hoverDetail == nil)
        chip.isUndoing = false
        chip.undoFailure = "Couldn't undo."
        #expect(PillState.actionDone(chip).hoverDetail == nil)
        chip.undoFailure = nil
        chip.undone = true
        #expect(PillState.actionDone(chip).hoverDetail == nil)
        #expect(PillState.actionDone(DoneChipState(title: "Opened: Chrome", kind: .openLink)).hoverDetail == nil)
        #expect(DoneChipRow.compactTitleLimit == 170)
    }

    @Test("a card that only reports a problem is one pill row, with Retry only when it is safe")
    func problemRow() {
        #expect(Self.card(.failed("Reminders access needed")).soleProblemRow != nil)
        #expect(Self.card(.blocked("x")).soleProblemRow != nil)
        #expect(Self.card(.uncertain("x")).soleProblemRow != nil)
        #expect(Self.card(.pending).soleProblemRow == nil, "a question stays the confirm row")
        #expect(Self.card(.confirming).soleProblemRow == nil)
        var two = ActionConfirmationCardState(actions: [Self.reminder, Self.reminder])
        two.rows[0].status = .failed("x")
        #expect(two.soleProblemRow == nil, "more than one row stays a card")

        #expect(ActionConfirmationRow.RowStatus.failed("x").canRunAgain)
        #expect(!ActionConfirmationRow.RowStatus.uncertain("x").canRunAgain, "it may already have run")
        #expect(!ActionConfirmationRow.RowStatus.blocked("x").canRunAgain, "it would fail the same way")
        #expect(ActionProblemRow.isUncertain(.uncertain("x")))
        #expect(!ActionProblemRow.isUncertain(.failed("x")))
    }

    @Test("the failed action's own words wait behind a hover")
    func problemHover() {
        #expect(PillState.actionConfirm(Self.card(.failed("Reminders access needed"))).hoverDetail == "Add \"Oat milk\"")
        #expect(PillState.actionConfirm(Self.card(.pending)).hoverDetail == nil)
        let shortcut = ProposedAction(kind: .runShortcut, title: "Send Standup", shortcutName: "Send Standup", sourceText: "x")
        #expect(ActionConfirmationRowView.title(for: shortcut) == "Run \"Send Standup\"")
    }

    @Test("states that are not compact action rows show nothing on hover")
    func noHoverDetailElsewhere() {
        for state: PillState in [.idle, .listening, .handsFree(startedAt: .now), .processing(), .actionListening,
                                 .actionProcessing, .error("Stopped listening"), .done(words: 4)] {
            #expect(state.hoverDetail == nil)
        }
    }

    // MARK: The card footer

    @Test("the footer's buttons name their keys only while the keys work")
    func footerHints() {
        let live = ActionCardFooter.hints(count: 3, isChoice: false, keysLive: true)
        #expect(live.cancel.compact == "Dismiss all [esc]")
        #expect(live.confirm.compact == "Confirm all [return]")
        let expired = ActionCardFooter.hints(count: 3, isChoice: false, keysLive: false)
        #expect(expired.cancel.compact == "Dismiss all [esc]", "esc keeps dismissing a lingering card")
        #expect(expired.confirm.compact == "Confirm all", "never a key cap for a key that won't work")
        #expect(ActionCardFooter.hints(count: 3, isChoice: true, keysLive: true).confirm.compact == "Open first [return]")
    }

    // MARK: Nothing is unreachable

    @Test("every voice-action state can be left from the keyboard, and takes the pointer when it has a button")
    func everyStateKeepsItsEscape() {
        let undoable = DoneChipState(title: "Added: Dentist", kind: .createEvent, undoRecordID: 1)
        let states: [PillState] = [
            .actionListening, .actionProcessing, .actionDone(undoable),
            .actionConfirm(Self.card(.pending)), .actionConfirm(Self.card(.failed("x"))),
            .actionConfirm(Self.card(.uncertain("x"))), .actionConfirm(Self.card(.blocked("x"))),
        ]
        for state in states {
            #expect(PillKeyRouter.key(keyCode: kVK_Escape, flags: [], scope: state.keyScope) == .dismiss, "\(state)")
            #expect(state.isInteractive, "\(state)")
        }
        // The two layouts drawn without a card each carry a ✕, except the held chord, whose way
        // out is the key under the person's fingers (let go to send, esc to cancel).
        #expect(ActionPillLayout.listening(.latched(cancelKey: nil)).hasCancelControl)
        #expect(ActionPillLayout.working.hasCancelControl)
        #expect(!ActionPillLayout.listening(.held).hasCancelControl)
    }

    @Test("esc on the pill still reaches the same handlers")
    func answersRouteAsBefore() {
        let pill = PillModel()
        var events: [String] = []
        pill.onActionStopListening = { events.append("send") }
        pill.onActionDiscardListening = { events.append("discard") }
        pill.onActionCancelProcessing = { events.append("cancel-working") }
        pill.onActionCancelAll = { events.append("dismiss-card") }
        pill.state = .actionListening
        pill.answer(.confirm)
        pill.answer(.dismiss)
        pill.state = .actionProcessing
        pill.answer(.confirm)
        pill.answer(.dismiss)
        pill.state = .actionConfirm(Self.card(.failed("x")))
        pill.answer(.dismiss)
        #expect(events == ["send", "discard", "cancel-working", "dismiss-card"])
    }
}
