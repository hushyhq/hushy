import SwiftUI

/// The marks of the wait, drawn for one `PillWaitFrame` (`wait`): the listening bars folding into three
/// dots, then the dots in the frame's rhythm. A plain drawing with no clock of its own; the
/// writing view's timeline says what time it is.
///
/// Per frame: at most nine rounded rects, no text, no allocation.
struct PillWaitMarks: View {
    let wait: PillWaitFrame
    /// Seconds on any steady clock, for the dots' rhythm.
    let time: Double
    /// The nine bars as they stood at release (0 to 1). Anything else starts as dots.
    var levels: [Double] = []
    var vertical = false
    var motion = PillMotion.standard
    var reduceMotion = false
    var tint: Color = Theme.pillWorking
    var metrics = WaveformMetrics.dictation

    /// The bars fold only in a horizontal pill that has bars to fold from.
    private var folds: Bool { !vertical && !wait.showsDots && levels.count == PillFold.barCount }

    var body: some View {
        Canvas { context, size in
            if folds { drawFold(in: &context, size: size) } else { drawDots(in: &context, size: size) }
        }
        .accessibilityHidden(true)
    }

    private func drawFold(in context: inout GraphicsContext, size: CGSize) {
        let inset = (size.width - PillFold.barsWidth(metrics)) / 2
        for index in 0..<PillFold.barCount {
            let level = levels[index] * PillFold.centreWeight(index: index)
            let mark = PillFold.mark(index: index, fold: wait.fold, level: level, metrics: metrics, height: size.height)
            let path = Path(roundedRect: mark.rect.offsetBy(dx: inset, dy: 0), cornerRadius: mark.rect.width / 2)
            // Lime cools to purple: the microphone has closed and the model has the words.
            context.fill(path, with: .color(Theme.phosphorFill.opacity((1 - mark.purple) * mark.opacity)))
            context.fill(path, with: .color(Theme.pillWorking.opacity(mark.purple * mark.opacity)))
        }
    }

    private func drawDots(in context: inout GraphicsContext, size: CGSize) {
        let length = PillFold.dotsWidth
        for index in 0..<3 {
            let along = CGFloat(index) * (PillFold.dotSize + PillFold.dotGap)
            let origin = vertical
                ? CGPoint(x: (size.width - PillFold.dotSize) / 2, y: (size.height - length) / 2 + along)
                : CGPoint(x: (size.width - length) / 2 + along, y: (size.height - PillFold.dotSize) / 2)
            let rect = CGRect(origin: origin, size: CGSize(width: PillFold.dotSize, height: PillFold.dotSize))
            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(opacity(index))))
        }
    }

    /// A dot's strength now. Still under Reduce Motion; a travelling wave while work moves along;
    /// all three together, slowly, while one sentence is taking its time.
    private func opacity(_ index: Int) -> Double {
        Self.opacity(index: index, rhythm: wait.rhythm, time: time, motion: motion, reduceMotion: reduceMotion)
    }

    static func opacity(index: Int, rhythm: PillWaitFrame.Rhythm, time: Double, motion: PillMotion, reduceMotion: Bool) -> Double {
        let base = PillFold.restingOpacity[index]
        guard !reduceMotion else { return base }
        switch rhythm {
        case .folding:
            return base
        case .flowing:
            // 1.2 s a lap; never fully off.
            let wave = 0.5 + 0.5 * sin((time / 1.2 + Double(index) * 0.18) * 2 * .pi)
            return base * (0.55 + 0.45 * wave)
        case .breathing:
            // The dimmest dot would vanish if it breathed as deep as the others; lift it a little.
            return max(base, 0.5) * motion.breathe(at: time)
        }
    }
}

/// The wait's progress: a hairline inside the capsule, near its lower edge, filled as far as
/// cleanup has really got. Drawn only when there is real progress to show (`PillWaitFrame.line`).
struct PillProgressLine: View {
    /// 0 to just under 1; nil draws nothing.
    let fill: Double?
    var motion = PillMotion.standard
    var reduceMotion = false

    static let height: CGFloat = 2
    /// Clear of the capsule's round ends, so the whole line is visible.
    static let endInset: CGFloat = 12
    static let bottomInset: CGFloat = 3

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.12))
            Capsule().fill(Theme.pillWorking)
                // Transform only: the fill grows from the leading end without a layout pass.
                .scaleEffect(x: max(0.001, fill ?? 0), y: 1, anchor: .leading)
        }
        .frame(height: Self.height)
        .padding(.horizontal, Self.endInset)
        .padding(.bottom, Self.bottomInset)
        .opacity(fill == nil ? 0 : 1)
        // A step at a time under Reduce Motion: the line jumps to the truth instead of sliding.
        .animation(reduceMotion ? nil : motion.animation(.morph), value: fill)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The progress line on the pill's capsule during the wait. Nothing at all unless cleanup has
/// reported real progress; then a slow clock (four looks a second) applies the wait's one rule for
/// when the line may show (`PillWait.frame`), and the line itself moves only when a report arrives.
struct PillWritingProgress: View {
    let model: PillModel
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotWritingElapsed) private var snapshotElapsed

    var body: some View {
        if let progress = model.waitProgress, let since = model.processingStartedAt {
            TimelineView(.periodic(from: since, by: PillWritingView.reducedTick)) { context in
                let wallElapsed = isSnapshot ? snapshotElapsed : context.date.timeIntervalSince(since)
                let wait = PillWait.frame(wallElapsed: wallElapsed, progress: progress, motion: motion, reduceMotion: reduceMotion)
                PillProgressLine(fill: wait.line, motion: motion, reduceMotion: reduceMotion)
            }
        }
    }
}
