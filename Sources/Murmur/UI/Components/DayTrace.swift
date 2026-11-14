import MurmurCore
import SwiftUI

/// The Today trace: when you spoke today, as a strip of thin bars (one per 20 minutes) from the
/// start of the waking day to midnight — the brand's waveform trace at the scale of a day
/// (docs/design/DESIGN-LANGUAGE.md §5.2). Past speech is graphite ink; the most recent burst is
/// lit phosphor (its afterglow); the future is a dotted baseline; a tick marks now.
///
/// Static: drawn once per data change with `Canvas`, no timeline — Home at rest costs nothing.
struct DayTrace: View {
    let model: DayTraceModel
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: Self.height)
            hourLabels
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilitySummary)
    }

    private var hourLabels: some View {
        GeometryReader { proxy in
            ForEach(model.hourMarks, id: \.self) { hour in
                Text(Self.hourLabel(hour))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
                    .position(x: proxy.size.width * model.fraction(ofHour: hour), y: 6)
            }
        }
        .frame(height: 12)
    }

    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0, 24: "12a"
        case 12: "12p"
        default: hour < 12 ? "\(hour)a" : "\(hour - 12)p"
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let count = model.buckets.count
        guard count > 0 else { return }
        let step = size.width / CGFloat(count)
        let barWidth = max(1.5, min(4, step * 0.6))
        let baseline = size.height - 1
        let ink = Theme.textSecondary.opacity(scheme == .dark ? 0.55 : 0.45)
        let dot = Theme.textTertiary.opacity(0.45)

        for (index, value) in model.buckets.enumerated() {
            let x = CGFloat(index) * step + (step - barWidth) / 2
            if index > model.nowIndex {
                // The rest of the day: a dotted baseline, not bars — nothing has been said yet.
                if index % 2 == 0 {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: baseline - 1, width: 1.5, height: 1.5)), with: .color(dot))
                }
                continue
            }
            let height = value > 0 ? max(3, (size.height - 2) * CGFloat(value)) : 1
            let rect = CGRect(x: x, y: baseline - height, width: barWidth, height: height)
            let isAfterglow = index == model.latestActiveIndex
            let color: Color = value == 0 ? Theme.hairline : (isAfterglow ? Theme.phosphor : ink)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }

        // Now: a short phosphor tick above the baseline, in the next slot.
        let nowX = CGFloat(model.nowIndex) * step + step / 2
        let tick = CGRect(x: nowX - 0.75, y: 2, width: 1.5, height: size.height - 3)
        context.fill(Path(roundedRect: tick, cornerRadius: 0.75), with: .color(Theme.phosphor.opacity(0.35)))
    }
}

/// Pure bucketing for `DayTrace` (unit-tested): speaking seconds per 20-minute slot from the
/// window's start hour to midnight, normalised with a square root so one long dictation doesn't
/// flatten every short one.
struct DayTraceModel: Equatable {
    static let bucketMinutes = 20
    /// The waking day starts at 6 AM unless you spoke earlier.
    static let defaultStartHour = 6

    let startHour: Int
    /// 0…1 per bucket.
    let buckets: [Double]
    /// Index of the bucket containing `now`.
    let nowIndex: Int
    /// The newest bucket with speech — drawn lit (its afterglow). `nil` if nothing today.
    let latestActiveIndex: Int?
    let totalSeconds: Double

    init(spoken: [(at: Date, seconds: Double)], now: Date = Date(), calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: now)
        let today = spoken.filter { calendar.isDate($0.at, inSameDayAs: now) }
        let earliestHour = today.map { calendar.component(.hour, from: $0.at) }.min() ?? Self.defaultStartHour
        startHour = min(Self.defaultStartHour, earliestHour)
        let windowStart = dayStart.addingTimeInterval(TimeInterval(startHour * 3600))
        let slot = TimeInterval(Self.bucketMinutes * 60)
        let count = (24 - startHour) * 60 / Self.bucketMinutes

        var raw = Array(repeating: 0.0, count: count)
        for entry in today {
            let index = Int(entry.at.timeIntervalSince(windowStart) / slot)
            guard raw.indices.contains(index) else { continue }
            raw[index] += max(entry.seconds, 0)
        }
        let peak = raw.max() ?? 0
        buckets = raw.map { peak > 0 ? ($0 / peak).squareRoot() : 0 }
        nowIndex = min(max(Int(now.timeIntervalSince(windowStart) / slot), 0), max(count - 1, 0))
        latestActiveIndex = raw.indices.last { raw[$0] > 0 }
        totalSeconds = raw.reduce(0, +)
    }

    /// Hour marks shown under the trace, every three hours strictly inside the window (the
    /// edges are implied, and a centred label there would be clipped).
    var hourMarks: [Int] {
        stride(from: startHour + 3, to: 24, by: 3).map { $0 }
    }

    /// Horizontal position (0…1) of an hour boundary within the window.
    func fraction(ofHour hour: Int) -> CGFloat {
        CGFloat(hour - startHour) / CGFloat(24 - startHour)
    }

    var accessibilitySummary: String {
        guard totalSeconds > 0 else { return "Today's trace: nothing said yet today" }
        let minutes = max(1, Int((totalSeconds / 60).rounded()))
        return "Today's trace: about \(minutes) minute\(minutes == 1 ? "" : "s") of speaking today"
    }
}
