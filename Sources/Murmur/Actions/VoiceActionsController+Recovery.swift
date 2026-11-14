import Foundation
import MurmurCore

/// A voice action refused because the list or calendar it names isn't there. The refusal stands:
/// a named place is never swapped for the default on Hushy's own say (`ActionExecutor`). What
/// changes is that the person is not left with nothing. The row carries an offer
/// (`ActionConfirmationRow.offer`), the pill asks in one line, and one tick adds the same item to
/// the default list or calendar.
extension VoiceActionsController {
    /// ✓ on the pill's question, ⏎ while its first key window is open, or "Use default" on a card row.
    /// The row's action loses only the place that wasn't found and goes through the ordinary
    /// confirmed path (`execute(rowID:)`): the executor checks it again, the done chip names where
    /// it landed and carries Undo, one free action is counted, and History's refused row becomes
    /// the done one. A row whose offer is gone (taken, dismissed, never there) does nothing.
    func acceptOffer(_ row: ActionConfirmationRow) {
        guard case .actionConfirm(var current) = pill.state,
              let index = current.rows.firstIndex(where: { $0.id == row.id }),
              let offer = current.rows[index].openOffer else { return }
        current.rows[index].action = offer.applied(to: current.rows[index].action)
        current.rows[index].offer = nil
        current.rows[index].status = .confirming
        pill.state = .actionConfirm(current)
        Task { await execute(rowID: row.id) }
    }

    /// One usage event per request (`onMetric`). A refusal that asks a question is not reported
    /// when it is refused; it reports when the question is settled. Taking it reports what the add
    /// came to (succeeded, or why it failed, from `execute(rowID:)`). Leaving it reports the
    /// refusal itself, once, here: ✕ or esc, a new action or a dictation taking the pill, or
    /// Hushy quitting with it open (`settleForQuit`). Only the fixed category, never the name.
    /// Called for every change to a card on the pill (`PillModel.onActionCardChange`).
    func reportUnansweredOffers(leaving old: ActionConfirmationCardState, for state: PillState) {
        var rowsNow: [ActionConfirmationRow] = []
        if case .actionConfirm(let card) = state { rowsNow = card.rows }
        for row in old.rows {
            guard let offer = row.openOffer else { continue }
            // Still asked, or just taken and running: not settled yet.
            if let same = rowsNow.first(where: { $0.id == row.id }), same.openOffer != nil || same.status == .confirming { continue }
            onMetric?(VoiceActionMetricEvent(outcome: .failed, failure: VoiceActionFailureCategory(offer.refusal)))
        }
    }

    /// Hushy is quitting. A question still on the pill was never answered, which counts as its
    /// refusal: clearing the pill reports it before the usage numbers are flushed.
    func settleForQuit() {
        guard case .actionConfirm(let card) = pill.state, card.rows.contains(where: { $0.openOffer != nil }) else { return }
        pill.state = .idle
    }

    /// Writes a History record, or returns nil (with a fixed log line, no names) when it could not
    /// be written. A done action that was to be written over its refused row (`acceptOffer`) and
    /// could not be is written as a row of its own: the item exists, so History has to say so and
    /// its Undo needs a record to work from. The refused row then stays beside it.
    func writeHistory(_ record: ActionRecord) -> ActionRecord? {
        let write = saveRecord ?? { try self.store.save($0) }
        do {
            return try write(record)
        } catch {
            log.error("history write failed: the action record")
        }
        guard record.id != nil, record.status == .completed else { return nil }
        var added = record
        added.id = nil
        do {
            return try write(added)
        } catch {
            log.error("history write failed: the action record, as a new row")
            return nil
        }
    }
}
