import AppKit
import SwiftUI

/// What a person can do on a recovery row (a dictation that was not pasted, or produced no
/// text), by name. The pill's panel never takes keyboard focus, so each of these is also a named
/// accessibility action on the row: VoiceOver can copy, open History, try again or dismiss
/// without the pointer.
enum RecoveryAction: Hashable, Sendable {
    case copy
    case openInHistory
    case tryAgain
    /// The quiet-microphone row: record from the Mac's own microphone.
    case useMacMic
    /// The quiet-microphone row: go back to the microphone the Mac is set to use.
    case useAutomatic
    /// The quiet "Pasted" row: open the card with the words.
    case showWords
    case dismiss

    var title: String {
        switch self {
        case .copy: "Copy what you said"
        case .openInHistory: "Open in History"
        case .tryAgain: DictationFailure.retryTitle
        case .useMacMic: QuietMic.switchTitle
        case .useAutomatic: QuietMic.automaticTitle
        case .showWords: "Show what you said"
        case .dismiss: "Dismiss"
        }
    }
}

extension PillState {
    /// The showing recovery row's buttons, in the order it draws them. Empty for every other state.
    var recoveryActions: [RecoveryAction] {
        switch self {
        case .noField(let mode): (mode.afterCopy == nil ? [] : [.copy]) + [.dismiss]
        case .held(copied: false): [.copy, .openInHistory, .dismiss]
        case .failed(let failure):
            (failure.canRetry ? [.tryAgain] : []) + (failure.micOffer == nil ? [] : [.useMacMic])
                + (failure.offersAutomatic ? [.useAutomatic] : []) + [.dismiss]
        case .pastedUnchecked: [.showWords, .dismiss]
        default: []
        }
    }
}

extension PillModel {
    /// Does what the row's own button does. An action the showing row does not offer is ignored.
    func perform(_ action: RecoveryAction) {
        guard state.recoveryActions.contains(action) else { return }
        switch (action, state) {
        case (.copy, .noField): copyNoFieldText()
        case (.copy, _): copyHeldText()
        case (.openInHistory, _): openHeldInHistory()
        case (.tryAgain, _): retryFailure()
        case (.useMacMic, _): useOfferedMic()
        case (.useAutomatic, _): useAutomatic()
        case (.showWords, _): showUncheckedWords()
        case (.dismiss, _): state = .idle
        }
    }

    /// What VoiceOver says as a recovery row appears: the row's own words. For a card that still
    /// has its Copy, also the line that names paste last (not while the app lock is on, when
    /// paste last refuses). Never the dictated text.
    var recoveryAnnouncement: String? {
        switch state {
        case .noField(let mode):
            mode.afterCopy == nil || mode.recoveryLine(isLocked: isAppLocked()) == nil
                ? mode.accessibilityText : "\(mode.accessibilityText) \(ShortcutHelp.pasteLastSpoken)"
        case .held, .failed: accessibilityLabel
        // Said after every dictation in an app Hushy cannot read, so it is short; the row's own
        // label has the full sentence.
        case .pastedUnchecked: PastedUncheckedRow.announcement
        default: nil
        }
    }
}

extension View {
    /// The showing recovery row's buttons as named VoiceOver actions on this element.
    func recoveryAccessibilityActions(_ model: PillModel) -> some View {
        accessibilityActions {
            ForEach(model.state.recoveryActions, id: \.self) { action in
                Button(action.title) { model.perform(action) }
            }
        }
    }
}

/// Speaks a line through VoiceOver without moving its cursor or anyone's keyboard focus.
@MainActor
enum PillAnnouncer {
    static func post(_ words: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: words,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
