import XCTest
@testable import MurmurCore

/// A paste into a field Hushy is sure of is reported at once, as it always was. Nothing about it waits for
/// a second look, and nothing is read on the way to ⌘V: the "before" of the second look is the read made at
/// key-down. The second look is a separate step the caller runs after the pill has answered.
@MainActor
final class FieldPasteLandingTests: XCTestCase {
    private let text = "Ship it on Thursday."
    private var focus: FakeFocus!
    private var bound: BoundFocus<Int>!
    private var paster: FakePaster!

    override func setUp() async throws {
        focus = FakeFocus()
        bound = focus.bind()
        paster = FakePaster()
    }

    /// Pastes into a known field. `keyDown` is the read of the field made at key-down, the baseline of the second look.
    /// `readsMadeByDeliver` counts every call of the `landing` closure: for a known field it must stay zero.
    private func deliverToField(
        keyDown: LandingProbe? = LandingProbe(characterCount: 3, selectedLength: 0, caretLocation: 3),
        pressReturn: Bool = false
    ) async -> (result: DeliveryResult, watch: FieldPasteWatch?, readsMadeByDeliver: Int) {
        var watch: FieldPasteWatch?
        var count = 0
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: pressReturn, answer: .field,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { count += 1; return nil },
            paster: paster, fieldBaseline: keyDown, onFieldPaste: { watch = $0 })
        paster.settle()
        return (result, watch, count)
    }

    private func late(_ watch: FieldPasteWatch, reads: [LandingProbe?]) async -> LateLanding {
        var index = 0
        return await TargetedDelivery.lateLanding(watch) {
            defer { index += 1 }
            return index < reads.count ? reads[index] : reads.last ?? nil
        }
    }

    private func probe(count: Int, selected: Int = 0, caret: Int? = nil) -> LandingProbe {
        LandingProbe(characterCount: count, selectedLength: selected, caretLocation: caret)
    }

    func testAKnownFieldIsReportedPastedAtOnceWithNoReadBeforeOrAfterCmdV() async throws {
        let (result, watch, reads) = await deliverToField()
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(reads, 0, "no read of the field between key-down and ⌘V, and none after it: the polling belongs to the caller")
        XCTAssertNotNil(watch)
        XCTAssertEqual(paster.events, ["stage", "⌘V"])
        XCTAssertEqual(paster.clipboard, paster.userClipboard, "a pasted dictation still gives the earlier clipboard back")
    }

    func testTheSecondLookConfirmsAPasteThatChangedTheCount() async throws {
        let (_, watch, _) = await deliverToField()
        let landed = await late(try XCTUnwrap(watch), reads: [probe(count: 3 + text.utf16.count)])
        XCTAssertEqual(landed, .confirmed)
    }

    func testTheSecondLookConfirmsAPasteThatMovedTheCaretWhenNoCountCanBeRead() async throws {
        let (_, watch, _) = await deliverToField(keyDown: LandingProbe(characterCount: nil, selectedLength: 0, caretLocation: 10))
        let landed = await late(try XCTUnwrap(watch), reads: [LandingProbe(characterCount: nil, selectedLength: 0, caretLocation: 10 + text.utf16.count)])
        XCTAssertEqual(landed, .confirmed)
    }

    func testAFieldThatNeverChangedIsReportedNotLanded() async throws {
        let (result, watch, _) = await deliverToField()
        XCTAssertEqual(result, .pasted, "the pill answered before anyone knew")
        let landed = await late(try XCTUnwrap(watch), reads: [probe(count: 3)])
        XCTAssertEqual(landed, .notLanded)
    }

    func testAPasteOverASelectionOfItsOwnLengthIsNotCalledNotLanded() async throws {
        let (_, watch, _) = await deliverToField(keyDown: probe(count: 40, selected: text.utf16.count))
        let landed = await late(try XCTUnwrap(watch), reads: [probe(count: 40)])
        XCTAssertNotEqual(landed, .notLanded, "replacing a selection of the same length leaves the count as it was")
    }

    func testAFieldThatCannotBeReadAfterwardsIsUnreadableNotLanded() async throws {
        let (_, watch, _) = await deliverToField()
        let landed = await late(try XCTUnwrap(watch), reads: [nil])
        XCTAssertEqual(landed, .unreadable)
    }

    func testAFieldThatWasNotReadAtKeyDownHasNothingToWatch() async {
        let (result, watch, reads) = await deliverToField(keyDown: nil)
        XCTAssertEqual(result, .pasted)
        XCTAssertNil(watch, "no baseline, so no claim either way")
        XCTAssertEqual(reads, 0, "and no read is made to get one")
    }

    func testNoWatchFollowsAReturn() async {
        let (result, watch, reads) = await deliverToField(pressReturn: true)
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(paster.events, ["stage", "⌘V", "↩"], "the Return went out with the paste")
        XCTAssertNil(watch, "a composer that sends and clears itself reads as unchanged whether or not the paste landed")
        XCTAssertEqual(reads, 0)
    }

    func testALookThatReadsSlowlyGivesUpAndNeverClaimsTheTextIsMissing() async throws {
        let (_, watch, _) = await deliverToField()
        let watchToRun = try XCTUnwrap(watch)
        var reads = 0
        let landed = await TargetedDelivery.lateLanding(watchToRun, within: .milliseconds(300)) {
            reads += 1
            Thread.sleep(forTimeInterval: 0.4)
            return self.probe(count: 3)
        }
        XCTAssertEqual(landed, .unreadable, "every read said unchanged, but the look ran out of time before it could say so")
        XCTAssertLessThan(reads, 5, "no read starts after the limit")
    }

    func testACancelledLookNeverClaimsTheTextIsMissing() async throws {
        let (_, watch, _) = await deliverToField()
        let watchToRun = try XCTUnwrap(watch)
        let task = Task { @MainActor in await self.late(watchToRun, reads: [self.probe(count: 3)]) }
        task.cancel()
        let landed = await task.value
        XCTAssertEqual(landed, .unreadable)
    }

    func testNoWatcherAskedForMeansNoExtraRead() async {
        var reads = 0
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .field,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { reads += 1; return nil }, paster: paster, fieldBaseline: probe(count: 3))
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(reads, 0, "callers that do not ask for the watch keep the hot path exactly as it was")
    }

    func testAMovedTargetIsCopiedAndNeverWatched() async {
        focus.switchToChat()
        let (result, watch, _) = await deliverToField()
        guard case .copied = result else { return XCTFail("expected the moved-target copy, got \(result)") }
        XCTAssertNil(watch)
        XCTAssertEqual(paster.clipboard, text)
    }

    func testAnUncertainTargetStillUsesItsOwnCheckAndNeverTheWatcher() async {
        var watched = false
        var count = 3
        paster.afterStaging = { count = 3 + self.text.utf16.count }
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: .unknown,
            check: { [focus, bound] in TargetGuard.check(bound!, reader: focus!) },
            landing: { LandingProbe(characterCount: count, selectedLength: 0) },
            paster: paster, fieldBaseline: probe(count: 3), onFieldPaste: { _ in watched = true })
        XCTAssertEqual(result, .unknownConfirmed)
        XCTAssertFalse(watched)
    }
}
