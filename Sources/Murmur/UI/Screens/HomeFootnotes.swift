import MurmurCore
import SwiftUI

/// The quiet band at the foot of Home: when you spoke today as a trace, the last seven days as
/// bars, and the two things a voice can also do here. Flat on the page, under a hairline: it is
/// reference, not the point of the screen.
struct HomeFootnotes: View {
    let dictations: [Dictation]
    let now: Date
    let calendar: Calendar
    /// The person's dictation key and voice-action key, as Settings has them.
    let triggerGlyph: String
    let actionKeyCap: String
    /// Words per day and the current streak, from Insights.
    let days: [Insights.DayCount]
    let currentStreak: Int
    /// Off while the app lock is on: the day's trace and the week are insights, hidden then.
    var showsActivity = true
    /// Off before the first dictation (the dictation card above offers the sentence itself) and
    /// while dictation cannot work.
    let showsTryIt: Bool

    /// Today's spoken moments for the trace: each dictation's speaking time at its time of day.
    private var traceModel: DayTraceModel {
        let spoken = dictations
            .filter { calendar.isDate($0.createdAt, inSameDayAs: now) && $0.status != .cancelled }
            .map { (at: $0.createdAt, seconds: max($0.durationSeconds, 1)) }
        return DayTraceModel(spoken: spoken)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            // "Today, as Hushy heard it" (ACTIONS-IA §3.1): the day's speech as a trace, the
            // same waveform mark as the pill and the logo at the scale of a day.
            if showsActivity {
                HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("When you spoke today")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        DayTrace(model: traceModel)
                    }
                    StreakMiniChart(days: days, currentStreak: currentStreak, now: now, calendar: calendar)
                        .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                voiceActionHint
                if showsTryIt { tryItHint }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    /// The chord's second job, under the first one (beta note, 2026-09-28).
    private var voiceActionHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Hold fn + control for an action, or tap")
            KeyCap(label: actionKeyCap)
            Text("twice to talk hands-free. Tap again to cancel.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold fn + control for an action, or tap \(actionKeyCap) twice to talk hands-free. Tap again to cancel.")
    }

    /// The sentence with a deliberate self-correction; what was said shows up in the dictation
    /// card above, as the last dictation.
    private var tryItHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Try it here. Double-tap")
            KeyCap(label: triggerGlyph)
            Text("and say: “\(HomeFeedCopy.tryItSentence)” Then press Enter to paste.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Try it here. Double-tap \(triggerGlyph) and say: \(HomeFeedCopy.tryItSentence) Then press Enter to paste.")
    }
}

/// Words per day for the last 7 days, today highlighted in phosphor — a compact version of Insights'
/// daily chart, sized for Home's foot.
struct StreakMiniChart: View {
    let days: [Insights.DayCount]
    /// Consecutive days dictated (today, or ending yesterday), from `Insights.streaks`.
    var currentStreak = 0
    /// The clock's now and calendar, so the highlighted bar moves to the new day at midnight.
    let now: Date
    let calendar: Calendar

    /// The chart is words per day, so it says so; a real streak is named only once there is
    /// one worth naming (two days or more).
    private var label: String {
        currentStreak >= 2 ? "Last 7 days · \(currentStreak)-day streak" : "Last 7 days"
    }

    var body: some View {
        let today = calendar.startOfDay(for: now)
        let counts = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.words) })
        let series = (0..<7).reversed().map { offset -> Int in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return counts[day] ?? 0
        }
        let maxWords = max(series.max() ?? 1, 1)
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(series.enumerated()), id: \.offset) { index, words in
                    Capsule()
                        .fill(index == series.count - 1 ? Theme.phosphor : Theme.textTertiary.opacity(0.35))
                        .frame(width: 6, height: max(4, 28 * CGFloat(words) / CGFloat(maxWords)))
                }
            }
            .frame(height: 28, alignment: .bottom)
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
