import MurmurCore
import SwiftUI

/// Words for the surfaces that sit outside `LockGate` (the search palette, the Assistant pane,
/// the menu bar) while the app lock is on. History, Notes and Insights are replaced whole by
/// `LockScreenView`; these stay on screen, so each says in one line what it is hiding.
/// Home's lines are `HomeFeedCopy.lockedMessage` and `lockedTodayMessage`.
enum LockedCopy {
    static var search: String {
        FeatureFlags.meetings ? "Your dictations and notes are hidden while Hushy is locked." : "Your dictations are hidden while Hushy is locked."
    }
    static let assistant = "Your notes and action items are hidden while Hushy is locked."
    static let unlock = "Unlock"

    /// Whether the menu bar's "Paste Last Transcript" and "Copy Last Transcript" are offered:
    /// never while locked, since either one hands over dictated words.
    static func canUseLastTranscript(hasTranscript: Bool, isLocked: Bool) -> Bool {
        hasTranscript && !isLocked
    }
}

/// One line saying content is hidden, and the way to see it. It never asks for Touch ID or the
/// password by itself (unlike `LockScreenView`, which a person reaches by choosing a locked
/// section): these surfaces are on screen without being asked for.
struct LockedContentNotice: View {
    @Environment(AppModel.self) private var model
    let message: String
    @State private var isAuthenticating = false

    var body: some View {
        LockedContentLine(message: message, isBusy: isAuthenticating, onUnlock: unlock)
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            _ = await model.appLock.unlock()
            isAuthenticating = false
        }
    }
}

/// The notice itself: a lock, the line, and Unlock. Presentational.
struct LockedContentLine: View {
    let message: String
    var isBusy = false
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Button(LockedCopy.unlock, action: onUnlock)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isBusy)
                .accessibilityLabel("Unlock Hushy")
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
    }
}

extension EnvironmentValues {
    /// Snapshot-only: renders Home, the search palette and the Assistant pane as they are while
    /// the app lock is on, without touching the lock itself.
    @Entry var snapshotAppLocked = false
}
