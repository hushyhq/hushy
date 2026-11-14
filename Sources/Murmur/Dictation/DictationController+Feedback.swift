import Foundation

/// What the dictation path says through the pill when the words did not land.
extension DictationController {
    /// A gentle, non-alarming hint (no error sound).
    func flashNotice(_ message: String) {
        show(.error(message))
        scheduleReset(after: .seconds(2.2))
    }

    func flashError(_ message: String) {
        sounds.error()
        show(.error(message))
        scheduleReset(after: .seconds(2.5))
    }

    /// A dictation that produced no text. The row stays until it is dismissed, tried again or the
    /// next dictation starts (`DictationFailure`), so it is never missed. Nothing here touches the
    /// recording phase or the keyboard: the next key press starts recording as usual.
    ///
    /// `retry` runs the dictation again from audio it holds in memory. The pill keeps the closure
    /// and drops it with the row, so that audio lives no longer than the row and is never written
    /// to disk for this (History keeps its own copy only when audio retention is on, as before).
    func fail(_ failure: DictationFailure, retry: (@MainActor () -> Void)? = nil) {
        if failure.playsErrorSound { sounds.error() }
        pill.present(failure: failure, retry: retry)
    }

    /// Paste last could not paste where the cursor is. The pill opens with the words and a Copy, as
    /// it does for any dictation that was not pasted; the clipboard is left alone. Mid-dictation
    /// the pill belongs to the recording, so only the sound plays.
    func showNotPasted(_ text: String) {
        sounds.error()
        guard !isBusy else { return }
        pill.present(.noField(.plainNotPasted), text: text)
    }
}
