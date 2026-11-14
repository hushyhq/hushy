import MurmurCore

/// Paste last (⌃⌘V) and copy last (⌃⌘C): the two shortcuts that hand over the most recent
/// dictation from anywhere. While the app lock is on they hand over nothing and the pill says
/// to unlock (`LastTranscriptShortcut`); the check comes before the dictation is read.
extension DictationController {
    // MARK: Paste last

    func pasteLast() {
        guard !refusesWhileLocked(.paste) else { return }
        guard let last = try? store.lastDictation(), !last.text.isEmpty else {
            flashError("Nothing to paste yet")
            return
        }
        let target = FocusTarget.current()
        Task {
            let outcome = await TextInserter.insert(last.text, into: target)
            if outcome == .focusChanged || outcome == .dispatchFailed { self.showNotPasted(last.text) }
        }
    }

    // MARK: Copy last

    /// Puts the most recent dictation's final text on the clipboard and says so in the pill.
    /// Never types anything. With no dictation yet it only says so.
    func copyLast() {
        guard !refusesWhileLocked(.copy) else { return }
        let outcome = (try? CopyLast.resolve(from: store)) ?? .nothingToCopy
        switch outcome {
        case .copy(let text):
            TextInserter.copy(text, markTransient: false)
            // Mid-dictation the pill belongs to the recording; the copy still happens.
            guard !isBusy else { return }
            pill.present(.held(copied: true), text: "")
        case .nothingToCopy:
            guard !isBusy else { return }
            flashNotice(CopyLast.nothingMessage)
        }
    }

    // MARK: Locked

    /// True when the app lock is on: nothing is pasted, copied or read. The pill says why when it
    /// is free to (`LastTranscriptShortcut.showsNotice`).
    private func refusesWhileLocked(_ shortcut: LastTranscriptShortcut) -> Bool {
        guard let notice = shortcut.refusal(isLocked: pill.isAppLocked()) else { return false }
        let pillHoldsRecoveryRow = !pill.state.recoveryActions.isEmpty
        if LastTranscriptShortcut.showsNotice(isDictating: isBusy, pillHoldsRecoveryRow: pillHoldsRecoveryRow) {
            flashNotice(notice)
        }
        return true
    }
}
