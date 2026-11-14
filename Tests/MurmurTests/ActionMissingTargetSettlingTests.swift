import AppKit
import Carbon.HIToolbox
import Foundation
import MurmurCore
import Testing
@testable import Murmur

private struct HistoryWriteFailure: Error {}

/// The question about a list or calendar that isn't there, once it is on the pill: which keys it
/// takes and for how long, what a dismissed one leaves behind, the one usage event a request
/// ends as, History when its overwrite fails, ticks that arrive at the wrong moment, and a name
/// too long for the row. Same fakes and in-memory store as the rest of the suite.
extension ActionMissingTargetTests {
    var notFound: VoiceActionMetricEvent { VoiceActionMetricEvent(outcome: .failed, failure: .notFound) }
    var succeeded: VoiceActionMetricEvent { VoiceActionMetricEvent(outcome: .succeeded, failure: nil) }

    func keyTaken(_ keyCode: Int, _ scope: PillKeyScope) -> PillKey? {
        PillKeyRouter.key(keyCode: keyCode, flags: [], scope: scope)
    }

    /// A card of two that the person confirmed: the first names a list that isn't there, the
    /// second is an ordinary reminder (which fails when `secondFails`).
    func confirmedPair(_ rig: Rig, secondFails: Bool = false) async throws -> ActionConfirmationCardState {
        await rig.controller.dispatch([reminder(), reminder(list: nil, title: "Call Dana")], utterance: "x")
        if secondFails { await rig.calendar.setNextError(.backendFailed("Calendar is busy")) }
        rig.controller.confirmAll()
        await rig.settle { rig.card?.rows.allSatisfy { $0.status != .confirming && $0.status != .pending } == true }
        return try #require(rig.card)
    }

    // MARK: Keys: the first key window only

    @Test("the question takes return and esc in its first key window only; after it both reach the app, a hover changes nothing, and a click still accepts")
    func keysOnlyInTheFirstWindow() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        let until = try #require(rig.pill.cardKeysUntil, "showing the question opens its key window")

        let inside = rig.pill.keyScope(now: until.addingTimeInterval(-0.1), ownTextFieldFocused: false)
        #expect(keyTaken(kVK_Return, inside) == .confirm)
        #expect(keyTaken(kVK_Escape, inside) == .dismiss)
        #expect(rig.pill.keyScope(now: until.addingTimeInterval(-0.1), ownTextFieldFocused: true) == .dismiss,
                "return stays with Hushy's own text field")

        let after = rig.pill.keyScope(now: until.addingTimeInterval(0.1), ownTextFieldFocused: false)
        #expect(after == PillKeyScope.none)
        #expect(keyTaken(kVK_Return, after) == nil, "a Return meant for the app in front reaches it")
        #expect(keyTaken(kVK_Escape, after) == nil, "so does esc, however long the row sits")

        // The pointer crosses the pill ten minutes later: no new window, no keys.
        let later = until.addingTimeInterval(600)
        rig.pill.renewCardKeys(now: later)
        #expect(rig.pill.cardKeysUntil == until)
        let hovered = rig.pill.keyScope(now: later.addingTimeInterval(1), ownTextFieldFocused: false)
        #expect(keyTaken(kVK_Return, hovered) == nil)
        #expect(keyTaken(kVK_Escape, hovered) == nil)

        // The hints promise no key once the window has closed, with or without a hover.
        rig.pill.expireCardKeys()
        rig.pill.renewCardKeys()
        #expect(!rig.pill.showsCardKeys)
        #expect(ActionProblemRow.acceptHint(for: row, keysLive: rig.pill.showsCardKeys) == PillHint(title: "Add to default list", key: nil))
        #expect(ActionProblemRow.dismissHint(for: row, keysLive: rig.pill.showsCardKeys) == PillHint(title: "Dismiss", key: nil))
        #expect(ActionProblemRow.dismissHint(for: row, keysLive: true) == PillHint(title: "Dismiss", key: "esc"))
        #expect(await rig.calendar.createdReminders.isEmpty, "nothing was added by the keys or the hover")

        // It is still there, and the tick still works by click.
        #expect(rig.card?.soleOfferRow?.id == row.id, "the question waits: no timeout takes the reminder with it")
        await accept(rig, row)
        #expect(rig.chip?.canUndo == true)
        #expect(await rig.calendar.createdReminders.map(\.action.title) == ["Team sync"])
    }

    @Test("a hover inside the first window does not stretch it")
    func hoverDoesNotStretchTheWindow() async throws {
        let rig = try Rig()
        _ = try await refusedRow(rig, reminder())
        let until = try #require(rig.pill.cardKeysUntil)
        rig.pill.renewCardKeys(now: until.addingTimeInterval(-1))
        #expect(rig.pill.cardKeysUntil == until)
    }

    @Test("only a card that waits on nothing but the question goes click-only; rows still to confirm and a failure toast keep their keys")
    func clickOnlyIsForTheQuestionAlone() throws {
        let refusal = ActionExecutionError.targetNotFound(.list, "Errands")
        var card = ActionConfirmationCardState(actions: [reminder(), reminder(list: nil, title: "Call Dana")])
        card.rows[0].refuse(refusal, recordID: nil)
        #expect(!card.waitsOnOffer, "the second row is still to confirm")
        let pending = PillModel()
        pending.state = .actionConfirm(card)
        let pendingUntil = try #require(pending.cardKeysUntil)
        #expect(pending.keyScope(now: pendingUntil.addingTimeInterval(1), ownTextFieldFocused: false) == .dismiss)
        pending.renewCardKeys(now: pendingUntil.addingTimeInterval(20))
        #expect(pending.keyScope(now: pendingUntil.addingTimeInterval(21), ownTextFieldFocused: false) == .confirm,
                "a card with rows to confirm still re-opens on hover")

        // The other row is done: only the question keeps the card.
        card.rows[1].status = .succeeded(undoToken: nil)
        #expect(card.waitsOnOffer)
        let waiting = PillModel()
        waiting.state = .actionConfirm(card)
        let waitingUntil = try #require(waiting.cardKeysUntil)
        #expect(waiting.keyScope(now: waitingUntil.addingTimeInterval(-1), ownTextFieldFocused: false) == .dismiss)
        #expect(waiting.keyScope(now: waitingUntil.addingTimeInterval(1), ownTextFieldFocused: false) == PillKeyScope.none)
        waiting.renewCardKeys(now: waitingUntil.addingTimeInterval(20))
        #expect(waiting.keyScope(now: waitingUntil.addingTimeInterval(21), ownTextFieldFocused: false) == PillKeyScope.none)

        // A plain failure toast is unchanged: esc dismisses it for as long as it shows.
        var toast = ActionConfirmationCardState(actions: [reminder(list: nil)])
        toast.rows[0].status = .failed("Calendar is busy")
        let failed = PillModel()
        failed.state = .actionConfirm(toast)
        failed.expireCardKeys()
        #expect(failed.keyScope(now: Date(), ownTextFieldFocused: false) == .dismiss)
    }

    // MARK: A dismissed question lets go of the card

    @Test("a dismissed question no longer holds the card: the other row's failure toast clears as usual")
    func dismissedOfferFreesTheToast() async throws {
        let rig = try Rig()
        let card = try await confirmedPair(rig, secondFails: true)
        #expect(card.rows[0].openOffer == .useDefault(.list, missing: "Errands"))
        #expect(card.rows[1].status == .failed("Calendar is busy"))
        #expect(!card.isFailureToast, "the question is open: the card waits")

        rig.controller.cancel(card.rows[0])
        let after = try #require(rig.card)
        #expect(after.rows[0].status == .cancelled)
        #expect(after.rows[0].offer == nil, "nothing stale is left on the row")
        #expect(after.isFailureToast)
        #expect(PillState.actionConfirm(after).selfDismissDelay == PillState.failureToastDelay)
        #expect(await rig.calendar.createdReminders.isEmpty)
    }

    @Test("an offer counts only on a refused row: one left on a cancelled row holds nothing")
    func staleOfferIsNotAQuestion() {
        var card = ActionConfirmationCardState(actions: [reminder(), reminder(list: nil, title: "Call Dana")])
        card.rows[0].refuse(ActionExecutionError.targetNotFound(.list, "Errands"), recordID: nil)
        card.rows[0].status = .cancelled
        card.rows[1].status = .failed("Calendar is busy")
        #expect(card.rows[0].offer != nil)
        #expect(card.rows[0].openOffer == nil)
        #expect(card.isFailureToast)
        #expect(!card.waitsOnOffer)
        #expect(card.soleOfferRow == nil)
    }

    // MARK: One usage event per request

    @Test("left unanswered, the request is one failed event (not found): the cross, esc, a new action, a dictation, or quitting")
    func unansweredReportsOnce() async throws {
        for leaving in ["cross", "esc", "new action", "dictation", "quit"] {
            let rig = try Rig()
            var events: [VoiceActionMetricEvent] = []
            rig.controller.onMetric = { events.append($0) }
            let row = try await refusedRow(rig, reminder())
            #expect(events.isEmpty, "\(leaving)")
            switch leaving {
            case "cross": rig.controller.cancel(row)
            case "esc": rig.controller.cancelAll()
            case "new action": rig.pill.state = .actionListening
            case "dictation": rig.pill.state = .listening
            default: rig.controller.settleForQuit()
            }
            #expect(events == [notFound], "\(leaving)")
            // Nothing more is reported for it afterwards.
            rig.controller.settleForQuit()
            rig.controller.acceptOffer(row)
            rig.pill.state = .idle
            #expect(events == [notFound], "\(leaving)")
            #expect(records(rig).map(\.status) == [.failed], "\(leaving)")
        }
    }

    @Test("taken but the default can't take it either: one failed event, for why the add failed")
    func takenAndFailedReportsOnce() async throws {
        let rig = try Rig()
        var events: [VoiceActionMetricEvent] = []
        rig.controller.onMetric = { events.append($0) }
        let row = try await refusedRow(rig, reminder())
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        await accept(rig, row)
        #expect(events == [VoiceActionMetricEvent(outcome: .failed, failure: .backendFailed)])
    }

    @Test("a refusal with nothing to offer still reports at once, as before")
    func plainRefusalReportsAtOnce() async throws {
        let rig = try Rig()
        var events: [VoiceActionMetricEvent] = []
        rig.controller.onMetric = { events.append($0) }
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        _ = try await refusedRow(rig, reminder(list: nil))
        #expect(events == [VoiceActionMetricEvent(outcome: .failed, failure: .backendFailed)])
    }

    @Test("a refused row dismissed in a card of several: nothing added for it, one failed event, the other row untouched")
    func dismissedInACardOfSeveral() async throws {
        let rig = try Rig()
        var events: [VoiceActionMetricEvent] = []
        rig.controller.onMetric = { events.append($0) }
        let card = try await confirmedPair(rig)
        #expect(events == [succeeded], "the other row is in; the question has not been answered")

        rig.controller.cancel(card.rows[0])
        #expect(rig.pill.state == .idle, "every row is settled")
        #expect(events == [succeeded, notFound])
        rig.controller.acceptOffer(card.rows[0])
        #expect(rig.pill.state == .idle)
        #expect(await createdAfterDrain(rig) == ["Call Dana", "Marker 1", "Marker 2"])
        #expect(records(rig).map(\.status) == [.failed])
        #expect(records(rig, titled: "Call Dana").map(\.status) == [.completed])
    }

    // MARK: Ticks at the wrong moment

    @Test("a second tick, return or button while the add is running adds nothing more")
    func tickWhileAdding() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        await rig.calendar.holdCreates()
        rig.controller.acceptOffer(row)
        var tries = 0
        while await rig.calendar.heldCount < 1, tries < 400 {
            try? await Task.sleep(for: .milliseconds(5))
            tries += 1
        }
        #expect(await rig.calendar.heldCount == 1, "the add is in flight")

        let running = try #require(rig.card?.rows.first)
        #expect(running.status == .confirming)
        rig.controller.acceptOffer(row)
        rig.controller.acceptOffer(running)
        rig.controller.confirmAll()
        #expect(rig.card?.rows.first == running, "the row is untouched by a tick that came too late")

        await rig.calendar.release()
        await rig.settle { rig.chip != nil }
        #expect(await createdAfterDrain(rig) == ["Team sync", "Marker 1", "Marker 2"])
        #expect(records(rig).map(\.status) == [.completed])
    }

    @Test("a tick on a question that a new utterance has replaced does nothing; the new question is its own")
    func tickAfterReplaced() async throws {
        let rig = try Rig()
        var events: [VoiceActionMetricEvent] = []
        rig.controller.onMetric = { events.append($0) }
        let old = try await refusedRow(rig, reminder())
        let newer = try await refusedRow(rig, reminder(list: "Chores", title: "Water plants"))
        #expect(events == [notFound], "the first request ended unanswered when the second took the pill")

        rig.controller.acceptOffer(old)
        #expect(rig.card?.rows == [newer], "the showing question is not touched by the old row's tick")
        await accept(rig, newer)
        #expect(await createdAfterDrain(rig) == ["Water plants", "Marker 1", "Marker 2"])
        #expect(records(rig).map(\.status) == [.failed])
        #expect(records(rig, titled: "Water plants").map(\.status) == [.completed])
        #expect(Array(events.prefix(2)) == [notFound, succeeded])
    }

    @Test("Undo after the offer gives the free action back")
    func undoGivesTheUseBack() async throws {
        let rig = try Rig()
        rig.controller.isEntitled = { false }
        let row = try await refusedRow(rig, reminder())
        await accept(rig, row)
        #expect(try rig.store.voiceActionsThisMonth() == 1)
        rig.controller.undoDone()
        await rig.settle { rig.chip?.undone == true || rig.chip?.undoFailure != nil }
        #expect(rig.chip?.undone == true)
        #expect(try rig.store.voiceActionsThisMonth() == 0)
        #expect(records(rig).map(\.status) == [.undone])
    }

    // MARK: History when the overwrite fails

    @Test("if History can't be written over the refused row, the added item gets a row of its own, so Undo exists and works")
    func historyOverwriteFails() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        let refusedID = try #require(rig.records.first?.id)
        let store = rig.store
        rig.controller.saveRecord = { record in
            guard record.id == nil else { throw HistoryWriteFailure() }
            return try store.save(record)
        }
        await accept(rig, row)

        #expect(await rig.calendar.createdReminders.count == 1)
        let chip = try #require(rig.chip)
        #expect(chip.canUndo, "the item exists, so the chip can take it back")
        let all = records(rig)
        #expect(all.count == 2)
        let done = try #require(all.first { $0.status == .completed })
        #expect(done.id != refusedID)
        #expect(done.undoBackendID != nil)
        #expect(all.contains { $0.id == refusedID && $0.status == .failed }, "the refused row stays beside it")

        rig.controller.undoDone()
        await rig.settle { rig.chip?.undone == true || rig.chip?.undoFailure != nil }
        #expect(rig.chip?.undone == true)
        #expect(await rig.calendar.createdReminders.isEmpty)
        let doneID = try #require(done.id)
        let undone = try rig.store.actionRecord(id: doneID)
        #expect(undone?.status == .undone)
    }

    @Test("if History can't be written at all, the item is still added and the chip offers no Undo it could not keep")
    func historyCannotBeWritten() async throws {
        let rig = try Rig()
        let row = try await refusedRow(rig, reminder())
        rig.controller.saveRecord = { _ in throw HistoryWriteFailure() }
        await accept(rig, row)
        #expect(await rig.calendar.createdReminders.count == 1)
        let chip = try #require(rig.chip)
        #expect(!chip.canUndo)
        #expect(records(rig).map(\.status) == [.failed])
    }

    // MARK: A name too long for the row

    @Test("however long the name, the question is whole and fits the row: the name is what gives way")
    func longNamesNeverCutTheQuestion() {
        let names = [
            "Quarterly planning offsite and travel", "Family and friends birthdays", String(repeating: "W", count: 60),
            String(repeating: "i", count: 90), "\u{9577}\u{3044}\u{540D}\u{524D}\u{306E}\u{30EA}\u{30B9}\u{30C8}\u{3067}\u{3059}\u{3088}\u{306D}\u{672C}\u{5F53}\u{306B}\u{9577}\u{3044}",
        ]
        let room = ActionProblemRow.offerLineLimit - ActionProblemRow.offerLineSlack
        for name in names {
            for (target, ending) in [(ActionExecutionError.Target.list, "Add to your default list?"), (.calendar, "Add to your default calendar?")] {
                var row = ActionConfirmationRow(action: reminder(list: name))
                row.refuse(ActionExecutionError.targetNotFound(target, name), recordID: nil)
                let line = ActionProblemRow.line(for: row)
                #expect(line.hasSuffix("\u{2026}\u{201D}. \(ending)"), "\(name) \(target)")
                #expect(ActionProblemRow.width(of: line) <= room, "\(name) \(target): \(ActionProblemRow.width(of: line))")
            }
        }
        // A name that fits is shown as it is.
        var short = ActionConfirmationRow(action: event())
        short.refuse(ActionExecutionError.targetNotFound(.calendar, "Holidays"), recordID: nil)
        #expect(ActionProblemRow.line(for: short) == "No calendar called \u{201C}Holidays\u{201D}. Add to your default calendar?")
        #expect(ActionProblemRow.width(of: ActionProblemRow.line(for: short)) <= room)
        // The capsule (✕, dot, line, ✓, inline padding of 14) stays inside the confirm card's width.
        let chrome = 2 * ActionPillLayout.buttonDiameter + 2 * ActionPillLayout.spacing + 12 + 2 * 14
        #expect(ActionProblemRow.offerLineLimit + chrome <= ActionConfirmationCard.width)
    }
}
