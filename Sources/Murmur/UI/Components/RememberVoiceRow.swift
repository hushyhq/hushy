import MurmurCore
import SwiftUI

/// What one speaker's row needs to offer "Remember <name>'s voice": whether the chip menu shows it,
/// where the consent steps are, and what each press does. Plain values and closures, so the row can be
/// rendered in a snapshot without a model.
struct SpeakerVoiceAccess {
    var availability: RememberVoiceAvailability = .hidden
    var flow: RememberVoiceFlow = .idle
    var onRequest: () -> Void = {}
    var onRemember: () -> Void = {}
    var onCancel: () -> Void = {}
}

/// The consent line under a speaker's chip. It only appears after "Remember <name>'s voice…" was
/// chosen from the chip menu; nothing is computed or stored until "Remember" is pressed here.
struct RememberVoiceRow: View {
    let name: String
    let flow: RememberVoiceFlow
    let onRemember: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch flow {
        case .idle:
            EmptyView()
        case .asking:
            line(symbol: "waveform", text: """
                Learn \(name)'s voice from this recording? It stays on this Mac, encrypted, and is only ever \
                offered as a question, never applied on its own. Forget it any time in Settings → Voices.
                """) {
                Button("Remember", action: onRemember).buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.phosphor)
                Button("Not now", action: onCancel).buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        case .working:
            line(symbol: "waveform", text: "Learning \(name)'s voice…") { ProgressView().controlSize(.small) }
        case .remembered:
            line(symbol: "checkmark.circle", text: "\(name)'s voice is remembered. Forget it any time in Settings → Voices.") {
                Button("Done", action: onCancel).buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        case .declined(let message):
            line(symbol: "exclamationmark.circle", text: message) {
                Button("OK", action: onCancel).buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func line<Trailing: View>(
        symbol: String, text: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            trailing()
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgSunken))
    }
}

/// One-tap names under the rename field (calendar attendees, when the note has them).
struct NameSuggestionRow: View {
    let names: [String]
    let onPick: (String) -> Void

    var body: some View {
        if !names.isEmpty {
            HStack(spacing: 6) {
                ForEach(names.prefix(5), id: \.self) { name in
                    Button(name) { onPick(name) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.bgSunken))
                }
            }
        }
    }
}
