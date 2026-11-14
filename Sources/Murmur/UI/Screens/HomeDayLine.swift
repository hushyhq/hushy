import MurmurCore
import SwiftUI

/// The quiet line above Home's dictation card: the greeting, with the name in the phosphor
/// accent, and the date. It used to be the page's headline (a card with the greeting in the
/// section serif and three large stats); the headline is now whether dictation is ready
/// (`HomeDictationHero`), and the greeting steps back to one line.
struct HomeDayLine: View {
    /// The person's name from Settings; empty until they set one.
    let name: String
    let now: Date
    let calendar: Calendar

    private var greeting: String {
        let hour = calendar.component(.hour, from: now)
        let time = hour < 12 ? "morning" : (hour < 17 ? "afternoon" : "evening")
        return "Good \(time),"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            (Text("\(greeting) ") + Text(name.isEmpty ? "there" : name).italic().foregroundStyle(Theme.phosphor) + Text("."))
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(now.formatted(date: .complete, time: .omitted))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }
}

/// Today's two numbers as one short line for the Today header ("142 words · 3 min saved"),
/// counted the way Insights counts them. Pure (`HomeLastDictationTests`).
struct HomeTodayNumbers: Equatable {
    let words: Int
    /// Time saved *today* against typing, so it sits honestly next to today's words (the
    /// lifetime figure lives in Insights, labelled as a total).
    let savedSeconds: Double

    static func make(dictations: [Dictation], now: Date, calendar: Calendar, typingWPM: Double) -> HomeTodayNumbers {
        let totals = Insights.todayTotals(from: dictations, now: now, calendar: calendar)
        let saved = Insights.secondsSaved(words: totals.words, speakingSeconds: totals.speakingSeconds, typingWPM: typingWPM)
        return HomeTodayNumbers(words: totals.words, savedSeconds: saved)
    }

    /// Nil before the first word of the day; the saved time joins once there is a second of it.
    var line: String? {
        guard words > 0 else { return nil }
        let counted = "\(words.formatted()) word\(words == 1 ? "" : "s")"
        return savedSeconds >= 1 ? "\(counted) · \(Insights.savedTimeValue(seconds: savedSeconds)) saved" : counted
    }

    /// The tooltip that says what "saved" is measured against.
    func help(measuredTypingWPM: Int?) -> String {
        let speed = measuredTypingWPM.map { "your typing speed of \($0) wpm" }
            ?? "typing at an average 40 wpm. Measure your own speed in Insights"
        return "Time you'd have spent typing today's \(words) words, compared with \(speed). Minus the time you spent talking."
    }
}
