import Foundation
import MurmurCore

/// Proposed-action cards in the chat. The agent's `propose_action` call only ever produces a
/// card; nothing runs until the user clicks Add here, which goes through `actionHandlers`
/// (the voice-actions executor: Undo, and an `ActionRecord` in the timeline). Gated by
/// `ProFeature.voiceActions`, which is free (founder, 2026-11-11).
extension AssistantModel {
    var actionsEntitled: Bool { actionHandlers.isEntitled() }

    /// The card row state for an entry, reusing the pill's confirmation-row model.
    func confirmationRow(for entry: ChatActionEntry) -> ActionConfirmationRow {
        var row = ActionConfirmationRow(action: entry.action)
        if executingActions.contains(entry.id) {
            row.status = .confirming
            return row
        }
        switch entry.status {
        case .pending:
            // A fresh row is pending, or already refused for a missing detail. If the chat could
            // not be saved before the start, the row says so and Add works again.
            if let note = actionNotes[entry.id] { row.status = .failed(note) }
        case .added: row.status = .succeeded(undoToken: nil)
        // The reason is this session's note, never the saved one: a restored chat shows the fixed line.
        case .failed: row.status = .failed(actionNotes[entry.id] ?? "Couldn't do that")
        case .uncertain: row.status = .uncertain(actionNotes[entry.id] ?? ActionWording.mayAlreadyHaveRun)
        case .blocked: row.status = .blocked(actionNotes[entry.id] ?? "Couldn't do that")
        case .cancelled, .undone: row.status = .cancelled
        }
        return row
    }

    func confirmAction(_ actionID: UUID, in messageID: UUID) {
        guard actionsEntitled, !executingActions.contains(actionID),
              let entry = entry(actionID, in: messageID), entry.status == .pending || entry.status == .failed
        else { return }
        // Write the intent first. An action that cannot be undone must never run twice, so the
        // chat durably says "started" BEFORE it runs; if that cannot be saved, it does not run.
        // A restored chat then shows the fixed "may already have run" line and no Add or Retry
        // until a clean result replaces it below.
        guard markStarted(actionID, in: messageID, was: entry.status) else {
            actionNotes[actionID] = ActionWording.notStartedChatNotSaved
            return
        }
        executingActions.insert(actionID)
        let handlers = actionHandlers
        Task { [weak self] in
            let result = await handlers.execute(entry.action)
            guard let self else { return }
            self.executingActions.remove(actionID)
            // The person may have left this conversation while it ran: nothing on screen to update.
            guard self.entry(actionID, in: messageID) != nil else { return }
            self.actionNotes[actionID] = nil
            self.setEntry(actionID, in: messageID) { entry in
                entry.failure = nil
                switch result {
                case .success(let record):
                    entry.status = .added
                    entry.recordID = record.id
                case .failure(let failure) where failure.didRun:
                    // It ran: completed, with nothing to undo or retry because History has no record.
                    entry.status = .added
                    entry.recordID = nil
                case .failure(let failure):
                    switch failure.kind {
                    case .failed: entry.status = .failed
                    case .uncertain: entry.status = .uncertain
                    case .blocked: entry.status = .blocked
                    }
                }
            }
            if case .failure(let failure) = result { self.actionNotes[actionID] = failure.message }
        }
    }

    /// Marks the entry started and saves that, reporting whether it is on disk. On a failed save
    /// the entry goes back to what it was.
    private func markStarted(_ actionID: UUID, in messageID: UUID, was previous: ChatActionEntry.Status) -> Bool {
        var saved: Message?
        updateMessage(messageID) { message in
            guard let index = message.actions.firstIndex(where: { $0.id == actionID }) else { return }
            message.actions[index].status = .uncertain
            message.actions[index].failure = nil
            saved = message
        }
        guard let saved else { return false }
        do {
            let id = try persistThrowing(saved)
            updateMessage(messageID) { $0.storedID = id }
            return true
        } catch {
            log.error("couldn't save the start of an action, so it did not run")
            updateMessage(messageID) { message in
                guard let index = message.actions.firstIndex(where: { $0.id == actionID }) else { return }
                message.actions[index].status = previous
            }
            return false
        }
    }

    func cancelAction(_ actionID: UUID, in messageID: UUID) {
        guard let status = entry(actionID, in: messageID)?.status,
              [.pending, .failed, .uncertain, .blocked].contains(status) else { return }
        setEntry(actionID, in: messageID) { $0.status = .cancelled }
    }

    func undoAction(_ actionID: UUID, in messageID: UUID) {
        guard let entry = entry(actionID, in: messageID), entry.status == .added, let recordID = entry.recordID else { return }
        let handlers = actionHandlers
        Task { [weak self] in
            let outcome = await handlers.undo(recordID)
            guard let self else { return }
            // "Undone" only once the item is really gone. A failed Undo leaves the card as added
            // and says so under it, for this session only.
            switch outcome {
            case .undone, .removedNotRecorded:
                self.actionNotes[actionID] = outcome == .undone ? nil : ActionWording.undoNotRecorded
                self.setEntry(actionID, in: messageID) { entry in
                    entry.status = .undone
                    entry.failure = nil
                }
            case .failed(let line):
                self.actionNotes[actionID] = line
            case .unavailable:
                self.actionNotes[actionID] = "Undo is no longer available."
            }
        }
    }

    /// Whether an added action can still be undone (Calendar/Reminders only; Shortcuts can't).
    func canUndo(_ entry: ChatActionEntry) -> Bool {
        entry.status == .added && entry.recordID != nil && entry.action.kind != .runShortcut
    }

    private func entry(_ actionID: UUID, in messageID: UUID) -> ChatActionEntry? {
        messages.first { $0.id == messageID }?.actions.first { $0.id == actionID }
    }

    private func setEntry(_ actionID: UUID, in messageID: UUID, _ change: (inout ChatActionEntry) -> Void) {
        var saved: Message?
        updateMessage(messageID) { message in
            guard let index = message.actions.firstIndex(where: { $0.id == actionID }) else { return }
            change(&message.actions[index])
            saved = message
        }
        if let saved { persist(saved) }
    }
}
