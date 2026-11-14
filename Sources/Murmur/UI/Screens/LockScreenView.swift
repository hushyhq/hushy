import MurmurCore
import SwiftUI

/// Shown in place of History/Notes/Insights while `AppModel.appLock.isLocked` is true. Calm,
/// centered, uses existing Theme tokens only (no new palette) so it doesn't need coordination
/// with the light-theme restyle in progress elsewhere. Dictation keeps working while this is
/// showing — this view only ever replaces the *content* of a gated section, never the pill.
struct LockScreenView: View {
    @Environment(AppModel.self) private var model
    @State private var isAuthenticating = false
    @State private var failedOnce = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: Theme.Space.xs) {
                Text("Hushy is locked")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text(FeatureFlags.meetings ? "History, notes and insights are hidden until you unlock." : "History and insights are hidden until you unlock.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: unlock) {
                HStack(spacing: 8) {
                    if isAuthenticating { ProgressView().controlSize(.small) }
                    Text(isAuthenticating ? "Waiting…" : "Unlock")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isAuthenticating)
            if failedOnce {
                Text("That didn't work. Try again.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
            }
            Spacer()
            Text("Dictation still works while locked — hold \(model.settings.triggerKey.glyph) anywhere.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgBase)
        .task { unlock() }
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let ok = await model.appLock.unlock()
            isAuthenticating = false
            failedOnce = !ok
        }
    }
}

/// Wraps a gated section's content, swapping in `LockScreenView` while locked. Also records
/// activity on appear so switching into the section (once unlocked) resets the idle clock.
struct LockGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if model.appLock.isLocked {
                LockScreenView()
            } else {
                content()
            }
        }
        .onAppear { model.appLock.recordActivity() }
    }
}
