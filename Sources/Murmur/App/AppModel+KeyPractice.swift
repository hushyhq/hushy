import Foundation

extension AppModel {
    /// Onboarding's key lesson: while it is on screen the dictation key starts nothing (nothing is
    /// recorded or pasted), and its raw presses go to `onEdge` so the lesson can tell a double-tap
    /// from a hold. `endHotkeyPractice` puts the dictation handlers back.
    ///
    /// Both handlers are swapped: the dictation controller listens on `onTimedEvent`, which the monitor
    /// prefers over `onEvent`, so swapping `onEvent` alone let a practice press start a real dictation.
    /// The monitor's own latch flags are cleared after every event, as the controller would when a
    /// dictation ends, so the next press is a fresh press and Esc and Return stay with the app in front.
    func beginHotkeyPractice(onEdge: @escaping (_ isDown: Bool, _ at: Date) -> Void) {
        if practiceSavedHandlers == nil { practiceSavedHandlers = (hotkeys.onEvent, hotkeys.onTimedEvent) }
        hotkeys.onTimedEvent = nil
        hotkeys.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .pasteLast, .copyLast:
                // Not the dictation key: these shortcuts keep working during the lesson.
                self.practiceSavedHandlers?.event?(event)
            default:
                self.hotkeys.isLatched = false
                self.hotkeys.isDictationActive = false
            }
        }
        hotkeys.onTriggerEdge = onEdge
    }

    func endHotkeyPractice() {
        guard let saved = practiceSavedHandlers else { return }
        hotkeys.onEvent = saved.event
        hotkeys.onTimedEvent = saved.timed
        hotkeys.onTriggerEdge = nil
        hotkeys.isLatched = false
        hotkeys.isDictationActive = false
        practiceSavedHandlers = nil
    }
}
