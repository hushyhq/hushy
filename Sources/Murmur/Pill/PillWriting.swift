import SwiftUI

/// The pill between key release and paste (design v3, "Writing"): three purple dots, and from 1 s
/// a label saying so. The internal stages (hearing → polishing → typing) are never shown — the
/// user's mental model is "my words are being written", not our pipeline.
enum WritingPhase: Equatable {
    /// Under a second: the dots alone. Most dictations never leave this phase.
    case dots
    /// From 1 s: the last few words already heard, or "Writing…" when none have arrived.
    case writing
    /// From 5 s: the wait is named, and the person is told the words will still be pasted.
    case stillWriting

    static let labelDelay: TimeInterval = 1
    static let stillDelay: TimeInterval = 5
    /// How many trailing words the writing pill shows from 1 s (`PillModel.ink`).
    static let previewWordCount = 4
    static let stillWritingMessage = "Still writing…"  // pill-sized; a sentence here tripled the capsule

    static func phase(after elapsed: TimeInterval) -> WritingPhase {
        if elapsed >= stillDelay { return .stillWriting }
        if elapsed >= labelDelay { return .writing }
        return .dots
    }

    /// The words beside the dots. From 1 s, the tail of `ink` (the words already heard). From 5 s,
    /// "Still writing…", which does not repeat those words.
    static func label(after elapsed: TimeInterval, ink: String?) -> String? {
        switch phase(after: elapsed) {
        case .dots: nil
        case .writing: preview(ink) ?? "Writing…"
        case .stillWriting: Self.stillWritingMessage
        }
    }

    /// The last few words of the ink preview. Nil when nothing has been heard yet.
    static func preview(_ ink: String?) -> String? {
        guard let ink else { return nil }
        let words = ink.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.suffix(previewWordCount).joined(separator: " ")
    }

    var label: String? {
        switch self {
        case .dots: nil
        case .writing: "Writing…"
        case .stillWriting: Self.stillWritingMessage
        }
    }
}

/// The capsule size fixed by the v3 mock for push-to-talk dictation (points).
enum PillMetrics {
    static let listening = CGSize(width: 104, height: 32)
    /// The resting capsule (`PillIdleMark` plus its end padding). It hugs its glyph rather than
    /// being fixed, so `size(for:)` has no case for it; this is the size it comes to.
    static let idle = CGSize(width: 40, height: 10)

    /// The fixed capsule for a state, or `nil` when the capsule fits its content.
    static func size(for state: PillState) -> CGSize? {
        switch state {
        case .listening: listening
        default: nil
        }
    }
}

/// The pill between key release and paste: the listening bars fold into three dots in the
/// "working" purple, and from 1 s a label says so (`PillWait` holds the rules, `PillWaitMarks`
/// draws the marks). Under Reduce Motion the dots hold still at their resting strengths and the
/// label still arrives on time. Vertical pills show the dots alone, stacked, since text only
/// reads horizontally.
struct PillWritingView: View {
    let since: Date
    var vertical = false
    /// The words beside the dots after `elapsed` seconds, if any. Dictation's are "Writing…" and
    /// "Still writing…"; a voice action passes its own (`ActionWorkingPhase`).
    var label: (TimeInterval) -> String? = { WritingPhase.label(after: $0, ink: nil) }
    /// The listening bars as they stood at release: the dots fold out of them. Without them (a
    /// voice action, a side pill) the dots are simply there.
    var levels: [Double] = []
    /// Real cleanup progress, when there is some: a stall changes the dots' rhythm.
    var progress: PillWaitProgress?
    var tint: Color = Theme.pillWorking
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion
    @Environment(\.isSnapshot) private var isSnapshot
    /// Snapshots have no clock; the harness says how long Writing has "lasted".
    @Environment(\.snapshotWritingElapsed) private var snapshotElapsed
    @Environment(\.snapshotWritingMoves) private var snapshotMoves

    /// Between the marks and the label.
    static let labelGap: CGFloat = 8
    /// How often a still pill looks at the clock, so its label still arrives on time.
    static let reducedTick: TimeInterval = 0.25

    /// A still pill's clock. It used to be paused under Reduce Motion, which stopped the dots
    /// (right) and also the label (wrong: "Writing…" never appeared). Nothing moves, so it only
    /// has to tick often enough for the words to arrive on time.
    static func reducedSchedule(since: Date) -> PeriodicTimelineSchedule {
        .periodic(from: since, by: reducedTick)
    }

    private var canFold: Bool { !vertical && levels.count == PillFold.barCount }

    var body: some View {
        Group {
            if reduceMotion {
                TimelineView(Self.reducedSchedule(since: since)) { marksAndLabel(at: $0.date) }
            } else {
                // The marks animate; 60 a second is plenty for dots.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isSnapshot)) { marksAndLabel(at: $0.date) }
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func marksAndLabel(at date: Date) -> some View {
        let wallElapsed = isSnapshot ? snapshotElapsed : date.timeIntervalSince(since)
        // A still image shows the wait at rest (the dots), unless it asks for the frame in motion.
        let still = reduceMotion || (isSnapshot && !snapshotMoves)
        let wait = PillWait.frame(wallElapsed: wallElapsed, progress: progress, motion: motion, reduceMotion: still)
        let text = label(wallElapsed * motion.speed)
        let marks = marksSize(hasLabel: text != nil)
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: PillFold.dotGap)) : AnyLayout(HStackLayout(spacing: Self.labelGap))
        return layout {
            PillWaitMarks(
                wait: wait, time: isSnapshot ? 0 : date.timeIntervalSinceReferenceDate, levels: canFold ? levels : [],
                vertical: vertical, motion: motion, reduceMotion: still, tint: tint)
                .frame(width: marks.width, height: marks.height)
            if !vertical, let text {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        // The dots step aside for the word in one move; under Reduce Motion the word is simply there.
        .animation(reduceMotion ? nil : motion.animation(.morph), value: text)
    }

    /// The room the marks take. A pill that folds keeps the bars' width until a label arrives, so
    /// the dots sit where the bars' middle was; then the dots take only their own width.
    func marksSize(hasLabel: Bool) -> CGSize {
        if vertical { return CGSize(width: PillFold.dotSize, height: PillFold.dotsWidth) }
        let metrics = WaveformMetrics.dictation
        return CGSize(width: canFold && !hasLabel ? PillFold.barsWidth(metrics) : PillFold.dotsWidth,
                      height: canFold ? metrics.frameHeight : PillFold.dotSize)
    }
}

extension EnvironmentValues {
    /// How long the snapshot harness pretends Writing has lasted (0 shows the dots, 2 shows the
    /// last few words or "Writing…", 6 shows "Still writing…"). Ignored outside snapshots.
    @Entry var snapshotWritingElapsed: TimeInterval = 0
    /// A snapshot that wants the wait exactly as it is drawn at `snapshotWritingElapsed` (bars part
    /// way into dots, the stalled rhythm) rather than the dots at rest. Ignored outside snapshots.
    @Entry var snapshotWritingMoves = false
}
