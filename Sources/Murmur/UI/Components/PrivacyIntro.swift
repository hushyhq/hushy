import SwiftUI

/// A short privacy moment when the main window first appears in a launch: the Hushy mark (the
/// Wave-H tile, `LogoTile`) gives way to a lock, with one line of promise. Says *what* we
/// promise, never *how* it's built. Once per launch, click to skip, and skipped entirely with
/// Reduce Motion or in snapshots (the snapshot renderer draws `PrivacyIntroContent` directly).
struct PrivacyIntro: View {
    /// Process-wide, so reopening the window later in the same launch doesn't replay it.
    @MainActor private static var hasPlayed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var visible = true
    @State private var locked = false
    @State private var showLine = false

    private enum Timing {
        static let listen: Duration = .milliseconds(900)
        static let hold: Duration = .milliseconds(1_500)
        static let fadeOut = 0.45
    }

    var body: some View {
        if visible, !isSnapshot, !reduceMotion, !Self.hasPlayed {
            PrivacyIntroContent(locked: locked, showLine: showLine)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .transition(.opacity)
                .task { await play() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Click to skip")
        }
    }

    private func play() async {
        try? await Task.sleep(for: Timing.listen)
        withAnimation(.spring(duration: 0.5)) { locked = true }
        withAnimation(.easeOut(duration: 0.5).delay(0.15)) { showLine = true }
        try? await Task.sleep(for: Timing.hold)
        dismiss()
    }

    private func dismiss() {
        guard visible else { return }
        Self.hasPlayed = true
        withAnimation(.easeInOut(duration: Timing.fadeOut)) { visible = false }
    }
}

/// What the intro draws at a moment in its timeline: the mark alone (`locked == false`, no
/// line), then the lock with the promise. Pure drawing, so the snapshot renderer can show both
/// moments without playing the intro.
struct PrivacyIntroContent: View {
    let locked: Bool
    let showLine: Bool

    var body: some View {
        ZStack {
            Theme.bgBase.ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                ZStack {
                    LogoTile(size: 88)
                        .opacity(locked ? 0 : 1)
                        .scaleEffect(locked ? 0.9 : 1)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(Theme.phosphor)
                        .opacity(locked ? 1 : 0)
                        .scaleEffect(locked ? 1 : 0.9)
                }
                .frame(height: 88)
                VStack(spacing: 6) {
                    Text("Private by default.")
                        .font(.system(size: 26, weight: .regular, design: .serif))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your words, audio and notes stay on your Mac unless you send them.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .opacity(showLine ? 1 : 0)
                .offset(y: showLine ? 0 : 6)
            }
        }
    }
}
