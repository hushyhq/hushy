import XCTest
@testable import MurmurCore

@MainActor
final class BoundDeliveryTests: XCTestCase {
    func testProcessChangeBeforePasteDoesNotPrepareClipboardOrDispatchKeys() async {
        var events: [String] = []
        let outcome = await BoundDelivery.perform(
            pressReturn: true,
            isCurrent: { true },
            hasFocus: { events.append("focus-check"); return false },
            prepareClipboard: { events.append("clipboard-write"); return true },
            clipboardIsOwned: { true },
            paste: { events.append("paste"); return true },
            waitBeforeReturn: { events.append("wait") },
            sendReturn: { events.append("return"); return true })

        XCTAssertEqual(outcome, .focusChanged)
        XCTAssertEqual(events, ["focus-check"])
    }

    func testSameProcessDifferentFieldIsBlockedBeforePaste() async {
        let captured = (processID: 42, fieldID: 100)
        let focused = (processID: 42, fieldID: 200)
        var dispatched = false
        let outcome = await BoundDelivery.perform(
            pressReturn: false,
            isCurrent: { true },
            hasFocus: { captured.processID == focused.processID && captured.fieldID == focused.fieldID },
            prepareClipboard: { true }, clipboardIsOwned: { true },
            paste: { dispatched = true; return true }, waitBeforeReturn: {}, sendReturn: { true })

        XCTAssertEqual(outcome, .focusChanged)
        XCTAssertFalse(dispatched)
    }

    func testFocusChangeDuringReturnDelayKeepsPasteAndSkipsReturn() async {
        var focusMatches = true
        var events: [String] = []
        let outcome = await BoundDelivery.perform(
            pressReturn: true,
            isCurrent: { true },
            hasFocus: { focusMatches },
            prepareClipboard: { events.append("clipboard"); return true },
            clipboardIsOwned: { true },
            paste: { events.append("paste"); return true },
            waitBeforeReturn: { focusMatches = false },
            sendReturn: { events.append("return"); return true })

        XCTAssertEqual(outcome, .pastedReturnSkipped)
        XCTAssertEqual(events, ["clipboard", "paste"])
    }

    func testCancellationDuringReturnDelaySkipsReturn() async {
        var events: [String] = []
        let outcome = await BoundDelivery.perform(
            pressReturn: true,
            isCurrent: { true },
            hasFocus: { true },
            prepareClipboard: { events.append("clipboard"); return true },
            clipboardIsOwned: { true },
            paste: { events.append("paste"); return true },
            waitBeforeReturn: { withUnsafeCurrentTask { $0?.cancel() } },
            sendReturn: { events.append("return"); return true })

        XCTAssertEqual(outcome, .pastedReturnSkipped)
        XCTAssertEqual(events, ["clipboard", "paste"])
    }

    func testReturnOnlySendsReturnWithoutTouchingClipboard() async {
        var events: [String] = []
        let outcome = await BoundDelivery.performReturnOnly(
            isCurrent: { true },
            hasFocus: { events.append("focus-check"); return true },
            waitBeforeReturn: { events.append("wait") },
            sendReturn: { events.append("return"); return true })

        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(events, ["focus-check", "wait", "focus-check", "return"])
    }

    func testReturnOnlyFocusChangeBeforeWaitNeverSendsReturn() async {
        var sent = false
        let outcome = await BoundDelivery.performReturnOnly(
            isCurrent: { true },
            hasFocus: { false },
            waitBeforeReturn: { XCTFail("should not wait when focus is already gone") },
            sendReturn: { sent = true; return true })

        XCTAssertEqual(outcome, .focusChanged)
        XCTAssertFalse(sent)
    }

    func testReturnOnlyFocusChangeDuringWaitSkipsReturn() async {
        var focusMatches = true
        var sent = false
        let outcome = await BoundDelivery.performReturnOnly(
            isCurrent: { true },
            hasFocus: { focusMatches },
            waitBeforeReturn: { focusMatches = false },
            sendReturn: { sent = true; return true })

        XCTAssertEqual(outcome, .focusChanged)
        XCTAssertFalse(sent)
    }

    func testReturnOnlyDispatchFailureIsReported() async {
        let outcome = await BoundDelivery.performReturnOnly(
            isCurrent: { true },
            hasFocus: { true },
            waitBeforeReturn: {},
            sendReturn: { false })

        XCTAssertEqual(outcome, .dispatchFailed)
    }

    func testExternalCopyBecomesNextInsertionRestoreSnapshot() {
        var ledger = ClipboardSnapshotLedger<String>()
        ledger.record("original user clipboard", at: 10)

        let snapshot = ledger.original(currentChangeCount: 11) { "user's later copy" }
        ledger.record(snapshot, at: 12)
        ledger.clear(ifChangeCount: 10) // Old restore task must not clear the newer insertion.

        XCTAssertEqual(snapshot, "user's later copy")
        XCTAssertEqual(ledger.original(currentChangeCount: 12) { "unexpected" }, "user's later copy")
    }
}
