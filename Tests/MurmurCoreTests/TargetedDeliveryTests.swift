import XCTest
@testable import MurmurCore

/// Records what a delivery did to the keyboard and a one-slot clipboard. Staging our text
/// schedules a restore of the user's clipboard (like `ClipboardPaster`); `settle()` runs it.
@MainActor
final class FakePaster: DeliveryPaster {
    let userClipboard = "user's own clipboard"
    private(set) var clipboard: String
    private(set) var events: [String] = []
    private var restorePending = false
    /// The paste whose restore is held for a landing check, and how each held paste was settled.
    private var held: PasteLanding?
    private(set) var settlements: [LandingSettlement] = []
    var pasteKeySucceeds = true
    var returnKeySucceeds = true
    /// Runs after the clipboard is staged, before the ⌘V re-check (focus moves "during" paste).
    var afterStaging: () -> Void = {}
    /// Runs during the ~60 ms wait before Return.
    var duringReturnWait: () -> Void = {}

    init() { clipboard = userClipboard }

    func paste(_ text: String, pressReturn: Bool, awaitLanding: PasteLanding?, hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome {
        await BoundDelivery.perform(
            pressReturn: pressReturn, isCurrent: { true }, hasFocus: hasFocus,
            prepareClipboard: {
                self.events.append("stage")
                self.clipboard = text
                self.restorePending = true
                self.held = awaitLanding
                self.afterStaging()
                return true
            },
            clipboardIsOwned: { self.clipboard == text },
            paste: { self.events.append("⌘V"); return self.pasteKeySucceeds },
            waitBeforeReturn: { self.duringReturnWait() },
            sendReturn: { self.events.append("↩"); return self.returnKeySucceeds })
    }

    /// Unconfirmed keeps the staged text; confirmed and withdrawn leave the restore to run.
    func finishLanding(_ landing: PasteLanding, as settlement: LandingSettlement) {
        guard landing == held else { return }
        held = nil
        settlements.append(settlement)
        if settlement == .unconfirmed { restorePending = false }
    }

    func sendReturn(hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome {
        await BoundDelivery.performReturnOnly(
            isCurrent: { true }, hasFocus: hasFocus,
            waitBeforeReturn: { self.duringReturnWait() },
            sendReturn: { self.events.append("↩"); return self.returnKeySucceeds })
    }

    func copyForManualPaste(_ text: String) {
        events.append("copy")
        clipboard = text
        restorePending = false
    }

    /// The restore timer fires.
    func settle() {
        if restorePending { clipboard = userClipboard }
        restorePending = false
    }
}

@MainActor
final class TargetedDeliveryTests: XCTestCase {
    private let text = "Ship it on Thursday."
    private var focus: FakeFocus!
    private var bound: BoundFocus<Int>!
    private var paster: FakePaster!

    override func setUp() async throws {
        focus = FakeFocus()
        bound = focus.bind()
        paster = FakePaster()
    }

    private func deliver(
        _ text: String? = nil, pressReturn: Bool = false, hasTextInput: Bool = true,
        noFieldClipboard: NoFieldClipboardPolicy = .current
    ) async -> DeliveryResult {
        let result = await TargetedDelivery.deliver(
            text: text ?? self.text, pressReturn: pressReturn, hasTextInput: hasTextInput,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            noFieldClipboard: noFieldClipboard, paster: paster)
        paster.settle()
        return result
    }

    // MARK: Target unchanged

    func testUnknownPasteConfirmedByCountChange() async {
        var count = 3
        paster.afterStaging = { count = 3 + self.text.count }
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: count, selectedLength: 0) }, paster: paster)
        XCTAssertEqual(result, .unknownConfirmed)
        XCTAssertEqual(result.logSummary, "delivery=pasted landing=confirmed")
        paster.settle()
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testCancelledDuringTheLandingWaitReportsThePasteAndTakesTheTextOffTheClipboard() async {
        // ⌘V has gone out; the count never changes. A cancel during the wait must not turn a
        // paste into "cancelled" or into "not landed" by spinning through the remaining reads.
        // Nothing will show a cancelled dictation, so its text must not stay on the clipboard.
        var reads = 0
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: {
                reads += 1
                if reads == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return LandingProbe(characterCount: 3, selectedLength: 0)
            }, paster: paster)
        XCTAssertEqual(result, .unknownCancelled)
        XCTAssertEqual(result.logSummary, "delivery=pasted landing=cancelled clipboard=restored")
        XCTAssertTrue(result.hasUnknownLandingCheck)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(paster.settlements, [.withdrawn])
        paster.settle()
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testCancelledDuringTheReturnWaitAfterAnUnreadableLandingTakesTheTextOffTheClipboard() async {
        // The landing could not be read, so the clipboard is still held while Return waits.
        paster.duringReturnWait = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { nil }, paster: paster)
        XCTAssertEqual(result, .unknownCancelled)
        XCTAssertEqual(paster.events, ["stage", "⌘V"], "no Return after a cancel")
        XCTAssertEqual(paster.settlements, [.withdrawn])
        paster.settle()
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testCancelledAfterAConfirmedLandingStaysAConfirmedPaste() async {
        var count = 3
        paster.afterStaging = { count = 4 }
        paster.duringReturnWait = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: count, selectedLength: 0) }, paster: paster)
        XCTAssertEqual(result, .unknownConfirmedReturnSkipped(nil))
        XCTAssertEqual(paster.settlements, [.confirmed])
        paster.settle()
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testEveryHeldPasteIsSettledExactlyOnce() async {
        let probes: [(LandingProbe?, LandingProbe?, LandingSettlement)] = [
            (LandingProbe(characterCount: 3, selectedLength: 0), LandingProbe(characterCount: 9, selectedLength: 0), .confirmed),
            (LandingProbe(characterCount: 3, selectedLength: 0), LandingProbe(characterCount: 3, selectedLength: 0), .unconfirmed),
            (nil, nil, .unconfirmed),
        ]
        for (before, after, expected) in probes {
            for pressReturn in [false, true] {
                paster = FakePaster()
                var reads = 0
                _ = await TargetedDelivery.deliver(
                    text: text, pressReturn: pressReturn, answer: .unknown,
                    check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
                    landing: { reads += 1; return reads == 1 ? before : after }, paster: paster)
                XCTAssertEqual(paster.settlements, [expected], "\(expected) return=\(pressReturn)")
            }
        }
    }

    func testPasswordFieldFocusedWhenTheLandingFailsWithdrawsTheStagedText() async {
        // The paste goes out; a password field has focus by the time the landing check gives up.
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { self.paster.events.contains("⌘V") ? .secureField(change: .field) : .unchanged },
            landing: { LandingProbe(characterCount: 3, selectedLength: 0) }, paster: paster)
        XCTAssertEqual(result, .heldForSecureField(.field))
        XCTAssertEqual(paster.settlements, [.withdrawn], "never left on the clipboard by the keep setting")
        paster.settle()
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testTransformedPasteAnyCountChangeConfirms() async {
        var count = 3
        paster.afterStaging = { count = 4 } // host trimmed or transformed the paste
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: count, selectedLength: 0) }, paster: paster)
        XCTAssertEqual(result, .unknownConfirmed)
    }

    func testDelayedCountChangeConfirmsBeforeTimeout() async {
        var reads = 0
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: {
                reads += 1
                return LandingProbe(characterCount: reads >= 4 ? 4 : 3, selectedLength: 0)
            }, paster: paster)
        XCTAssertEqual(result, .unknownConfirmed)
        XCTAssertEqual(paster.events, ["stage", "⌘V", "↩"])
        XCTAssertLessThan(reads, 7)
    }

    func testSameLengthSelectionCannotProvePasteFailed() async {
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: 3, selectedLength: self.text.utf16.count) }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable)
    }

    func testUnknownReturnFollowsFirstPositiveRead() async {
        var reads = 0
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { reads += 1; return LandingProbe(characterCount: reads == 1 ? 3 : 4, selectedLength: 0) },
            paster: paster)
        XCTAssertEqual(result, .unknownConfirmed)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(paster.events, ["stage", "⌘V", "↩"])
    }

    func testUnreadableReturnWaitsOnlyOneInterval() async {
        var reads = 0
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { reads += 1; return nil }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(paster.events, ["stage", "⌘V", "↩"])
    }

    func testUnknownCountUsesAXUTF16UnitsAndSelectedRange() async {
        let words = "🌙"
        var count = 10
        paster.afterStaging = { count = 10 - 3 + words.utf16.count }
        let result = await TargetedDelivery.deliver(
            text: words, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: count, selectedLength: 3) }, paster: paster)
        XCTAssertEqual(result, .unknownConfirmed)
    }

    func testUnknownPasteNotLandedShowsCard() async {
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: 3, selectedLength: 0) }, paster: paster)
        XCTAssertEqual(result, .unknownNotLanded)
        XCTAssertEqual(result.logSummary, "delivery=copied reason=paste-unconfirmed landing=not-landed clipboard=kept")
        paster.settle()
        XCTAssertEqual(paster.clipboard, text)
    }

    func testUnknownNotLandedKeepsTheStagedDictationWithoutCopyingAgain() async {
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: 3, selectedLength: 0) },
            noFieldClipboard: .copyAutomatically, paster: paster)
        XCTAssertEqual(result, .unknownNotLanded)
        XCTAssertEqual(paster.events, ["stage", "⌘V"], "the staged text is already on the clipboard")
    }

    func testUnknownNotLandedNeverSendsReturn() async {
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: 3, selectedLength: 0) }, paster: paster)
        XCTAssertEqual(result, .unknownNotLanded)
        XCTAssertEqual(paster.events, ["stage", "⌘V"])
    }

    func testUnknownUnreadableKeepsStagedDictation() async {
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { nil }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable)
        XCTAssertEqual(result.logSummary, "delivery=pasted landing=unreadable clipboard=kept reason=unconfirmed")
        paster.settle()
        XCTAssertEqual(paster.clipboard, text)
    }

    func testUnreadablePasteWithReturnSkippedAlsoKeepsTheStagedText() async {
        paster.returnKeySucceeds = false
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { nil }, paster: paster)
        paster.settle()
        XCTAssertEqual(result, .unknownUnreadableReturnSkipped(nil))
        XCTAssertEqual(paster.clipboard, text)
    }

    func testUnknownStillHonorsMovedAndSecureTargets() async {
        focus.switchToChat()
        let moved = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { nil }, paster: paster)
        XCTAssertEqual(moved, .copied(.app))
        XCTAssertEqual(paster.events, ["copy"])
        paster = FakePaster()
        focus.security[200] = .secure
        let secure = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { nil }, paster: paster)
        XCTAssertEqual(secure, .heldForSecureField(.app))
        XCTAssertEqual(paster.events, [])
    }

    func testUnchangedTargetPastesAndRestoresTheClipboard() async {
        let result = await deliver()
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(paster.events, ["stage", "⌘V"])
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
        XCTAssertEqual(result.logSummary, "delivery=pasted")
        XCTAssertTrue(result.reachedTarget)
    }

    func testUnchangedTargetPastesAndPressesReturn() async {
        let result = await deliver(pressReturn: true)
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(paster.events, ["stage", "⌘V", "↩"])
    }

    func testFieldAnswerPreservesAllNormalDeliveryAndReturnEvents() async {
        for pressReturn in [false, true] {
            paster = FakePaster()
            let result = await TargetedDelivery.deliver(
                text: text, pressReturn: pressReturn, answer: .field,
                check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
                landing: { XCTFail("field delivery must not probe"); return nil }, paster: paster)
            XCTAssertEqual(result, .pasted)
            XCTAssertEqual(paster.events, pressReturn ? ["stage", "⌘V", "↩"] : ["stage", "⌘V"])
        }
        paster = FakePaster()
        paster.duringReturnWait = { self.focus.switchToChat() }
        let skipped = await TargetedDelivery.deliver(
            text: text, pressReturn: true, answer: .field,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { XCTFail("field delivery must not probe"); return nil }, paster: paster)
        XCTAssertEqual(skipped, .pastedReturnSkipped(.app))
        XCTAssertEqual(paster.events, ["stage", "⌘V"])
    }

    func testFieldAnswerMatchesOriginalDeliveryForEveryOutcomeFamily() async {
        typealias Setup = (FakeFocus, FakePaster) -> Void
        let scenarios: [(String, String, Bool, Setup)] = [
            ("paste", text, false, { _, _ in }),
            ("paste and Return", text, true, { _, _ in }),
            ("moved", text, true, { focus, _ in focus.switchToChat() }),
            ("secure", text, true, { focus, _ in focus.security[100] = .secure }),
            ("paste failed", text, true, { _, paster in paster.pasteKeySucceeds = false }),
            ("moved during paste", text, true, { focus, paster in
                paster.afterStaging = { focus.switchToChat() }
            }),
            ("Return withheld", text, true, { focus, paster in
                paster.duringReturnWait = { focus.switchToChat() }
            }),
            ("Return only", "", true, { _, _ in }),
            ("Return only moved", "", true, { focus, _ in focus.switchToChat() }),
            ("Return only secure", "", true, { focus, _ in focus.security[100] = .secure }),
            ("Return key failed", "", true, { _, paster in paster.returnKeySucceeds = false }),
            ("empty", "", false, { _, _ in }),
        ]
        for (name, body, pressReturn, setup) in scenarios {
            var outcomes: [(DeliveryResult, [String])] = []
            for useAnswer in [false, true] {
                let focus = FakeFocus()
                let bound = focus.bind()
                let paster = FakePaster()
                setup(focus, paster)
                let check = { TargetGuard.check(bound, reader: focus) }
                let result: DeliveryResult
                if useAnswer {
                    result = await TargetedDelivery.deliver(
                        text: body, pressReturn: pressReturn, answer: .field,
                        check: check, landing: { XCTFail("field must not probe"); return nil }, paster: paster)
                } else {
                    result = await TargetedDelivery.deliver(
                        text: body, pressReturn: pressReturn, hasTextInput: true,
                        check: check, paster: paster)
                }
                outcomes.append((result, paster.events))
            }
            XCTAssertEqual(outcomes[1].0, outcomes[0].0, name)
            XCTAssertEqual(outcomes[1].1, outcomes[0].1, name)
        }
    }

    func testFocusMovingDuringTheReturnWaitKeepsThePasteAndWithholdsReturn() async {
        paster.duringReturnWait = { self.focus.switchToChat() }
        let result = await deliver(pressReturn: true)
        XCTAssertEqual(result, .pastedReturnSkipped(.app))
        XCTAssertEqual(paster.events, ["stage", "⌘V"])
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
        XCTAssertEqual(result.logSummary, "delivery=pasted-no-return reason=target-changed:app")
        XCTAssertTrue(result.reachedTarget)
    }

    func testCancellationDuringTheReturnWaitWithholdsReturnWithoutAReason() async {
        paster.duringReturnWait = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await deliver(pressReturn: true)
        XCTAssertEqual(result, .pastedReturnSkipped(nil))
        XCTAssertEqual(result.logSummary, "delivery=pasted-no-return reason=not-current")
    }

    // MARK: Target moved before the paste → copy, never paste

    func testSwitchingAppsCopiesInsteadOfPasting() async {
        focus.switchToChat()
        let result = await deliver(pressReturn: true)
        XCTAssertEqual(result, .copied(.app))
        XCTAssertEqual(paster.events, ["copy"], "no ⌘V and no Return anywhere")
        XCTAssertEqual(paster.clipboard, text, "left on the clipboard for ⌘V")
        XCTAssertEqual(result.logSummary, "delivery=copied reason=target-changed:app")
        XCTAssertFalse(result.reachedTarget)
    }

    func testAnotherFieldInTheSameAppCopiesInsteadOfPasting() async {
        focus.fields[FakeFocus.mailPID] = 101
        let result = await deliver()
        XCTAssertEqual(result, .copied(.field))
        XCTAssertEqual(paster.events, ["copy"])
        XCTAssertEqual(result.logSummary, "delivery=copied reason=target-changed:field")
    }

    func testClosedFieldCopiesInsteadOfPasting() async {
        focus.destroyed.insert(100)
        focus.fields[FakeFocus.mailPID] = nil
        let result = await deliver()
        XCTAssertEqual(result, .copied(.fieldClosed))
        XCTAssertEqual(paster.clipboard, text)
        XCTAssertEqual(result.logSummary, "delivery=copied reason=target-changed:field-closed")
    }

    func testFocusMovingBetweenStagingAndPasteCopiesAndCancelsTheRestore() async {
        paster.afterStaging = { self.focus.switchToChat() }
        let result = await deliver()
        XCTAssertEqual(result, .copied(.app))
        XCTAssertEqual(paster.events, ["stage", "copy"], "⌘V never sent")
        XCTAssertEqual(paster.clipboard, text, "the pending restore must not wipe the copied text")
    }

    func testHandsFreeFocusThatCameBackBeforeTheEndPastes() async {
        focus.switchToChat() // wandered off mid-recording…
        focus.front = (FakeFocus.mailPID, FakeFocus.mail) // …and came back before finishing
        let result = await deliver()
        XCTAssertEqual(result, .pasted)
    }

    // MARK: Password fields: never paste, never stage

    func testMovingToAPasswordFieldHoldsTheTextAndLeavesTheClipboardAlone() async {
        focus.switchToChat()
        focus.security[200] = .secure
        let result = await deliver(pressReturn: true)
        XCTAssertEqual(result, .heldForSecureField(.app))
        XCTAssertEqual(paster.events, [])
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
        XCTAssertEqual(result.logSummary, "delivery=held reason=secure-field target-changed:app")
    }

    func testBoundFieldThatIsAPasswordFieldIsHeld() async {
        focus.security[100] = .secure
        bound = focus.bind()
        let result = await deliver()
        XCTAssertEqual(result, .heldForSecureField(nil))
        XCTAssertEqual(paster.events, [])
        XCTAssertEqual(result.logSummary, "delivery=held reason=secure-field")
    }

    func testPasswordFieldAppearingBetweenStagingAndPasteRestoresTheUsersClipboard() async {
        paster.afterStaging = {
            self.focus.fields[FakeFocus.mailPID] = 101
            self.focus.security[101] = .secure
        }
        let result = await deliver()
        XCTAssertEqual(result, .heldForSecureField(.field))
        XCTAssertEqual(paster.events, ["stage"], "⌘V never sent")
        XCTAssertEqual(paster.clipboard, paster.userClipboard, "staged text is restored away, not left for ⌘V")
    }

    // MARK: Command-only "press enter"

    func testReturnOnlyReachesTheBoundField() async {
        let result = await deliver("", pressReturn: true)
        XCTAssertEqual(result, .returnSent)
        XCTAssertEqual(paster.events, ["↩"])
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testReturnOnlyAfterSwitchingAppsSendsNothing() async {
        focus.switchToChat()
        let result = await deliver("", pressReturn: true)
        XCTAssertEqual(result, .returnWithheld(.app))
        XCTAssertEqual(paster.events, [])
        XCTAssertEqual(paster.clipboard, paster.userClipboard, "nothing to copy")
        XCTAssertEqual(result.logSummary, "delivery=return-withheld reason=target-changed:app")
    }

    func testReturnOnlyIntoAPasswordFieldSendsNothing() async {
        focus.security[100] = .secure
        bound = focus.bind()
        let result = await deliver("", pressReturn: true)
        XCTAssertEqual(result, .returnWithheld(nil))
        XCTAssertEqual(result.logSummary, "delivery=return-withheld reason=secure-field")
    }

    func testReturnOnlyFocusMovingDuringTheWaitSendsNothing() async {
        paster.duringReturnWait = { self.focus.fields[FakeFocus.mailPID] = 101 }
        let result = await deliver("", pressReturn: true)
        XCTAssertEqual(result, .returnWithheld(.field))
        XCTAssertEqual(paster.events, [])
    }

    func testReturnOnlyCancelledDuringTheWaitIsCancelled() async {
        paster.duringReturnWait = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await deliver("", pressReturn: true)
        XCTAssertEqual(result, .cancelled)
    }

    func testReturnOnlyKeyFailureIsReported() async {
        paster.returnKeySucceeds = false
        let result = await deliver("", pressReturn: true)
        XCTAssertEqual(result, .dispatchFailed(copied: false))
        XCTAssertEqual(paster.clipboard, paster.userClipboard, "nothing to copy")
        XCTAssertEqual(result.logSummary, "delivery=not-pasted reason=dispatch-failed")
    }

    func testEmptyTextWithoutReturnDispatchesNothing() async {
        let result = await deliver("", pressReturn: false)
        XCTAssertEqual(result, .dispatchFailed(copied: false))
        XCTAssertEqual(paster.events, [])
    }

    // MARK: No text field at key-down → copy for ⌘V (UI round 2026-09-28 §1, A3)

    func testNoTextFieldAtKeyDownCopiesForManualPasteAndNeverTouchesKeys() async {
        let result = await deliver(pressReturn: true, hasTextInput: false, noFieldClipboard: .copyAutomatically)
        XCTAssertEqual(result, .noField(copied: true))
        XCTAssertEqual(paster.events, ["copy"], "no ⌘V and no Return anywhere")
        XCTAssertEqual(paster.clipboard, text, "left on the clipboard for ⌘V, not restored away")
        XCTAssertEqual(result.logSummary, "delivery=copied reason=no-field")
        XCTAssertFalse(result.reachedTarget)
    }

    func testNoTextFieldAtKeyDownIsNotRescuedByALaterField() async {
        focus.switchToChat() // the user found a field after starting on the desktop
        let result = await deliver(hasTextInput: false, noFieldClipboard: .copyAutomatically)
        XCTAssertEqual(result, .noField(copied: true))
        XCTAssertEqual(paster.events, ["copy"], "copied, never pasted into the new field")
    }

    func testNoTextFieldWithAPasswordFieldFocusedNowHoldsAndLeavesTheClipboardAlone() async {
        focus.switchToChat()
        focus.security[200] = .secure
        let result = await deliver(hasTextInput: false)
        XCTAssertEqual(result, .heldForSecureField(.app))
        XCTAssertEqual(paster.events, [])
        XCTAssertEqual(paster.clipboard, paster.userClipboard, "never staged beside a password field")
    }

    func testNoTextFieldWithAFieldOfUnknownSecurityFocusedNowFailsClosed() async {
        focus.switchToChat()
        focus.security[200] = .unknown
        let result = await deliver(hasTextInput: false)
        XCTAssertEqual(result, .heldForSecureField(.app))
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    // MARK: No field: the clipboard rule (`NoFieldClipboardPolicy`)

    func testNoFieldDefaultCopiesForManualPasteAndNothingIsTyped() async {
        XCTAssertEqual(NoFieldClipboardPolicy.current, .copyAutomatically, "the shipped default")
        let result = await deliver(pressReturn: true, hasTextInput: false)
        XCTAssertEqual(result, .noField(copied: true))
        XCTAssertEqual(paster.events, ["copy"], "no ⌘V, no Return")
        XCTAssertEqual(paster.clipboard, text, "on the clipboard for the person to paste themselves")
        XCTAssertEqual(result.logSummary, "delivery=copied reason=no-field")
        XCTAssertFalse(result.reachedTarget)
    }

    func testNoFieldLeaveClipboardAloneIsStillOneCaseAway() async {
        let result = await deliver(pressReturn: true, hasTextInput: false, noFieldClipboard: .leaveClipboardAlone)
        XCTAssertEqual(result, .noField(copied: false))
        XCTAssertEqual(paster.events, [], "no copy, no ⌘V, no Return")
        XCTAssertEqual(paster.clipboard, paster.userClipboard, "the user's clipboard is not overwritten")
        XCTAssertEqual(result.logSummary, "delivery=not-pasted reason=no-field")
        XCTAssertFalse(result.reachedTarget)
    }

    func testNoFieldCopyAutomaticallyKeepsTheOldBehaviour() async {
        let result = await deliver(hasTextInput: false, noFieldClipboard: .copyAutomatically)
        XCTAssertEqual(result, .noField(copied: true))
        XCTAssertEqual(paster.clipboard, text)
    }

    func testNoFieldPolicyChangesNothingWhenThereIsAField() async {
        for policy in [NoFieldClipboardPolicy.leaveClipboardAlone, .copyAutomatically] {
            let result = await deliver(hasTextInput: true, noFieldClipboard: policy)
            XCTAssertEqual(result, .pasted, "\(policy)")
        }
    }

    func testNoFieldPolicyChangesNothingForAMovedTarget() async {
        focus.switchToChat()
        let result = await deliver(noFieldClipboard: .leaveClipboardAlone)
        XCTAssertEqual(result, .copied(.app), "a moved target is still copied for ⌘V")
        XCTAssertEqual(paster.clipboard, text)
    }

    func testNoFieldWithAPasswordFieldIsHeldUnderEveryPolicy() async {
        focus.switchToChat()
        focus.security[200] = .secure
        for policy in [NoFieldClipboardPolicy.leaveClipboardAlone, .copyAutomatically] {
            let result = await deliver(hasTextInput: false, noFieldClipboard: policy)
            XCTAssertEqual(result, .heldForSecureField(.app), "\(policy)")
            XCTAssertEqual(paster.clipboard, paster.userClipboard)
        }
    }

    func testNoTextFieldWithNothingToCopyTouchesNothing() async {
        let result = await deliver("", pressReturn: true, hasTextInput: false)
        XCTAssertEqual(result, .noField(copied: false))
        XCTAssertEqual(paster.events, [], "a command-only Return is never sent without a field")
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
        XCTAssertEqual(result.logSummary, "delivery=not-pasted reason=no-field")
    }

    func testNoTextFieldCancelledBeforeDeliveryCopiesNothing() async {
        withUnsafeCurrentTask { $0?.cancel() }
        let result = await deliver(hasTextInput: false)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(paster.events, [], "a superseded dictation must not overwrite a newer copy")
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    // MARK: Paste failed (dispatch) → copy for ⌘V (A3)

    func testPasteKeyFailureCopiesForManualPasteAndCancelsTheRestore() async {
        paster.pasteKeySucceeds = false
        let result = await deliver(pressReturn: true)
        XCTAssertEqual(result, .dispatchFailed(copied: true))
        XCTAssertEqual(paster.events, ["stage", "⌘V", "copy"], "no Return after a failed paste")
        XCTAssertEqual(paster.clipboard, text, "the staged paste's restore must not wipe the copy")
        XCTAssertEqual(result.logSummary, "delivery=copied reason=dispatch-failed")
        XCTAssertFalse(result.reachedTarget)
    }

    func testPasteKeyFailureWithAPasswordFieldFocusedNowHoldsAndRestoresTheClipboard() async {
        paster.pasteKeySucceeds = false
        let failing = SecureAfterPastePaster(inner: paster) {
            // After the failed ⌘V the user clicks into a password field in the same window.
            self.focus.fields[FakeFocus.mailPID] = 101
            self.focus.security[101] = .secure
        }
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, hasTextInput: true,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) }, paster: failing)
        paster.settle()
        XCTAssertEqual(result, .heldForSecureField(.field))
        XCTAssertFalse(paster.events.contains("copy"), "never staged for ⌘V beside a password field")
        XCTAssertEqual(paster.clipboard, paster.userClipboard, "the failed paste's staging is restored away")
    }

    func testPasteKeyFailureAfterCancellationCopiesNothing() async {
        paster.pasteKeySucceeds = false
        let failing = SecureAfterPastePaster(inner: paster) { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, hasTextInput: true,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) }, paster: failing)
        paster.settle()
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(paster.events.contains("copy"))
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    // MARK: No path logs the text

    func testNoLogSummaryCarriesTheText() {
        let results: [DeliveryResult] = [
            .pasted, .pastedReturnSkipped(.app), .pastedReturnSkipped(nil), .returnSent, .returnWithheld(.field),
            .returnWithheld(nil), .copied(.window), .heldForSecureField(.app), .heldForSecureField(nil),
            .noField(copied: true), .noField(copied: false), .dispatchFailed(copied: true),
            .dispatchFailed(copied: false), .cancelled, .unknownConfirmed,
            .unknownConfirmedReturnSkipped(.app), .unknownUnreadable,
            .unknownUnreadableReturnSkipped(nil), .unknownNotLanded, .unknownCancelled,
        ]
        for result in results {
            XCTAssertFalse(result.logSummary.contains("Ship"), "\(result)")
            XCTAssertTrue(result.logSummary.hasPrefix("delivery="), "\(result)")
        }
    }

    // MARK: Other exits

    func testCancelledBeforeDeliveryTouchesNothing() async {
        withUnsafeCurrentTask { $0?.cancel() }
        let result = await deliver()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(paster.events, [])
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testSupersededWithFocusUnchangedIsCancelledNotCopied() async {
        // A paster that reports the focus-guard failure while focus reads unchanged: a newer
        // insertion took the clipboard. Don't copy over the newer dictation.
        final class SupersededPaster: DeliveryPaster {
            var copied = false
            func paste(_ text: String, pressReturn: Bool, awaitLanding: PasteLanding?, hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome { .focusChanged }
            func finishLanding(_ landing: PasteLanding, as settlement: LandingSettlement) {}
            func sendReturn(hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome { .focusChanged }
            func copyForManualPaste(_ text: String) { copied = true }
        }
        let superseded = SupersededPaster()
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, hasTextInput: true,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) }, paster: superseded)
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(superseded.copied)
        let returnOnly = await TargetedDelivery.deliver(
            text: "", pressReturn: true, hasTextInput: true,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) }, paster: superseded)
        XCTAssertEqual(returnOnly, .cancelled)
    }
}

/// Wraps `FakePaster` and runs `afterPaste` once its paste returns — focus or cancellation that
/// changes between a failed ⌘V and the copy that follows it.
@MainActor
final class SecureAfterPastePaster: DeliveryPaster {
    let inner: FakePaster
    let afterPaste: () -> Void

    init(inner: FakePaster, afterPaste: @escaping () -> Void) {
        self.inner = inner
        self.afterPaste = afterPaste
    }

    func paste(_ text: String, pressReturn: Bool, awaitLanding: PasteLanding?, hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome {
        let outcome = await inner.paste(text, pressReturn: pressReturn, awaitLanding: awaitLanding, hasFocus: hasFocus)
        afterPaste()
        return outcome
    }

    func sendReturn(hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome {
        await inner.sendReturn(hasFocus: hasFocus)
    }

    func finishLanding(_ landing: PasteLanding, as settlement: LandingSettlement) {
        inner.finishLanding(landing, as: settlement)
    }
    func copyForManualPaste(_ text: String) { inner.copyForManualPaste(text) }
}
