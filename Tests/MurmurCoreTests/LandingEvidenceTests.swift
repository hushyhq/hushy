import XCTest
@testable import MurmurCore

/// What counts as "the paste landed", and what counts as "the field was read and it did not".
/// Only a read of the field may confirm: a confirmed paste restores the earlier clipboard, so a
/// false one can lose the dictation.
@MainActor
final class LandingEvidenceTests: XCTestCase {
    private let text = "Vela raises the amber sail."

    private func probe(count: Int? = nil, selected: Int? = nil, caret: Int? = nil) -> LandingProbe {
        LandingProbe(characterCount: count, selectedLength: selected, caretLocation: caret)
    }

    // MARK: The signal

    /// 27 UTF-16 units, no line breaks.
    private var pasted: PastedText { PastedText(text) }

    private func signal(_ before: LandingProbe, _ after: LandingProbe, pasted: PastedText? = nil) -> LandingSignal? {
        LandingEvidence.signal(before: before, after: after, pasted: pasted ?? self.pasted)
    }

    func testACharacterCountThatChangedConfirms() {
        XCTAssertEqual(signal(probe(count: 3), probe(count: 30)), .count)
        XCTAssertEqual(signal(probe(count: 30), probe(count: 3)), .count,
                       "a paste over a longer selection shortens the field")
    }

    func testACaretThatAdvancedByThePastedLengthConfirmsWhereTheCountCannotBeRead() {
        XCTAssertEqual(pasted.length, 27)
        XCTAssertEqual(signal(probe(caret: 4), probe(caret: 31)), .caret)
        XCTAssertEqual(signal(probe(caret: 0), probe(selected: 0, caret: 27)), .caret)
    }

    func testAPasteOverASelectionEndsAtTheSelectionStartPlusThePastedLength() {
        // The caret is where the selection starts, so replacing 12 selected characters still
        // moves it by exactly what was pasted. Same when the selection was as long as the paste.
        XCTAssertEqual(signal(probe(count: 40, selected: 12, caret: 4), probe(count: 55, selected: 0, caret: 31)), .count)
        XCTAssertEqual(signal(probe(selected: 12, caret: 4), probe(selected: 0, caret: 31)), .caret)
        XCTAssertEqual(signal(probe(count: 40, selected: 27, caret: 4), probe(count: 40, selected: 0, caret: 31)), .caret)
    }

    func testAJumpOfTheWrongSizeDoesNotConfirm() {
        // An arrow key, a click elsewhere in the field, a tree that settled between the reads.
        for moved in [5, 9, 30, 32, 58, 400] {
            XCTAssertNil(signal(probe(caret: 4), probe(caret: moved)), "caret 4 → \(moved)")
        }
    }

    func testABackwardJumpDoesNotConfirm() {
        XCTAssertNil(signal(probe(caret: 31), probe(caret: 4)))
        XCTAssertNil(signal(probe(caret: 27), probe(caret: 0)))
    }

    func testACaretThatDidNotMoveDoesNotConfirm() {
        XCTAssertNil(signal(probe(caret: 4), probe(caret: 4)))
    }

    func testANotFoundLocationOnEitherSideNeverConfirms() {
        // -1 → 26 is an advance of exactly 27, and still proves nothing.
        XCTAssertNil(signal(probe(caret: -1), probe(caret: 26)))
        XCTAssertNil(signal(probe(caret: -28), probe(caret: -1)))
        XCTAssertNil(signal(probe(caret: Int.max), probe(caret: 31)))
        XCTAssertNil(signal(probe(caret: 4), probe(caret: Int.max)))
        XCTAssertNil(signal(probe(caret: Int.max - 27), probe(caret: Int.max)))
        XCTAssertNil(signal(probe(caret: Int.min), probe(caret: Int.max)), "and never overflows")
    }

    func testACaretThatAdvancedButLeftASelectionIsNotAPaste() {
        // A paste leaves nothing selected; a drag or shift-arrow does.
        XCTAssertNil(signal(probe(selected: 0, caret: 4), probe(selected: 6, caret: 31)))
    }

    func testLineEndingsMayAddOrRemoveOneUnitEach() {
        let lines = PastedText("Dear Dana,\nthe ferry leaves at nine.\nVela")
        XCTAssertEqual(lines.length, 41)
        XCTAssertEqual(lines.lineBreaks, 2)
        for advance in [39, 40, 41, 42, 43] {
            XCTAssertEqual(signal(probe(caret: 10), probe(caret: 10 + advance), pasted: lines), .caret, "\(advance)")
        }
        for advance in [38, 44, 20, 1] {
            XCTAssertNil(signal(probe(caret: 10), probe(caret: 10 + advance), pasted: lines), "\(advance)")
        }
    }

    func testWithNoLineBreaksTheAdvanceMustBeExact() {
        XCTAssertEqual(pasted.lineBreaks, 0)
        XCTAssertNil(signal(probe(caret: 4), probe(caret: 30)))
        XCTAssertNil(signal(probe(caret: 4), probe(caret: 32)))
    }

    func testPastedTextCountsUTF16UnitsAndEveryLineBreakUnit() {
        let windows = PastedText("a\r\nb\nc")
        XCTAssertEqual(windows.length, 6)
        XCTAssertEqual(windows.lineBreaks, 3)
        XCTAssertEqual(PastedText("🌙").length, 2)
        XCTAssertEqual(PastedText("").length, 0)
    }

    func testAnEmptyPasteNeverConfirmsByCaret() {
        XCTAssertNil(signal(probe(caret: 4), probe(caret: 4), pasted: PastedText("")))
        XCTAssertNil(signal(probe(caret: 4), probe(caret: 5), pasted: PastedText("\n\n")),
                     "a paste of nothing but line breaks has no length the caret could prove")
        XCTAssertNil(signal(probe(caret: 4), probe(caret: 6), pasted: PastedText("\n\n")))
    }

    func testTheCountIsNamedFirstWhenBothMoved() {
        XCTAssertEqual(signal(probe(count: 3, caret: 3), probe(count: 30, caret: 30)), .count)
    }

    func testNothingChangedIsNoSignal() {
        XCTAssertNil(signal(probe(count: 3, selected: 0, caret: 3), probe(count: 3, selected: 0, caret: 3)))
    }

    func testAValueThatOnlyBecameReadableIsNotAChange() {
        // No baseline: a count or caret first seen after ⌘V says nothing about what the paste did.
        XCTAssertNil(signal(probe(), probe(count: 30, caret: 27)))
        XCTAssertNil(signal(probe(count: 3), probe(caret: 30)))
        XCTAssertNil(signal(probe(caret: 3), probe(count: 30)))
    }

    func testAValueThatStoppedBeingReadableIsNotAChange() {
        XCTAssertNil(signal(probe(count: 3, caret: 3), probe()))
    }

    func testASelectionLengthAloneNeverConfirms() {
        XCTAssertNil(signal(probe(selected: 5), probe(selected: 0)))
    }

    // MARK: Read, and unchanged

    func testACountReadBeforeAndAfterAndUnchangedIsEvidenceThePasteFailed() {
        XCTAssertTrue(LandingEvidence.wasReadAndUnchanged(
            before: probe(count: 3, selected: 0), last: probe(count: 3, selected: 0), pasted: PastedText(length: 27)))
    }

    func testAnUnmovedCaretAloneIsNotEvidenceOfFailure() {
        XCTAssertFalse(LandingEvidence.wasReadAndUnchanged(
            before: probe(selected: 0, caret: 3), last: probe(selected: 0, caret: 3), pasted: PastedText(length: 27)))
    }

    func testASelectionOfThePastedLengthCannotProveFailure() {
        XCTAssertFalse(LandingEvidence.wasReadAndUnchanged(
            before: probe(count: 30, selected: 27), last: probe(count: 30, selected: 0), pasted: PastedText(length: 27)))
    }

    func testAnUnknownSelectionCannotProveFailure() {
        XCTAssertFalse(LandingEvidence.wasReadAndUnchanged(
            before: probe(count: 30), last: probe(count: 30), pasted: PastedText(length: 27)))
    }

    func testACountThatCouldNotBeReadAfterwardsCannotProveFailure() {
        XCTAssertFalse(LandingEvidence.wasReadAndUnchanged(
            before: probe(count: 3, selected: 0), last: probe(selected: 0, caret: 3), pasted: PastedText(length: 27)))
    }

    // MARK: Through the delivery decision

    private func deliver(_ landing: @escaping () -> LandingProbe?, paster: FakePaster) async -> DeliveryResult {
        await TargetedDelivery.deliver(text: text, pressReturn: false, answer: .unknown,
                                       check: { .unchanged }, landing: landing, paster: paster)
    }

    func testACaretOnlyFieldIsConfirmedAndTheEarlierClipboardComesBack() async {
        let paster = FakePaster()
        var caret = 4
        paster.afterStaging = { caret = 4 + self.text.utf16.count }
        let result = await deliver({ self.probe(selected: 0, caret: caret) }, paster: paster)
        XCTAssertEqual(result, .unknownConfirmed)
        paster.settle()
        XCTAssertEqual(paster.clipboard, paster.userClipboard)
    }

    func testACaretOnlyFieldThatNeverMovesKeepsTheDictationAndIsNotCalledAFailure() async {
        let paster = FakePaster()
        let result = await deliver({ self.probe(selected: 0, caret: 4) }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable, "the field was not read well enough to say the paste failed")
        paster.settle()
        XCTAssertEqual(paster.clipboard, text)
    }

    func testACaretThatJumpedByTheWrongAmountDuringTheCheckKeepsTheDictation() async {
        // The person pressed an arrow key, or clicked in the field, while Hushy was checking.
        let paster = FakePaster()
        var caret = 4
        paster.afterStaging = { caret = 7 }
        let result = await deliver({ self.probe(selected: 0, caret: caret) }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable)
        paster.settle()
        XCTAssertEqual(paster.clipboard, text, "a wrong confirm would have put the earlier clipboard back")
    }

    func testACaretThatAppearedFromNotFoundKeepsTheDictation() async {
        let paster = FakePaster()
        var caret = -1
        paster.afterStaging = { caret = -1 + self.text.utf16.count }
        let result = await deliver({ self.probe(selected: 0, caret: caret) }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable)
        paster.settle()
        XCTAssertEqual(paster.clipboard, text)
    }

    // MARK: The same field before and after

    func testTheFirstElementIsPinnedAndOnlyThatOneIsAdmittedAfterwards() {
        var pin = LandingPin<Int>()
        XCTAssertTrue(pin.admits(7, isSame: ==), "the read before ⌘V pins its field")
        XCTAssertTrue(pin.admits(7, isSame: ==))
        XCTAssertFalse(pin.admits(8, isSame: ==), "another field in the same window is not the one that was read")
        XCTAssertTrue(pin.admits(7, isSame: ==), "and it stays pinned to the first")
    }

    func testAnotherFieldFocusedAfterThePasteIsNeverComparedWithTheFirst() async {
        // Nothing was bound at key-down, so each read looks at whichever field has focus. The
        // person tabbed to a longer field during the check: its count differs, and proves nothing.
        let paster = FakePaster()
        var focused = 1
        let counts = [1: 3, 2: 40]
        paster.afterStaging = { focused = 2 }
        var pin = LandingPin<Int>()
        let result = await deliver({
            guard pin.admits(focused, isSame: ==) else { return nil }
            return self.probe(count: counts[focused], selected: 0, caret: counts[focused])
        }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable)
        paster.settle()
        XCTAssertEqual(paster.clipboard, text)
    }

    func testACountSeenOnlyAfterThePasteNeverConfirms() async {
        let paster = FakePaster()
        var staged = false
        paster.afterStaging = { staged = true }
        let result = await deliver({ staged ? self.probe(count: 30, selected: 0) : self.probe(selected: 0) }, paster: paster)
        XCTAssertEqual(result, .unknownUnreadable)
        paster.settle()
        XCTAssertEqual(paster.clipboard, text, "no baseline, so the dictation stays on the clipboard")
    }

    func testAReadableCountThatNeverChangesIsStillNotLanded() async {
        let paster = FakePaster()
        let result = await deliver({ self.probe(count: 3, selected: 0, caret: 3) }, paster: paster)
        XCTAssertEqual(result, .unknownNotLanded)
        paster.settle()
        XCTAssertEqual(paster.clipboard, text)
    }
}
