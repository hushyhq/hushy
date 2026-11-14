import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Home's "Last dictation": which one is shown, what can be copied, and what is said when the
/// newest one has no words. Invented text only.
@Suite("Home last dictation")
struct HomeLastDictationTests {
    private let calendar = Calendar.current
    /// Noon, so "26 hours ago" is yesterday in every time zone.
    private var now: Date {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
    }

    private func dictation(
        _ id: Int64, minutesAgo: Double, text: String = "Moving the review to Thursday.", raw: String? = nil,
        status: Dictation.Status = .inserted, audioPath: String? = nil, app: String? = "Mail"
    ) -> Dictation {
        Dictation(
            id: id, createdAt: now.addingTimeInterval(-minutesAgo * 60), rawText: raw ?? text.lowercased(), text: text,
            appBundleID: nil, appName: app, durationSeconds: 3, status: status, audioPath: audioPath)
    }

    @Test("the newest dictation is picked whatever order the list is in, and a cancelled one never is")
    func pick() {
        let older = dictation(1, minutesAgo: 30)
        let newest = dictation(2, minutesAgo: 2)
        let cancelled = dictation(3, minutesAgo: 1, status: .cancelled)
        #expect(HomeLastDictation.pick(from: [older, cancelled, newest])?.id == 2)
        #expect(HomeLastDictation.pick(from: [cancelled]) == nil)
        #expect(HomeLastDictation.pick(from: []) == nil)
    }

    @Test("a typed dictation shows its words, where it went and when, and can be copied")
    func typed() {
        let last = HomeLastDictation.make(dictation(7, minutesAgo: 5), now: now, calendar: calendar)
        #expect(last.id == 7)
        #expect(last.text == "Moving the review to Thursday.")
        #expect(last.copyText == "Moving the review to Thursday.")
        #expect(last.hasWords)
        #expect(last.note == nil)
        #expect(last.whenLabel.hasPrefix("Today, "))
        #expect(last.appName == "Mail")
        #expect(!last.isLong)
    }

    @Test("one that was not typed into an app says so, and can still be copied")
    func notTyped() {
        let last = HomeLastDictation.make(dictation(8, minutesAgo: 5, status: .notInserted), now: now, calendar: calendar)
        #expect(last.copyText == "Moving the review to Thursday.")
        #expect(last.note == HomeLastDictation.notTypedNote)
    }

    @Test("a failed one with no words says what happened and offers nothing to copy")
    func failedWithoutWords() {
        let kept = HomeLastDictation.make(
            dictation(9, minutesAgo: 5, text: "", raw: "", status: .failed, audioPath: "/tmp/invented.wav"), now: now, calendar: calendar)
        #expect(kept.text == "Transcription failed. The audio was saved.")
        #expect(kept.copyText == nil)
        #expect(!kept.hasWords)

        let gone = HomeLastDictation.make(dictation(10, minutesAgo: 5, text: "", raw: "", status: .failed), now: now, calendar: calendar)
        #expect(gone.text == "Transcription failed. No audio was retained.")
    }

    @Test("when only the words as heard exist, they are shown and can be copied, and the card says so")
    func asHeardOnly() {
        let last = HomeLastDictation.make(
            dictation(11, minutesAgo: 5, text: "", raw: "moving the review to thursday", status: .failed), now: now, calendar: calendar)
        #expect(last.text == "moving the review to thursday")
        #expect(last.copyText == "moving the review to thursday")
        #expect(last.note == HomeLastDictation.asHeardNote)
    }

    @Test("Return with nothing to type has no words to copy")
    func returnOnly() {
        let last = HomeLastDictation.make(dictation(12, minutesAgo: 5, text: "", raw: ""), now: now, calendar: calendar)
        #expect(last.text == "Pressed Return (no text to type)")
        #expect(last.copyText == nil)
    }

    @Test("an earlier day is named")
    func earlierDay() {
        let yesterday = HomeLastDictation.make(dictation(13, minutesAgo: 26 * 60), now: now, calendar: calendar)
        #expect(yesterday.whenLabel.hasPrefix("Yesterday, "))
    }

    @Test("a long dictation is folded; a short one is not")
    func long() {
        let sentence = "We agreed to move the planning review to Thursday afternoon so everyone can read the draft first. "
        let long = HomeLastDictation.make(
            dictation(14, minutesAgo: 5, text: String(repeating: sentence, count: 8)), now: now, calendar: calendar)
        #expect(long.isLong)
        let manyLines = HomeLastDictation.make(
            dictation(15, minutesAgo: 5, text: Array(repeating: "A short line.", count: 9).joined(separator: "\n")), now: now, calendar: calendar)
        #expect(manyLines.isLong)
        #expect(!HomeLastDictation.make(dictation(16, minutesAgo: 5, text: sentence), now: now, calendar: calendar).isLong)
    }

    // MARK: App lock

    @Test("while the app lock is on, the card holds no dictated words to show or copy, whatever was dictated")
    func lockedCardHasNoWords() {
        let said = [dictation(1, minutesAgo: 2), dictation(2, minutesAgo: 30, status: .notInserted)]
        for isReady in [true, false] {
            let content = HomeCardContent.make(isLocked: true, dictations: said, isReady: isReady, now: now, calendar: calendar)
            #expect(content == .locked)
            #expect(content.last == nil)
        }
        #expect(HomeCardContent.make(isLocked: true, dictations: [], isReady: true, now: now, calendar: calendar) == .locked,
                "locked says locked, not Try it now, so it never tells whether anything was dictated")
    }

    @Test("unlocked, the card shows the last dictation, or invites a try only when dictation can work")
    func unlockedCard() {
        let said = [dictation(1, minutesAgo: 2)]
        let shown = HomeCardContent.make(isLocked: false, dictations: said, isReady: false, now: now, calendar: calendar)
        #expect(shown.last?.id == 1)
        #expect(HomeCardContent.make(isLocked: false, dictations: [], isReady: true, now: now, calendar: calendar) == .tryIt)
        #expect(HomeCardContent.make(isLocked: false, dictations: [], isReady: false, now: now, calendar: calendar) == .waiting)
    }

    @Test("the locked words say what is hidden and that dictation still works")
    func lockedCopy() {
        #expect(HomeFeedCopy.lockedMessage == "Your dictations are hidden while Hushy is locked. Dictation still works.")
        #expect(HomeFeedCopy.lockedTodayMessage == "Today's dictations are hidden while Hushy is locked.")
        #expect(HomeFeedCopy.unlockTitle == "Unlock")
    }

    // MARK: Today's numbers

    @Test("today's line counts words and time saved, and is absent before the first word")
    func todayNumbers() {
        #expect(HomeTodayNumbers(words: 0, savedSeconds: 0).line == nil)
        #expect(HomeTodayNumbers(words: 1, savedSeconds: 0).line == "1 word")
        #expect(HomeTodayNumbers(words: 142, savedSeconds: 180).line == "142 words · 3 min saved")
    }

    @Test("today's numbers come from today's typed dictations only")
    func todayNumbersFromDictations() {
        let today = dictation(1, minutesAgo: 10, text: "one two three four")
        let yesterday = dictation(2, minutesAgo: 26 * 60, text: "five six")
        let cancelled = dictation(3, minutesAgo: 5, text: "seven", status: .cancelled)
        let numbers = HomeTodayNumbers.make(dictations: [today, yesterday, cancelled], now: now, calendar: calendar, typingWPM: 40)
        #expect(numbers.words == 4)
        #expect(numbers.savedSeconds == 3, "four words at 40 wpm is 6 s of typing, minus 3 s of talking")
    }

    @Test("the saved-time tooltip names the speed it compares against")
    func todayHelp() {
        let numbers = HomeTodayNumbers(words: 12, savedSeconds: 9)
        #expect(numbers.help(measuredTypingWPM: 62).contains("your typing speed of 62 wpm"))
        #expect(numbers.help(measuredTypingWPM: nil).contains("average 40 wpm"))
    }
}
