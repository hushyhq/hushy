import CoreAudio
import MurmurCore
import SwiftUI

// Building blocks shared by the onboarding steps (required and "while it downloads").

struct StepLayout<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.onPhosphor)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.phosphorFill))
            Text(title).font(Theme.Font.section)
            Text(message).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.m) { actions }
                .padding(.top, Theme.Space.s)
        }
    }
}

struct GrantedLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(Theme.Font.emphasis)
            .foregroundStyle(Theme.success)
    }
}

/// "Change key ▾" — the key is a menu on the Try-it step rather than its own screen, so the
/// default (fn) costs nobody a click and anyone who wants Right ⌥/⌘ or ⌃⌥ can still switch.
struct TriggerKeyMenu: View {
    @Binding var selection: TriggerKey

    var body: some View {
        Menu {
            ForEach(TriggerKey.allCases) { key in
                Button {
                    withAnimation(Theme.snappy) { selection = key }
                } label: {
                    if key == selection {
                        Label(key.title, systemImage: "checkmark")
                    } else {
                        Text(key.title)
                    }
                }
            }
        } label: {
            Text("Change key")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Change dictation key")
    }
}

/// The macOS Globe-key action fights with fn dictation until it's set to Do Nothing (moot once
/// `HotkeyMonitor` captures solo fn presses itself — see `ReadinessStrip`).
struct GlobeKeyWarning: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Your 🌐 key is set to “\(Permissions.globeKeyAction.title)”", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning).font(Theme.Font.emphasis)
            Text("In Keyboard settings, set “Press 🌐 key to” → Do Nothing, so fn only starts Hushy.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.warning.opacity(0.08)))
    }
}

/// Optional on the closing step: "Tune Hushy to your voice" used to be its own required step;
/// it now takes 30 s whenever the user wants it (also in Settings).
struct TuneOffer: View {
    let onTune: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.phosphor)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.phosphorTint))
            VStack(alignment: .leading, spacing: 3) {
                Text("Tune Hushy to your voice")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(TuneCopy.onboardingOffer)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Button("Tune now", action: onTune).buttonStyle(SecondaryButtonStyle())
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Live mic level meter for onboarding: catches a dead/silent mic (wrong input picked in
/// System Settings, a muted audio interface, …) before the user reaches "Try it" and blames
/// Murmur for words that never arrived. Starts `AudioCapture` on appear, stops on disappear —
/// exactly the same capture path the hot path uses, so the check is honest.
///
/// It listens to the microphone a dictation would use (`MicrophoneSelector`), and its picker is
/// the Microphone setting itself: the same entries and "Automatic · <microphone>" label as
/// Settings, and a pick made here is the pick dictation uses.
struct MicCheck: View {
    let isSnapshot: Bool
    /// Stills only: draw the "no audio" state and its picker from this fixed device list.
    var silentSnapshot: MicrophoneSelector.Devices?

    @Environment(AppModel.self) private var model
    @State private var capture = AudioCapture()
    @State private var level: Float = 0
    @State private var peakLevel: Float = 0
    @State private var silentSeconds: Double = 0
    @State private var devices = MicrophoneSelector.Devices(inputs: [], systemDefault: nil)
    @State private var silenceTimer: Timer?

    /// How long the level must stay at exactly zero before we suspect a dead input.
    private static let silenceThreshold: Double = 3

    private var looksSilent: Bool { silentSnapshot != nil || (silentSeconds >= Self.silenceThreshold && !isSnapshot) }

    private var microphones: MicrophoneSettingState {
        MicrophoneSettingState(
            picked: model.settings.inputDeviceName, devices: silentSnapshot ?? devices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Say something — the bar should move.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            Text("Automatic uses the Mac's microphone with a Bluetooth headset. Pick the headset below if you prefer its microphone.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            OnboardingLevelMeter(
                level: silentSnapshot != nil ? 0 : isSnapshot ? 0.55 : level,
                peak: silentSnapshot != nil ? 0 : isSnapshot ? 0.7 : peakLevel)
            if looksSilent {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Label("No audio from this mic — pick another input.", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.emphasis).foregroundStyle(Theme.warning)
                    if !microphones.entries.isEmpty {
                        Picker("Input", selection: Binding(
                            get: { model.settings.inputDeviceName },
                            set: { picked in
                                model.settings.inputDeviceName = picked
                                restart()
                            })) {
                            Text(microphones.automaticLabel).tag(String?.none)
                            ForEach(microphones.entries) { Text($0.label).tag(Optional($0.name)) }
                        }
                        .labelsHidden().frame(width: MicrophoneSettingRow.pickerWidth)
                    }
                }
                .padding(Theme.Space.m)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.warning.opacity(0.08)))
            }
        }
        .onAppear {
            guard !isSnapshot else { return }
            devices = MicrophoneSelector.shared.probe()
            start()
        }
        .onDisappear { stop() }
    }

    private func start() {
        silentSeconds = 0
        peakLevel = 0
        silenceTimer?.invalidate()
        MicrophoneSelector.shared.prepare(capture, picked: model.settings.inputDeviceName)
        try? capture.start { rms in
            Task { @MainActor in
                level = rms
                peakLevel = max(peakLevel, rms)
            }
        }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                if peakLevel <= 0 {
                    silentSeconds += 0.5
                } else {
                    silentSeconds = 0
                }
            }
        }
    }

    private func restart() {
        stop()
        start()
    }

    private func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        _ = capture.stop()
    }
}

/// A row of bars driven by live RMS, styled like the pill's own listening indicator but
/// standalone (no Pill/* dependency) since this runs in a regular window.
private struct OnboardingLevelMeter: View {
    let level: Float
    let peak: Float

    private let barCount = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(index < activeBars ? Theme.phosphor : Theme.bgSunken)
                    .frame(width: 4, height: height(for: index))
            }
        }
        .frame(height: 40, alignment: .center)
        .animation(Theme.fade, value: level)
    }

    private var activeBars: Int { Int(Double(barCount) * min(Double(level) * 6, 1)) }

    private func height(for index: Int) -> CGFloat {
        let base: CGFloat = 6
        guard index < activeBars else { return base }
        // A little variation so it reads as a waveform rather than a plain bar.
        let variance = CGFloat((index % 3)) * 4
        return base + CGFloat(min(Double(level) * 6, 1)) * 28 + variance
    }
}

/// What you said vs what Murmur typed, with the time it took.
struct ResultCard: View {
    let dictation: Dictation

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Eyebrow("Heard").frame(width: 64, alignment: .leading)
                Text(dictation.rawText)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text("TYPED").font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.phosphor)
                    .frame(width: 64, alignment: .leading)
                Text(dictation.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(dictation.latencyMs) ms")
                    .font(Theme.Font.data)
                    .foregroundStyle(Theme.onPhosphor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.phosphorFill))
            }
        }
        .padding(Theme.Space.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// "Also save notes to Apple Notes" — offered once during setup, changeable later in Notes and
/// Settings. Turning it on asks macOS for permission immediately, so the prompt comes with context.
struct AppleNotesChoice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotAppleNotesResult) private var snapshotResult
    @State private var toggle = AppleNotesToggle()

    var body: some View {
        @Bindable var settings = model.settings
        let shown = snapshotResult ?? toggle.problem
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "note.text")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.warning)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Save notes to Apple Notes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let shown, !shown.isGranted {
                    AppleNotesAccessNotice(result: shown) { enable(true) }
                } else {
                    Text("Every recorded note also lands in a “\(AppleNotesExporter.folder)” folder, so it’s on your iPhone too.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            SwitchToggle(isOn: Binding(
                get: { settings.saveNotesToAppleNotes || snapshotResult == .granted },
                set: { enable($0) }))
                .accessibilityLabel("Save notes to Apple Notes")
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    /// Never runs the script in snapshot mode, so a render can't trigger the Automation prompt.
    private func enable(_ on: Bool) {
        guard !isSnapshot else { return }
        toggle.turn(on) { model.settings.saveNotesToAppleNotes = $0 }
    }
}
