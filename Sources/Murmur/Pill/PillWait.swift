import CoreGraphics
import Foundation
import MurmurCore

/// The wait between key release and the paste, as the pill draws it: a pure function of the time
/// since release and of real progress, so every rule about it can be tested without a view.
///
/// The rules:
/// - For the first `directDoneWindow` the listening bars fold into the three writing dots. A paste
///   that lands inside that window is shown as bars turning straight into the ✓: no dots flash by.
///   (The ✓ itself is never drawn here. It belongs to the done state, which the dictation path
///   sets only after the paste has gone out.)
/// - "Writing…" from 1 s and "Still writing…" from 5 s, as before (`WritingPhase`).
/// - A progress line only when cleanup reports real progress (a dictation cleaned sentence group
///   by sentence group). It never goes backwards, never reaches full while the pill is still
///   waiting, and when no group has finished for a while the dots change rhythm instead of the
///   line pretending to move.
struct PillWaitFrame: Equatable {
    enum Rhythm: Equatable {
        /// Bars are still folding into dots.
        case folding
        /// A soft wave through the dots: work is moving along.
        case flowing
        /// All three dots rise and fall together, slowly: one sentence is taking its time.
        case breathing
    }

    /// 0 while the marks are still the listening bars, 1 once they are the three dots.
    var fold: Double
    var rhythm: Rhythm
    /// The words beside the dots, if any.
    var label: String?
    /// How much of the progress line is filled, 0 to just under 1; nil when there is no line.
    var line: Double?

    var showsDots: Bool { fold >= 1 }
}

/// Real cleanup progress as the pill keeps it for one wait.
struct PillWaitProgress: Equatable {
    /// The share of the whole job that is done, the paste included: always under 1 while waiting.
    var fill: Double
    /// Seconds after release at which `fill` last grew.
    var advancedAt: TimeInterval

    /// The paste is the last part of the job, so cleanup alone never fills the line.
    static let deliveryShare = 0.08

    /// The fill for a cleanup report, or nil when there is no honest fraction to show: a dictation
    /// cleaned in one call has no groups to count.
    static func fill(for progress: CleanupProgress) -> Double? {
        guard progress.groupCount > 1, progress.wordCount > 0 else { return nil }
        return progress.fraction * (1 - deliveryShare)
    }

    /// This progress after a new report at `elapsed` seconds. The fill only ever grows; a report
    /// that does not grow it leaves `advancedAt` alone, so a stall is measured from the last real step.
    func advanced(by report: CleanupProgress, at elapsed: TimeInterval) -> PillWaitProgress {
        guard let fill = Self.fill(for: report), fill > self.fill else { return self }
        return PillWaitProgress(fill: fill, advancedAt: elapsed)
    }

    /// The first report of a wait.
    static func starting(with report: CleanupProgress, at elapsed: TimeInterval) -> PillWaitProgress? {
        fill(for: report).map { PillWaitProgress(fill: $0, advancedAt: elapsed) }
    }
}

enum PillWait {
    /// With progress showing, no group finishing for this long changes the dots to breathing.
    static let stallAfter: TimeInterval = 1.5

    /// What to draw `elapsed` seconds after release.
    static func frame(
        elapsed: TimeInterval, progress: PillWaitProgress? = nil, motion: PillMotion = .standard, reduceMotion: Bool = false
    ) -> PillWaitFrame {
        let window = motion.directDoneWindow
        // Under Reduce Motion nothing folds: the dots are simply there.
        let fold = reduceMotion || window <= 0 ? 1 : min(1, max(0, elapsed / window))
        let folded = fold >= 1
        let rhythm: PillWaitFrame.Rhythm
        if !folded {
            rhythm = .folding
        } else if let progress, elapsed - progress.advancedAt > stallAfter {
            rhythm = .breathing
        } else {
            rhythm = .flowing
        }
        return PillWaitFrame(
            fold: fold, rhythm: rhythm, label: WritingPhase.phase(after: elapsed).label,
            // The line waits for the dots, so a quick paste never flashes one.
            line: folded ? progress.map { min($0.fill, 1 - PillWaitProgress.deliveryShare) } : nil)
    }
}

extension PillWait {
    /// The frame `wallElapsed` seconds of real time after release, at the motion's speed: 1 in the
    /// app, so real time is the wait's time; the preview's slow motion slows the wait with it.
    static func frame(
        wallElapsed: TimeInterval, progress: PillWaitProgress?, motion: PillMotion, reduceMotion: Bool
    ) -> PillWaitFrame {
        let paced = progress.map { PillWaitProgress(fill: $0.fill, advancedAt: $0.advancedAt * motion.speed) }
        return frame(elapsed: wallElapsed * motion.speed, progress: paced, motion: motion, reduceMotion: reduceMotion)
    }
}

/// How the nine listening bars become the three writing dots: each run of three bars closes onto
/// one dot while its colour cools from lime to the working purple. Geometry only.
enum PillFold {
    static let barCount = PillModel.barCount
    static let dotSize: CGFloat = 5
    static let dotGap: CGFloat = 4
    /// The dots at rest: dim, mid, full.
    static let restingOpacity: [Double] = [0.35, 0.65, 1]

    struct Mark: Equatable {
        var rect: CGRect
        /// 0 lime (the microphone's colour) to 1 purple (the model's).
        var purple: Double
        var opacity: Double
    }

    /// The width of the three dots side by side.
    static var dotsWidth: CGFloat { 3 * dotSize + 2 * dotGap }

    /// The width of the bars the fold starts from.
    static func barsWidth(_ metrics: WaveformMetrics) -> CGFloat {
        CGFloat(barCount) * metrics.barWidth + CGFloat(barCount - 1) * metrics.spacing
    }

    /// Mark `index` (0 to 8) at `fold` (0 bars, 1 dots), drawn in a strip `barsWidth` wide and
    /// `height` tall with the dots centred in it. `level` is the bar's last height share, 0 to 1.
    static func mark(index: Int, fold: Double, level: Double, metrics: WaveformMetrics, height: CGFloat) -> Mark {
        let progress = CGFloat(ease(min(1, max(0, fold))))
        let dot = min(2, index * 3 / barCount)
        let barHeight = metrics.minHeight + metrics.maxExtra * CGFloat(min(1, max(0, level)))
        let barX = CGFloat(index) * (metrics.barWidth + metrics.spacing)
        let dotX = (barsWidth(metrics) - dotsWidth) / 2 + CGFloat(dot) * (dotSize + dotGap)
        let width = metrics.barWidth + (dotSize - metrics.barWidth) * progress
        let markHeight = barHeight + (dotSize - barHeight) * progress
        let x = barX + (dotX - barX) * progress
        let rect = CGRect(x: x, y: (height - markHeight) / 2, width: width, height: markHeight)
        let opacity = 1 + (restingOpacity[dot] - 1) * Double(progress)
        return Mark(rect: rect, purple: Double(progress), opacity: opacity)
    }

    /// How much of its level a bar shows: tallest in the middle, as the listening waveform draws it.
    static func centreWeight(index: Int) -> Double {
        1 - abs(Double(index) - Double(barCount - 1) / 2) / Double(barCount) * 0.9
    }

    /// Ease out: quick away from the bars, gentle onto the dots.
    static func ease(_ value: Double) -> Double {
        1 - pow(1 - value, 3)
    }
}
