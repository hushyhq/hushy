import SwiftUI

/// The onboarding hero: a sculpture of one spoken sentence — stacked waveform lines receding in
/// perspective, the nearest line lit phosphor, the far ones cooling to graphite
/// (docs/design/DESIGN-LANGUAGE.md §5.5). It is the one large piece of motion in the app, earned
/// because it's the first time the user sees Hushy hear anything.
///
/// Energy: drawn with `Canvas` at most 60 fps, and paused whenever it isn't being looked at —
/// off screen, window inactive (e.g. while the user is in System Settings granting a
/// permission), Reduce Motion, or snapshot rendering (a single still frame).
struct VoiceField: View {
    /// 0…1 live input level; `nil` drives the field with a slow synthetic "idle breath".
    var level: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var scheme
    @State private var isOnScreen = false

    static let lineCount = 26
    private static let samples = 96
    /// A still frame's time, chosen so the sculpture reads as a sentence mid-word.
    private static let stillTime: Double = 7.3

    private var isPaused: Bool { reduceMotion || isSnapshot || !isOnScreen || !appearsActive }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { context in
            Canvas { graphics, size in
                let time = isPaused ? Self.stillTime : context.date.timeIntervalSinceReferenceDate
                draw(in: &graphics, size: size, time: time)
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .accessibilityHidden(true)
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, time: Double) {
        let lines = Self.lineCount
        let horizon = size.height * 0.08
        let front = size.height * 0.94
        let energy = level.map { 0.35 + 0.9 * min(max($0, 0), 1) } ?? idleEnergy(time)
        let far = Theme.textTertiary
        let near = Theme.phosphorFill

        for line in 0..<lines {
            // depth 0 = farthest, 1 = nearest. Lines bunch toward the horizon (perspective).
            let depth = Double(line) / Double(lines - 1)
            let perspective = depth * depth
            let baseline = horizon + (front - horizon) * CGFloat(perspective)
            let inset = size.width * CGFloat(0.22 * (1 - perspective))
            let width = size.width - inset * 2
            let amplitude = CGFloat(4 + 46 * perspective) * CGFloat(energy)
            // Each line is the same sentence a moment later: the phase walks back with depth.
            let phase = time * 0.9 - depth * 2.4

            var path = Path()
            for index in 0...Self.samples {
                let x = Double(index) / Double(Self.samples)
                let y = sentence(x: x, phase: phase)
                let point = CGPoint(x: inset + width * CGFloat(x), y: baseline - amplitude * CGFloat(y))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let isNearest = line == lines - 1
            let opacity = isNearest ? 1 : 0.1 + 0.55 * perspective
            let color = isNearest ? near : (depth > 0.8 ? near.opacity(0.35 + (depth - 0.8) * 2) : far)
            graphics.stroke(
                path, with: .color(color.opacity(opacity)),
                style: StrokeStyle(lineWidth: isNearest ? 1.6 : 0.8 + 0.6 * perspective, lineCap: .round, lineJoin: .round))
            if isNearest, scheme == .dark {
                // Afterglow on the live line only.
                graphics.stroke(path, with: .color(near.opacity(0.18)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
    }

    /// A speech-like envelope: syllable bumps under a word envelope, tapering to silence at the
    /// edges, so every line reads as a spoken phrase rather than a sine.
    private func sentence(x: Double, phase: Double) -> Double {
        let taper = sin(x * .pi)
        let words = max(0, sin(x * 9.0 + phase * 0.7)) * 0.6 + 0.4
        let syllables = sin(x * 38 + phase * 3.1) * 0.55 + sin(x * 71 - phase * 2.3) * 0.3
        return taper * taper * words * syllables
    }

    /// A slow breath (about 6 s) so the idle field is alive without asking for attention.
    private func idleEnergy(_ time: Double) -> Double {
        0.55 + 0.2 * sin(time * 1.05)
    }
}
