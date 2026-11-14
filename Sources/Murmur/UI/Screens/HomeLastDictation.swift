import Foundation
import MurmurCore

/// What Home's dictation card shows as the last dictation: the words (or, when there are none,
/// the one sentence that says what happened), where and when it was said, and what can be
/// copied. Pure, so a test reads every case (`HomeLastDictationTests`); the sentences for a
/// dictation with no words are the timeline row's own (`TimelineEntryRow`).
struct HomeLastDictation: Equatable {
    let id: Int64?
    let text: String
    /// Nil when there are no words to copy (a failed transcription, Return on its own).
    let copyText: String?
    /// "Today, 3:12 PM", "Yesterday, 5:40 PM", "Mon, Oct 5, 9:02 AM".
    let whenLabel: String
    let appName: String?
    /// A quiet line under the words when they need explaining.
    let note: String?
    /// Longer than the card shows at rest; the card folds it behind "Show all".
    let isLong: Bool

    var hasWords: Bool { copyText != nil }

    static let notTypedNote = "This one was not typed into an app. Copy it from here."
    static let asHeardNote = "Hushy could not prepare this one, so these are the words as heard."

    /// Past this many characters or lines, the card folds the text (`collapsedLineLimit` lines of
    /// the card's type at its narrowest width hold about this much).
    static let longCharacterCount = 420
    static let longLineCount = 6
    static let collapsedLineLimit = 6

    /// The newest dictation the person did not cancel, whatever order `dictations` is in.
    static func pick(from dictations: [Dictation]) -> Dictation? {
        dictations.filter { $0.status != .cancelled }.max { $0.createdAt < $1.createdAt }
    }

    static func make(_ dictation: Dictation, now: Date, calendar: Calendar) -> HomeLastDictation {
        let words = wording(for: dictation)
        let day = HistoryScrubberModel.dayLabel(for: dictation.createdAt, calendar: calendar, now: now)
        let time = dictation.createdAt.formatted(date: .omitted, time: .shortened)
        let lines = words.text.split(separator: "\n", omittingEmptySubsequences: false).count
        return HomeLastDictation(
            id: dictation.id, text: words.text, copyText: words.copyText, whenLabel: "\(day), \(time)",
            appName: dictation.appName, note: words.note,
            isLong: words.text.count > longCharacterCount || lines > longLineCount)
    }

    private static func wording(for item: Dictation) -> (text: String, copyText: String?, note: String?) {
        if !item.text.isEmpty {
            return (item.text, item.text, item.status == .inserted ? nil : notTypedNote)
        }
        if item.status == .failed {
            if !item.rawText.isEmpty { return (item.rawText, item.rawText, asHeardNote) }
            let sentence = item.audioPath == nil
                ? "Transcription failed. No audio was retained." : "Transcription failed. The audio was saved."
            return (sentence, nil, nil)
        }
        if item.status == .inserted { return ("Pressed Return (no text to type)", nil, nil) }
        return item.rawText.isEmpty ? ("No words were kept for this one.", nil, nil) : (item.rawText, item.rawText, notTypedNote)
    }
}

/// What the dictation card's lower band holds. Locked comes first and carries nothing: while the
/// app lock is on (Settings → Privacy & security), Home shows and copies no dictated words, the
/// same promise History, Notes and Insights keep behind `LockGate`. Pure (`HomeLastDictationTests`).
enum HomeCardContent: Equatable {
    /// The app lock is on: no words, an Unlock button.
    case locked
    case last(HomeLastDictation)
    /// Nothing dictated yet and dictation can work: the sentence to try.
    case tryIt
    /// Nothing dictated yet and dictation cannot work yet.
    case waiting

    static func make(isLocked: Bool, dictations: [Dictation], isReady: Bool, now: Date, calendar: Calendar) -> HomeCardContent {
        if isLocked { return .locked }
        if let newest = HomeLastDictation.pick(from: dictations) {
            return .last(HomeLastDictation.make(newest, now: now, calendar: calendar))
        }
        return isReady ? .tryIt : .waiting
    }

    var last: HomeLastDictation? {
        if case .last(let last) = self { return last }
        return nil
    }
}
