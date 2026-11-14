import MurmurCore
import SwiftUI

/// "Your key": onboarding teaches the dictation key by doing. A slice of the Mac keyboard shows
/// where the key is; it lights while the key is really down (the event tap's own presses,
/// `HotkeyMonitor.onTriggerEdge`), and Continue unlocks once the person has double-tapped it, the
/// main gesture. Holding it is taught next and is optional. Nothing is recorded on this step
/// (`AppModel.beginHotkeyPractice`).
///
/// Without Accessibility the tap cannot see the key: the keyboard stays on screen, dimmed, with the
/// reason and the one button that fixes it, rather than a step that silently never lights.
struct OnboardingKeyStep: View {
    let onContinue: () -> Void
    /// Stills only: the lesson's state, and whether to draw the no-Accessibility state.
    var snapshot: KeyGesturePractice?
    var snapshotAccessibilityOff = false

    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var practice = KeyGesturePractice()
    /// Bumped when a gesture completes, to play the key's one ring.
    @State private var celebrations = 0
    @State private var practising = false

    private var lesson: KeyGesturePractice { snapshot ?? practice }
    private var canSeeKeys: Bool {
        !snapshotAccessibilityOff && (isSnapshot || model.permissions.accessibility == .granted)
    }

    var body: some View {
        @Bindable var settings = model.settings
        let glyph = settings.triggerKey.glyph
        let copy = OnboardingKeyCopy.state(lesson, canSeeKeys: canSeeKeys, glyph: glyph)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(copy.title).font(Theme.Font.section)
                .contentTransition(.opacity)
            Text(copy.line).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            OnboardingKeyboard(
                trigger: settings.triggerKey, isDown: lesson.isDown, isLearned: lesson.hasDoubleTapped,
                celebrations: celebrations, isEnabled: canSeeKeys)
                .padding(.vertical, Theme.Space.s)
            KeyLessonChecklist(lesson: lesson, glyph: glyph, isEnabled: canSeeKeys)
            HStack(spacing: Theme.Space.l) {
                if canSeeKeys {
                    Button("Continue", action: onContinue)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!lesson.hasDoubleTapped)
                } else {
                    // The one way forward is the grant; Continue stays visible, disabled, beside it.
                    Button(OnboardingDoneCopy.openAccessibilitySettings) { model.permissions.requestAccessibility() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button("Continue", action: onContinue).buttonStyle(SecondaryButtonStyle()).disabled(true).opacity(0.45)
                }
                if isSnapshot {
                    Text("Change key").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    TriggerKeyMenu(selection: $settings.triggerKey)
                }
            }
            .padding(.top, Theme.Space.xs)
            if settings.triggerKey == .fn, !isSnapshot, Permissions.globeKeyAction.conflicts, !model.hotkeys.isFnCaptureActive {
                GlobeKeyWarning()
            }
        }
        .animation(isSnapshot ? nil : Theme.Motion.fade, value: copy)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: model.permissions.accessibility) { _, status in
            guard status == .granted else { return }
            model.installHotkeys()
            start()
        }
    }

    private func start() {
        guard !isSnapshot, !practising, model.permissions.accessibility == .granted else { return }
        practising = true
        model.beginHotkeyPractice { isDown, time in
            if practice.edge(isDown: isDown, at: time) != nil { celebrations += 1 }
        }
    }

    private func stop() {
        guard practising else { return }
        practising = false
        model.endHotkeyPractice()
    }
}

/// The key step's words, one title and one line per state. Pure, so a test can read every state.
enum OnboardingKeyCopy {
    struct State: Equatable {
        let title: String
        let line: String
    }

    static func state(_ lesson: KeyGesturePractice, canSeeKeys: Bool, glyph: String) -> State {
        guard canSeeKeys else {
            return State(title: "Double-tap \(glyph)", line: "Hushy can't see your keys until Accessibility is on.")
        }
        switch (lesson.hasDoubleTapped, lesson.hasHeld) {
        case (false, _):
            return State(title: "Double-tap \(glyph)", line: "Tap it twice, quickly. Nothing is recorded here.")
        case (true, false):
            return State(
                title: "Now hold \(glyph)",
                line: lesson.heldTooBriefly ? "Hold it a little longer." : "Hold it down, as you would while you talk.")
        case (true, true):
            return State(title: "That's your key.", line: "Double-tap to talk, Enter to paste. Or hold it while you talk.")
        }
    }
}

/// The two gestures, ticked as the person shows them. Double-tap first: it is the main one.
private struct KeyLessonChecklist: View {
    let lesson: KeyGesturePractice
    let glyph: String
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            row(done: lesson.hasDoubleTapped, isNext: !lesson.hasDoubleTapped,
                title: "Double-tap \(glyph)", detail: "talk hands-free, Enter pastes")
            row(done: lesson.hasHeld, isNext: lesson.hasDoubleTapped && !lesson.hasHeld,
                title: "Hold \(glyph)", detail: "talk while you hold it")
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func row(done: Bool, isNext: Bool, title: String, detail: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            ZStack {
                Circle().strokeBorder(done ? Color.clear : (isNext ? Theme.phosphor : Theme.hairline), lineWidth: 1.5)
                if done {
                    Circle().fill(Theme.phosphorFill)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onPhosphor)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 18, height: 18)
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(done || isNext ? Theme.textPrimary : Theme.textTertiary)
            Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        .animation(Theme.Motion.pop, value: done)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not yet")
    }
}
