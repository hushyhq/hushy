import SwiftUI

/// A symmetric, centre-weighted bar waveform driven by recent audio levels, tallest in the
/// middle — the live counterpart to the idle pill's resting wave, and the brand's trace
/// (docs/design/DESIGN-LANGUAGE.md §1). Drawn with `TimelineView` + `Canvas` so bars spring
/// toward new levels at display rate (120 Hz on ProMotion) without SwiftUI re-laying out a view
/// per bar on every audio callback. Per-frame work is a handful of rounded rects: no allocation,
/// no text.
///
/// Afterglow: when `peaks` is given, each bar also draws a faint cap at its recent peak, which
/// decays in `PillModel` along the cool curve — a whisper visibly registers, and speech leaves
/// a phosphor persistence trail.
/// The bar geometry of a `Waveform` (points). `standard` is the pill's resting/working wave;
/// `dictation` is the larger one Listening and Hands-free show (design v3: 3 pt bars, 3 pt gaps,
/// up to 22 pt tall).
struct WaveformMetrics: Equatable {
    var barWidth: CGFloat
    var spacing: CGFloat
    var minHeight: CGFloat
    var maxExtra: CGFloat
    var frameHeight: CGFloat

    static let standard = WaveformMetrics(barWidth: 2.5, spacing: 2.5, minHeight: 4, maxExtra: 14, frameHeight: 18)
    static let dictation = WaveformMetrics(barWidth: 3, spacing: 3, minHeight: 4, maxExtra: 18, frameHeight: 22)
}

struct Waveform: View {
    let levels: [Double]
    var peaks: [Double] = []
    var metrics = WaveformMetrics.standard
    /// Gentle travelling shimmer instead of level-driven motion, for the processing state.
    var shimmer = false
    /// The vertical side pill (founder decision 2026-09-28): bars run top to bottom and grow
    /// sideways — the same drawing, rotated a quarter turn.
    var vertical = false
    /// The levels one update earlier, and when `levels` replaced them: with both, each bar glides
    /// from its old level to its new one over one update instead of stepping. Without them the
    /// bars are drawn at `levels` as they are.
    var previous: [Double] = []
    var updatedAt: Date?
    /// False while the microphone has been asked for but has sent no audio yet: the bars are grey.
    /// Lime only ever means the microphone is open and heard.
    var isLive = true
    /// An open microphone in silence breathes very slightly, so it never looks frozen.
    var breathesInSilence = false
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion

    private static let ghostHeight: CGFloat = 1.5
    private static let ghostGap: CGFloat = 1.5
    /// How often the pill's levels are replaced (`PillModel.push`): the length of one glide.
    static let levelInterval: TimeInterval = 0.03
    /// Below this loudest bar the room counts as silent; the breath fades out as it is approached.
    static let silenceCeiling = 0.08
    /// How much of a bar's range the breath may lift it: about a point of slow movement.
    static let breathDepth = 0.14

    var body: some View {
        // Paused under Reduce Motion (bars jump to their level; processing shows static bars),
        // so a Reduce Motion pill costs no per-frame work at all.
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { graphicsContext, size in
                if vertical {
                    graphicsContext.translateBy(x: size.width, y: 0)
                    graphicsContext.rotate(by: .degrees(90))
                    draw(in: &graphicsContext, size: CGSize(width: size.height, height: size.width), date: context.date)
                } else {
                    draw(in: &graphicsContext, size: size, date: context.date)
                }
            }
            .frame(width: vertical ? metrics.frameHeight : totalWidth, height: vertical ? totalWidth : metrics.frameHeight)
        }
        .frame(width: vertical ? metrics.frameHeight : totalWidth, height: vertical ? totalWidth : metrics.frameHeight)
        .accessibilityHidden(true)
    }

    private func draw(in graphicsContext: inout GraphicsContext, size: CGSize, date: Date) {
        let count = levels.count
        guard count > 0 else { return }
        let time = date.timeIntervalSinceReferenceDate
        let midY = size.height / 2
        let showsGhosts = !shimmer && !reduceMotion && isLive && peaks.count == count
        let quiet = breath(loudest: levels.max() ?? 0)
        for index in 0..<count {
            let weight = centerWeight(index: index, count: count)
            let level = shimmer
                ? shimmerLevel(index: index, count: count, time: time)
                : min(1, glidingLevel(index: index, date: date) * weight + quiet * motion.breathe(at: time - Double(index) * 0.18))
            let barHeight = metrics.minHeight + metrics.maxExtra * level
            let x = CGFloat(index) * (metrics.barWidth + metrics.spacing)
            let rect = CGRect(x: x, y: midY - barHeight / 2, width: metrics.barWidth, height: barHeight)
            // Lime while the mic is live and heard, grey until it is; the processing shimmer takes
            // the "working" purple.
            let barColor = shimmer ? Theme.pillWorking : (isLive ? Theme.phosphorFill : Theme.pillIdleMark)
            graphicsContext.fill(Path(roundedRect: rect, cornerRadius: metrics.barWidth / 2), with: .color(barColor))

            guard showsGhosts else { continue }
            let peakHeight = metrics.minHeight + metrics.maxExtra * min(peaks[index] * weight, 1)
            // Only a ghost that clearly sits above the live bar is drawn — at rest they coincide.
            guard peakHeight > barHeight + Self.ghostGap * 2 else { continue }
            let ghostOpacity = 0.4 * min(1, (peakHeight - barHeight) / 6)
            let top = CGRect(x: x, y: midY - peakHeight / 2, width: metrics.barWidth, height: Self.ghostHeight)
            let bottom = CGRect(x: x, y: midY + peakHeight / 2 - Self.ghostHeight, width: metrics.barWidth, height: Self.ghostHeight)
            let shading = GraphicsContext.Shading.color(Theme.phosphorFill.opacity(ghostOpacity))
            graphicsContext.fill(Path(roundedRect: top, cornerRadius: Self.ghostHeight / 2), with: shading)
            graphicsContext.fill(Path(roundedRect: bottom, cornerRadius: Self.ghostHeight / 2), with: shading)
        }
    }

    private var totalWidth: CGFloat {
        let count = CGFloat(levels.count)
        return count * metrics.barWidth + max(count - 1, 0) * metrics.spacing
    }

    private func centerWeight(index: Int, count: Int) -> Double {
        1 - abs(Double(index) - Double(count - 1) / 2) / Double(count) * 0.9
    }

    /// The level bar `index` shows at `date`: on its way from the level it had one update ago to
    /// the one it has now (`Self.glide`), with a tiny per-bar wobble so the bars never move in
    /// perfect lockstep, like a murmur rather than a mechanical equalizer. Under Reduce Motion the
    /// bar is simply at its level.
    private func glidingLevel(index: Int, date: Date) -> Double {
        guard levels.indices.contains(index) else { return 0 }
        let target = levels[index]
        if reduceMotion { return target }
        var level = target
        if previous.count == levels.count, let updatedAt {
            level = Self.glide(from: previous[index], to: target, elapsed: date.timeIntervalSince(updatedAt))
        }
        let wobblePhase = date.timeIntervalSinceReferenceDate * 6 + Double(index) * 0.7
        let wobble = sin(wobblePhase) * 0.03 * level
        return min(max(level + wobble, 0), 1)
    }

    /// Where a bar is `elapsed` seconds after its level was replaced: a straight line from the old
    /// level to the new one over one update, then the new level.
    static func glide(from old: Double, to new: Double, elapsed: TimeInterval) -> Double {
        let share = min(1, max(0, elapsed / levelInterval))
        return old + (new - old) * share
    }

    /// How much of a bar's range the silent breath may move, given the loudest bar: `breathDepth`
    /// in a silent room, fading to nothing as speech arrives. Nothing unless this waveform is an
    /// open microphone (`breathesInSilence`, `isLive`), and nothing under Reduce Motion.
    private func breath(loudest: Double) -> Double {
        guard breathesInSilence, isLive, !shimmer, !reduceMotion else { return 0 }
        return Self.breathDepth * max(0, 1 - loudest / Self.silenceCeiling)
    }

    /// A soft travelling highlight through the bars while a transcript is processing — motion
    /// that clarifies "still working," not a level reading.
    private func shimmerLevel(index: Int, count: Int, time: Double) -> Double {
        if reduceMotion {
            // Static, gently graduated bars: no motion, still reads as "processing."
            return 0.25 + 0.15 * (1 - abs(Double(index) - Double(count - 1) / 2) / Double(count))
        }
        let phase = (time.truncatingRemainder(dividingBy: 1.6)) / 1.6
        let position = phase * Double(count + 3) - 2
        let distance = abs(Double(index) - position)
        let wave = max(0, 1 - distance / 2.2)
        return 0.18 + 0.65 * wave
    }
}
