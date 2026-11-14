import MurmurCore
import SwiftUI

/// Home's loading progress: one segment per stage the speech model really goes through
/// (`SpeechLoadProgress`), each as wide as that stage usually takes on this Mac. A finished stage
/// is full. The one under way fills as its usual time passes; with no usual time to go by, or
/// once it has run past it, it breathes at a lower strength instead of pretending to a fraction.
/// Beside it, the step and either the time left or that it is taking longer than usual.
///
/// Only opacity and scale move. With Reduce Motion nothing breathes and the fill steps.
struct LoadStageTrack: View {
    let display: SpeechLoadProgress.Display
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var breathesIn = false

    /// How often the card looks at the clock while loading.
    static let tick: TimeInterval = 0.5
    static let height: CGFloat = 8
    static let width: CGFloat = 300
    /// The shortest the track gets before its line moves under it.
    static let shortest: CGFloat = 150

    var body: some View {
        // The track and its line side by side, so loading takes no more room than the ready
        // card's two lines; one above the other only where the card is too narrow.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) {
                track
                statusLine
            }
            VStack(alignment: .leading, spacing: 6) {
                track
                statusLine
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Getting dictation ready")
        .accessibilityValue(display.spokenValue)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { breathesIn = true }
    }

    private var statusLine: some View {
        Text(display.statusLine)
            .font(Theme.Font.data)
            .foregroundStyle(display.isSlow ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// One segment per stage, each as wide as the stage usually takes. The track takes what room
    /// the row has, between its shortest and longest lengths.
    private var track: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 4
            let total = max(display.segments.reduce(0) { $0 + $1.weight }, 0.001)
            let room = max(proxy.size.width - gap * CGFloat(max(display.segments.count - 1, 0)), 0)
            HStack(spacing: gap) {
                ForEach(display.segments, id: \.stage) { segment in
                    bar(segment.step).frame(width: room * segment.weight / total)
                }
            }
        }
        .frame(minWidth: Self.shortest, idealWidth: Self.shortest, maxWidth: Self.width)
        .frame(height: Self.height)
    }

    @ViewBuilder
    private func bar(_ step: SpeechLoadProgress.Display.Step) -> some View {
        let track = Capsule().fill(Theme.working.opacity(0.18))
        switch step {
        case .done:
            Capsule().fill(Theme.working).frame(height: Self.height)
        case .pending:
            track.frame(height: Self.height)
        case .current(let fraction?):
            track
                .overlay(alignment: .leading) {
                    // A scale, not a width: the fill grows without a layout pass.
                    Capsule().fill(Theme.working)
                        .scaleEffect(x: max(fraction, 0.04), y: 1, anchor: .leading)
                        .animation(reduceMotion || isSnapshot ? nil : .linear(duration: Self.tick), value: fraction)
                }
                .clipShape(Capsule())
                .frame(height: Self.height)
        case .current(nil):
            // In progress, length unknown: the whole segment breathes.
            track
                .overlay {
                    Capsule().fill(Theme.working)
                        .opacity(reduceMotion || isSnapshot ? 0.38 : (breathesIn ? 0.55 : 0.2))
                        .animation(reduceMotion || isSnapshot ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                   value: breathesIn)
                }
                .frame(height: Self.height)
        }
    }
}
