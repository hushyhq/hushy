import Charts
import MurmurCore
import SwiftUI

/// Mockup layout: three headline stat cards, a words-per-day bar chart, "Where you talk" and
/// "Speed" side by side. Everything is computed on this Mac.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var showTypingTest = false

    private var typingFootnote: String {
        guard let wpm = model.settings.typingWPM else { return "Since you started · assuming an average typist (40 wpm)" }
        return "Since you started · at your typing speed of \(Int(wpm)) wpm"
    }

    /// Lifetime time saved, "—" until there is a real figure (never "0 min").
    private var savedValue: String {
        let insights = model.library.insights
        let seconds = Insights.secondsSaved(
            words: insights.totalWords, speakingSeconds: insights.speakingSeconds,
            typingWPM: model.settings.effectiveTypingWPM)
        return Insights.savedTimeValue(seconds: seconds)
    }

    /// Below this many measured dictations, a percentage reads as more precise than it is.
    static let minMeasuredForRate = 10
    /// Below this many active days, a 30-day chart and heatmap are mostly empty cells.
    static let minActiveDaysForCharts = 7

    var body: some View {
        let insights = model.library.insights
        let activeDays = insights.days.filter { $0.words > 0 }.count
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Your voice, ").font(Theme.Font.section).foregroundStyle(Theme.textPrimary)
                    + Text("by the numbers").font(Theme.Font.section).italic().foregroundStyle(Theme.phosphor)
                Text("Computed on this Mac from your history. Your history is never uploaded.")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }

            InsightsStatRow(
                wordsValue: insights.totalWords.formatted(), savedValue: savedValue, savedFootnote: typingFootnote,
                measureTitle: model.settings.typingWPM == nil ? "Measure yours" : "Measure again",
                measure: { showTypingTest = true }
            ) { KeptStatCard(insights: insights) }

            if let line = insights.keptThisWeekLine { KeptThisWeekLine(text: line, measured: insights.weekEditsMeasured) }

            if activeDays >= Self.minActiveDaysForCharts {
                DailyChart(days: insights.days)
            } else {
                UnlockStrip(activeDays: activeDays)
            }

            HStack(alignment: .top, spacing: Theme.Space.l) {
                AppsCard(insights: insights)
                SpeedCard(wpm: insights.averageWPM)
            }
            .frame(height: 230)
        }
        .screen()
        .sheet(isPresented: $showTypingTest) { TypingTestSheet() }
    }
}

/// The three headline cards. The typing-test link sits inside the middle card, under its
/// footnote, in the card's own flow: a link floated over a corner collided with the figure once
/// the value was long or the window narrow. The cards share the row's height.
struct InsightsStatRow<Kept: View>: View {
    let wordsValue: String
    let savedValue: String
    let savedFootnote: String
    let measureTitle: String
    let measure: () -> Void
    @ViewBuilder let kept: () -> Kept

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            StatCard(value: wordsValue, label: "words dictated", footnote: "Since you started using Hushy")
            StatCard(value: savedValue, label: "saved vs typing, in total", footnote: savedFootnote) {
                LinkLikeButton(title: measureTitle, action: measure)
                    .help("A 30-second typing test, so time saved uses your real speed")
            }
            kept()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One headline stat card, matching the mockup's three flat cards (in place of the old
/// dark-banner numbers). `accessory` is an optional control on its own line under the footnote.
struct StatCard<Accessory: View>: View {
    let value: String
    let label: String
    var footnote: String?
    @ViewBuilder var accessory: () -> Accessory

    init(value: String, label: String, footnote: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.value = value
        self.label = label
        self.footnote = footnote
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 30, weight: .light, design: .serif).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
                // A long figure shrinks a little rather than wrapping or running into its card edge.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            if let footnote {
                Text(footnote).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            accessory().padding(.top, 2)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

extension StatCard where Accessory == EmptyView {
    init(value: String, label: String, footnote: String? = nil) {
        self.init(value: value, label: label, footnote: footnote) { EmptyView() }
    }
}

/// The "used without edits" stat card: a soft, sample-sized fraction until there's enough
/// measured data for a percentage to mean anything.
private struct KeptStatCard: View {
    let insights: Insights

    var body: some View {
        if insights.editsMeasured == 0 {
            StatCard(value: "—", label: "used without edits", footnote: "Measuring — check back soon")
        } else if insights.editsMeasured < InsightsView.minMeasuredForRate {
            let kept = Int(((insights.editFreeRate ?? 0) * Double(insights.editsMeasured)).rounded())
            StatCard(
                value: "\(kept) of \(insights.editsMeasured)",
                label: "checked kept as typed",
                footnote: "Only measured dictations count — a percentage shows after \(InsightsView.minMeasuredForRate).")
        } else {
            StatCard(
                value: "\(Int(((insights.editFreeRate ?? 0) * 100).rounded()))%",
                label: "used without edits",
                footnote: "\(insights.editsMeasured) of \(insights.totalDictations) used without edits · only measured dictations count")
        }
    }
}

/// The person's own edit number for the week, in one calm line. Private to this Mac: it is computed from the
/// history here, and the line says so.
private struct KeptThisWeekLine: View {
    let text: String
    let measured: Int

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "checkmark.seal").foregroundStyle(Theme.phosphor).accessibilityHidden(true)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text("Based on \(measured) dictations from the last 7 days that Hushy could check. Only on this Mac.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Before a week of use, the daily chart and activity map would be mostly empty grids;
/// one slim strip says when they arrive instead.
private struct UnlockStrip: View {
    let activeDays: Int

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Day \(min(activeDays, InsightsView.minActiveDaysForCharts)) of \(InsightsView.minActiveDaysForCharts)")
                .font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                .fixedSize()
            HStack(spacing: 4) {
                ForEach(0..<InsightsView.minActiveDaysForCharts, id: \.self) { day in
                    Capsule()
                        .fill(day < activeDays ? Theme.phosphorFill : Theme.textTertiary.opacity(0.25))
                        .frame(width: 14, height: 4)
                }
            }
            .accessibilityHidden(true)
            Text("Dictate on \(max(InsightsView.minActiveDaysForCharts - activeDays, 0)) more days to unlock your daily chart and activity map.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }
}

private struct InsightCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(title)
            content
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

private struct SpeedCard: View {
    @Environment(AppModel.self) private var model
    let wpm: Int

    var body: some View {
        InsightCard(title: "Speaking speed") {
            ZStack(alignment: .bottom) {
                Gauge(fraction: min(Double(wpm) / 200, 1))
                    .frame(width: 180, height: 96)
                VStack(spacing: 0) {
                    Text("\(wpm)").font(.system(size: 40, weight: .light, design: .serif).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("wpm").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.s)
            Spacer(minLength: 0)
            Text(wpm > 0 ? String(format: "%.1f× faster than typing", Double(wpm) / model.settings.effectiveTypingWPM) : "Dictate to see your speed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.phosphor)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct Gauge: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Arc(fraction: 1).stroke(Theme.bgSunken, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            Arc(fraction: fraction)
                .stroke(Theme.phosphor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .animation(Theme.settle, value: fraction)
        }
    }

    struct Arc: Shape {
        var fraction: Double
        var animatableData: Double {
            get { fraction }
            set { fraction = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: min(rect.width / 2, rect.height) - 6,
                        startAngle: .degrees(180), endAngle: .degrees(180 + 180 * max(fraction, 0.001)), clockwise: false)
            return path
        }
    }
}

/// Words per day for the last 30 days.
private struct DailyChart: View {
    @Environment(AppModel.self) private var model
    let days: [Insights.DayCount]

    private struct Point: Identifiable {
        let day: Date
        let words: Int
        var id: Date { day }
    }

    var body: some View {
        let calendar = model.dayClock.calendar
        let today = calendar.startOfDay(for: model.dayClock.now)
        let counts = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.words) })
        let series = (0..<30).reversed().map { offset -> Point in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return Point(day: day, words: counts[day] ?? 0)
        }
        InsightCard(title: "Words per day · last 30 days") {
            Chart(series) { point in
                BarMark(x: .value("Day", point.day, unit: .day), y: .value("Words", point.words))
                    .foregroundStyle(point.day == today ? Theme.phosphor : Theme.phosphor.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
        }
    }
}

private struct AppsCard: View {
    let insights: Insights

    var body: some View {
        InsightCard(title: "Where you talk") {
            if insights.topApps.isEmpty {
                // A centred empty state, not one stray sentence in a tall card.
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "app.dashed").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.textTertiary)
                    Text("Your top apps appear here").font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
                    Text("Dictate into Mail, Slack or anywhere else a few times.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: Theme.Space.m) {
                ForEach(insights.topApps, id: \.bundleID) { app in
                    HStack(spacing: Theme.Space.m) {
                        AppIcon(bundleID: app.bundleID).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(app.name).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(app.words.formatted()) words").font(Theme.Font.data).foregroundStyle(Theme.textSecondary)
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.bgSunken)
                                    Capsule().fill(Theme.phosphor.opacity(0.4 + 0.6 * app.fraction))
                                        .frame(width: max(geometry.size.width * app.fraction, 4))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
    }
}

