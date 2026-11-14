import MurmurCore
import SwiftUI

/// Voice Lab: records a held-out set of the user's real dictation through the exact
/// production capture path, for the ground-truth eval `murmur-eval voicelab` scores.
/// Reachable from Settings → Developer → "Voice Lab →".
struct VoiceLabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var lab: VoiceLabModel?

    var body: some View {
        Group {
            if let lab {
                VoiceLabContent(lab: lab, onDone: { dismiss() })
            } else {
                ProgressView().onAppear { lab = VoiceLabModel(settings: model.settings) }
            }
        }
        .frame(width: 640, height: 620)
    }
}

private struct VoiceLabContent: View {
    @Bindable var lab: VoiceLabModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header

            switch lab.loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load prompts", message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if lab.isFinished {
                    finishedState
                } else if let prompt = lab.currentPrompt {
                    VStack(spacing: Theme.Space.xxl) {
                        promptCard(prompt)
                        recordArea(prompt)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(Theme.Space.xl)
        .background(Theme.bgBase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Voice Lab").font(Theme.Font.section).foregroundStyle(Theme.textPrimary)
                    Text("A held-out set of your real dictation, recorded through the production mic path.")
                        .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Open folder", action: lab.openFolder).buttonStyle(SecondaryButtonStyle())
                IconButton(symbol: "xmark", help: "Close", action: onDone)
            }
            if case .ready = lab.loadState, !lab.prompts.isEmpty {
                ProgressBar(fraction: Double(lab.currentIndex) / Double(lab.prompts.count), label: lab.progressText)
            }
        }
    }

    private func promptCard(_ prompt: VoiceLabPrompt) -> some View {
        Card(padding: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    StyleBadge(style: prompt.style)
                    Eyebrow(prompt.category)
                    Spacer()
                    if lab.completedIDs.contains(prompt.id) {
                        Label("Recorded", systemImage: "checkmark.circle.fill")
                            .font(Theme.Font.caption).foregroundStyle(Theme.success)
                    }
                }
                Text(prompt.instruction)
                    .font(Theme.Font.emphasis).foregroundStyle(Theme.textSecondary)
                Text(promptText(prompt))
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The prompt text stripped of its lab-only stage direction, so what's shown to read is
    /// just the words, not "Say it naturally: …".
    private func promptText(_ prompt: VoiceLabPrompt) -> String {
        if let colonRange = prompt.prompt.range(of: ": ") {
            return String(prompt.prompt[colonRange.upperBound...])
        }
        return prompt.prompt
    }

    @ViewBuilder
    private func recordArea(_ prompt: VoiceLabPrompt) -> some View {
        if let pending = lab.pendingTake {
            reviewControls(pending)
        } else {
            VStack(spacing: Theme.Space.l) {
                LevelMeter(level: lab.level, isActive: lab.isRecording)
                HStack(spacing: Theme.Space.m) {
                    Button("Skip") { lab.skip() }.buttonStyle(SecondaryButtonStyle())
                    RecordButton(isRecording: lab.isRecording) {
                        if lab.isRecording { lab.stopRecording() } else { lab.startRecording() }
                    }
                    Button("Back") { lab.goToPrevious() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(lab.currentIndex == 0)
                }
                Text(lab.isRecording ? "Recording — click to stop" : "Click to start, click again to stop")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func reviewControls(_ pending: VoiceLabModel.PendingTake) -> some View {
        VStack(spacing: Theme.Space.l) {
            Card(padding: Theme.Space.l) {
                HStack(spacing: Theme.Space.m) {
                    PlaybackButton(path: pending.audioURL.path)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1fs · peak %.2f · rms %.3f", pending.take.durationSeconds, pending.peak, pending.rms))
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        if pending.peak < 0.01 {
                            Text("Very quiet — check the mic if this wasn't a whisper take.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    Spacer()
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button("Re-record") { lab.discardPendingTake() }.buttonStyle(SecondaryButtonStyle())
                Button("Keep") { lab.keepPendingTake() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var finishedState: some View {
        EmptyState(
            symbol: "checkmark.seal", title: "Voice Lab complete",
            message: "\(lab.completedCount)/\(lab.prompts.count) prompts recorded. Run murmur-eval voicelab to score them.")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thin fill bar with a trailing "N/total" count, replacing the plain number that used to
/// sit disconnected from the rest of the header.
private struct ProgressBar: View {
    let fraction: Double
    let label: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline).frame(height: 4)
                    Capsule().fill(Theme.phosphorFill)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1), height: 4)
                }
            }
            .frame(height: 4)
            Text(label)
                .font(Theme.Font.data).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .animation(Theme.settle, value: fraction)
    }
}

private struct StyleBadge: View {
    let style: VoiceLabPrompt.Style

    var body: some View {
        Text(label.uppercased())
            .font(Theme.Font.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var label: String {
        switch style {
        case .normal: "Normal"
        case .whisper: "Whisper"
        case .noisy: "Noisy"
        }
    }

    private var tint: Color {
        switch style {
        case .normal: Theme.success
        case .whisper: Theme.working
        case .noisy: Theme.warning
        }
    }
}

/// Live input level, drawn as a row of bars filling left to right — matches the pill's meter
/// language elsewhere in the app but sized for a standalone control.
private struct LevelMeter: View {
    let level: Float
    let isActive: Bool
    private let barCount = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: 6, height: height(for: index))
            }
        }
        .frame(height: 40)
        .animation(Theme.fade, value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let threshold = Float(index) / Float(barCount)
        let normalized = min(level * 6, 1)
        return normalized > threshold ? 10 + CGFloat(normalized) * 26 : 6
    }

    private func color(for index: Int) -> Color {
        guard isActive else { return Theme.hairline }
        let threshold = Float(index) / Float(barCount)
        let normalized = min(level * 6, 1)
        return normalized > threshold ? Theme.phosphor : Theme.hairline
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isRecording ? Theme.error : Theme.phosphorFill)
                    .frame(width: 64, height: 64)
                    .brightness(hovering ? -0.05 : 0)
                if isRecording {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.onPhosphor).frame(width: 20, height: 20)
                } else {
                    Circle().fill(Theme.onPhosphor).frame(width: 18, height: 18)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Minimal playback control for a saved take; wraps the app's shared `AudioPlayer`.
private struct PlaybackButton: View {
    let path: String
    @State private var player = AudioPlayer.shared

    var body: some View {
        Button {
            player.toggle(path)
        } label: {
            Image(systemName: player.isActive(path) && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.phosphor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play take")
    }
}
