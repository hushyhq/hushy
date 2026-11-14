import Combine
import MurmurCore
import SwiftUI

/// "Zoom call detected · Record notes?" and the cancellable stop countdown that follows a
/// call-detected note — see `PillBanner`/`CallDetectionState`. A small pill-shaped bar above the
/// main capsule that stays unobtrusive (it can appear mid-call, over whatever the user is doing)
/// and self-dismisses on its own.
struct CallDetectionBanner: View {
    let banner: PillBanner
    let onRecord: (MeetingApp) -> Void
    let onDismiss: () -> Void
    let onNever: (MeetingApp) -> Void
    let onCancelCountdown: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    /// Ticks once a second purely to redraw the countdown seconds; the actual stop is driven by
    /// `CallDetectionCoordinator`, not by this view reaching zero.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            switch banner {
            case .callDetected(let app, _):
                Image(systemName: "phone.fill.arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.phosphorFill)
                Text("\(app.displayName) call · Take notes?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Never for \(app.displayName)") { onNever(app) }
                    .buttonStyle(GhostPillButtonStyle())
                Button("Not now") { onDismiss() }
                    .buttonStyle(GhostPillButtonStyle())
                Button("Record") { onRecord(app) }
                    .buttonStyle(PillButtonStyle())
            case .stopCountdown(let fireAt):
                Circle().fill(Theme.warning).frame(width: 6, height: 6)
                Text("Call ended · stopping in \(secondsRemaining(until: fireAt))s")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Button("Keep recording") { onCancelCountdown() }
                    .buttonStyle(GhostPillButtonStyle())
            case .maxLengthWarning:
                Circle().fill(Theme.warning).frame(width: 6, height: 6)
                Text("Recording will stop in 2 min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(GhostPillButtonStyle())
            case .microphoneFallback:
                Image(systemName: "mic.fill")
                    .foregroundStyle(Theme.warning)
                Text(banner.microphoneFallbackLine ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            case .captureNotice(let line):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text(line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            case .cleanupModelWaiting(let line, let progress):
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.warning)
                Text(line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                if let progress {
                    PillDownloadBar(fraction: progress).padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 320)
        .background(
            ZStack {
                if !isSnapshot { VisualEffectBlur() }
                Theme.pillSurface
            })
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .environment(\.colorScheme, .dark)
        .onReceive(ticker) { now = $0 }
    }

    private func secondsRemaining(until fireAt: Date) -> Int {
        max(0, Int(fireAt.timeIntervalSince(now).rounded(.up)))
    }
}

/// The model download's progress inside the pill note: a short track with the done part filled.
private struct PillDownloadBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.14))
            .frame(width: 72, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.warning).frame(width: 72 * min(1, max(0.04, fraction)), height: 4)
            }
            .accessibilityElement()
            .accessibilityLabel("Download progress")
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// A dictation that didn't land, in one line (UI round 2026-09-28 §1). Graphite, no rim or glow:
/// nothing is live. Lime marks only the one next step — the ⌘ V key caps, or the held row's Copy —
/// as in the idle hint (DESIGN-LANGUAGE.md §1, §5.1). The pill never shows the dictated text here;
/// it is in History (and, for `.copied`, on the clipboard).
struct NotPastedRow: View {
    enum Kind: Equatable {
        /// "📋 Copied · switched apps  ⌘ V to paste".
        case copied(CopyReason)
        /// "🔒 Not pasted · password field [Copy] [History]", then "Copied" once tapped — never with
        /// the ⌘V hint, which beside a password field would invite pasting it there. The words are
        /// never drawn here; History opens that dictation in the main window, where they are.
        case held(copied: Bool)
    }

    let kind: Kind
    var onCopy: () -> Void = {}
    var onHistory: () -> Void = {}

    var body: some View {
        switch kind {
        case .copied(let reason): copiedRow(reason)
        case .held(let copied): heldRow(copied: copied)
        }
    }

    private func copiedRow(_ reason: CopyReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Copied").foregroundStyle(.white.opacity(0.75))
            Text("· \(reason.phrase)").foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 2) {
                KeyCap(label: "⌘")
                KeyCap(label: "V")
            }
            .padding(.leading, 2)
            Text("to paste").foregroundStyle(.white.opacity(0.45))
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize()
        .help(reason.help)
    }

    @ViewBuilder
    private func heldRow(copied: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: copied ? "doc.on.clipboard" : "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            if copied {
                Text("Copied").foregroundStyle(.white.opacity(0.75))
            } else {
                Text("Not pasted").foregroundStyle(.white.opacity(0.75))
                Text("· password field").foregroundStyle(.white.opacity(0.45))
                Button("Copy", action: onCopy)
                    .buttonStyle(PillButtonStyle())
                    .padding(.leading, 2)
                    .help("Copy what you said. Nothing was pasted into the password field.")
                Button("History", action: onHistory)
                    .buttonStyle(GhostPillButtonStyle())
                    .accessibilityLabel("Open in History")
                    .help("Open this dictation in History to read it")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize()
    }
}
