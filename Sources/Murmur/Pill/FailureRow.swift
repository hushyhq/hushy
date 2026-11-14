import SwiftUI

/// A dictation that produced no text, in one line on the capsule: a red dot, what happened, what
/// to do, Try again when its audio is still held, and ✕. Pill-sized like every other outcome row.
/// It stays until ✕, Try again or the next dictation (`DictationFailure`).
///
/// The quiet-microphone row is the same line with one button: "Use Mac mic" when the Mac's own
/// microphone is another input, or "Use Automatic" when a picked microphone delivered nothing and
/// the Mac's sound input is another one. Once tapped, the line is a tick and what is in use.
struct FailureRow: View {
    let failure: DictationFailure
    var onRetry: () -> Void = {}
    var onUseMic: () -> Void = {}
    var onUseAutomatic: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if failure.isGoodNews {
                CheckmarkDraw(tint: Theme.phosphorFill)
            } else if failure.isBrief {
                Circle().fill(.white.opacity(0.45)).frame(width: 6, height: 6)
            } else {
                Circle().fill(Theme.error).frame(width: 6, height: 6)
            }
            Text(failure.message).foregroundStyle(.white.opacity(0.9))
            if let detail = failure.detail {
                Text("· \(detail)").foregroundStyle(.white.opacity(0.55))
            }
            if failure.canRetry {
                // Lime marks the one next step, as on every other row.
                Button(DictationFailure.retryTitle, action: onRetry)
                    .buttonStyle(PillButtonStyle())
                    .padding(.leading, 2)
                    .help(DictationFailure.retryHelp)
            }
            if let offer = failure.micOffer {
                Button(QuietMic.switchTitle, action: onUseMic)
                    .buttonStyle(PillButtonStyle())
                    .padding(.leading, 2)
                    .help(failure.isHeadsetSilence ? "\(QuietMic.silenceAdvice) \(QuietMic.switchHelp(offer))" : QuietMic.switchHelp(offer))
            }
            if failure.offersAutomatic {
                Button(QuietMic.automaticTitle, action: onUseAutomatic)
                    .buttonStyle(PillButtonStyle())
                    .padding(.leading, 2)
                    .help(QuietMic.automaticHelp)
            }
            if !failure.isBrief {
                PillDismissButton(action: onDismiss)
                    .padding(.leading, 2)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}

/// The small round ✕ that closes a recovery row or card.
struct PillDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel("Dismiss")
        .help("Dismiss")
    }
}
