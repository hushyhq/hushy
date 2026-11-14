import MurmurCore
import SwiftUI

/// Replaces the note-recording row when ✕ is tapped: an inline "Discard this note?" confirm,
/// so a single misclick can't lose a recording.
struct DiscardConfirmRow: View {
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Discard note?")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Button("Keep", action: onKeep)
                .buttonStyle(GhostPillButtonStyle())
            Button("Discard", role: .destructive, action: onDiscard)
                .buttonStyle(DestructivePillButtonStyle())
        }
        .fixedSize()
    }
}

struct ElapsedTime: View {
    let since: Date

    /// "0:42", "12:04": minutes are not capped, seconds are always two digits.
    static func format(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The type is monospaced, so the label keeps its width while its digit count holds: it
    /// grows by one character at ten minutes and again at a hundred, and never from second to
    /// second. Reserving room for the longest time left a gap either side of a short one.
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.format(seconds: Int(context.date.timeIntervalSince(since))))
        }
        .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct CheckmarkDraw: View {
    /// Dictation's Done is lime (design v3); other callers keep the success green.
    var tint: Color = Theme.success
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var progress: CGFloat = 0

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 6))
            path.addLine(to: CGPoint(x: 5, y: 10))
            path.addLine(to: CGPoint(x: 13, y: 2))
        }
        .trim(from: 0, to: progress)
        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .frame(width: 14, height: 12)
        // Success is the one place with an overshoot (`Motion.pop`): the stroke draws, the mark
        // lands with a small bounce. Snapshots and Reduce Motion show it already drawn.
        .scaleEffect(reduceMotion || isSnapshot ? 1 : (progress == 1 ? 1 : 0.7))
        .onAppear {
            guard !reduceMotion, !isSnapshot else { progress = 1; return }
            withAnimation(motion.animation(.draw)) { progress = 1 }
        }
        .animation(motion.animation(.pop, reduceMotion: reduceMotion), value: progress)
    }
}

struct KeyCap: View {
    let label: String
    /// 10 pt in the pill and its hints; Settings shows the chord a step larger.
    var size: CGFloat = 10

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.onPhosphor)
            .padding(.horizontal, size / 2)
            .frame(minWidth: size * 1.8, minHeight: size * 1.6)
            .background(RoundedRectangle(cornerRadius: size * 0.4).fill(Theme.phosphorFill))
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.onPhosphor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.phosphorFill.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

struct GhostPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.1 : 0.14)))
    }
}

struct DestructivePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.error.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
