import Foundation
import Testing
@testable import MurmurCore

@Suite("TypingTest")
struct TypingTestTests {
    let passage = "one two three four five six seven eight nine ten"

    @Test("net wpm counts only correct words")
    func netWPM() throws {
        let result = try #require(TypingTest.score(typed: "one two three four five six seven eight nine ten", passage: passage, seconds: 15))
        #expect(result.wordsPerMinute == 40)
        #expect(result.accuracy == 1)
        let sloppy = try #require(TypingTest.score(typed: "one tow three four fiv six seven eight nine ten", passage: passage, seconds: 15))
        #expect(sloppy.wordsPerMinute == 32)
    }

    @Test("too short to measure returns nil")
    func tooShort() {
        #expect(TypingTest.score(typed: "one two", passage: passage, seconds: 3) == nil)
    }

    @Test("time saved uses the given typing speed")
    func savedUsesSpeed() {
        var insights = Insights.empty
        insights = Insights(totalWords: 600, totalDictations: 1, averageWPM: 150, fixes: 0, currentStreak: 0,
                            longestStreak: 0, minutesSaved: 0, days: [], categories: [], appsUsed: 0,
                            speakingSeconds: 240)
        #expect(insights.minutesSaved(typingWPM: 40) == 11)
        #expect(insights.minutesSaved(typingWPM: 100) == 2)
    }
}

@Suite("ExtractiveSummarizer short notes")
struct ShortNoteSummaryTests {
    @Test("a short note gets no echo summary and is titled by its opening words")
    func shortNote() {
        let out = ExtractiveSummarizer.summarize("Hey, is it actually recording?", fallbackTitle: "Note · Sep 25")
        #expect(out.summary.isEmpty)
        #expect(out.title == "Hey, is it actually recording")
    }

    @Test("long openings are cut with an ellipsis")
    func longOpening() {
        let out = ExtractiveSummarizer.summarize("Remind me to send the deck to Dana before Friday.", fallbackTitle: "Note")
        #expect(out.title == "Remind me to send the deck…")
        #expect(out.actionItems.count == 1)
    }
}

@Suite("Insights saved time")
struct InsightsSavedTimeTests {
    private func dictation(words: Int, seconds: Double, at date: Date, status: Dictation.Status = .inserted) -> Dictation {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        return Dictation(createdAt: date, rawText: text, text: text, durationSeconds: seconds, fixes: 0, status: status)
    }

    @Test("seconds saved is typing time minus speaking time, never negative")
    func secondsSaved() {
        // 40 words at 40 wpm = 60 s of typing; spoken in 20 s → 40 s saved.
        #expect(Insights.secondsSaved(words: 40, speakingSeconds: 20, typingWPM: 40) == 40)
        // Slower than typing saves nothing rather than going negative.
        #expect(Insights.secondsSaved(words: 10, speakingSeconds: 120, typingWPM: 40) == 0)
        #expect(Insights.secondsSaved(words: 0, speakingSeconds: 0, typingWPM: 40) == 0)
        #expect(Insights.secondsSaved(words: 100, speakingSeconds: 10, typingWPM: 0) == 0)
    }

    @Test("lifetime minutes saved uses the same formula as the per-day figure")
    func lifetimeMatchesFormula() {
        let insights = Insights(totalWords: 600, totalDictations: 1, averageWPM: 150, fixes: 0, currentStreak: 0,
                                longestStreak: 0, minutesSaved: 0, days: [], categories: [], appsUsed: 0,
                                speakingSeconds: 240)
        let seconds = Insights.secondsSaved(words: 600, speakingSeconds: 240, typingWPM: 40)
        #expect(insights.minutesSaved(typingWPM: 40) == Int((seconds / 60).rounded()))
    }

    @Test("today's totals count only today's successful dictations")
    func todayTotals() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: Calendar.Component.day, value: -1, to: now)!
        let dictations = [
            dictation(words: 30, seconds: 10, at: now),
            dictation(words: 20, seconds: 5, at: now.addingTimeInterval(-60)),
            dictation(words: 99, seconds: 30, at: now, status: Dictation.Status.failed),
            dictation(words: 99, seconds: 30, at: now, status: Dictation.Status.cancelled),
            dictation(words: 500, seconds: 100, at: yesterday),
        ]
        let totals = Insights.todayTotals(from: dictations, now: now, calendar: calendar)
        #expect(totals.words == 50)
        #expect(totals.speakingSeconds == 15)
    }

    @Test("saved-time value never reads 0 min")
    func savedTimeValue() {
        #expect(Insights.savedTimeValue(seconds: 0) == "—")
        #expect(Insights.savedTimeValue(seconds: 0.4) == "—")
        #expect(Insights.savedTimeValue(seconds: 42) == "42 s")
        #expect(Insights.savedTimeValue(seconds: 59.6) == "1 min")
        #expect(Insights.savedTimeValue(seconds: 600) == "10 min")
        #expect(Insights.savedTimeValue(seconds: 3_600) == "1 h")
        #expect(Insights.savedTimeValue(seconds: 5_400) == "1.5 h")
    }
}
