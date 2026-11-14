import Foundation

/// Scores the Insights typing test: net words per minute, where only correctly typed words
/// count (standard "net WPM"), so racing through with typos doesn't inflate the result.
public enum TypingTest {
    public static let passages = [
        "Thanks for sending the notes from yesterday. I read through them this morning and I think the plan looks good. Can we move the review to Thursday afternoon so the design team can join?",
        "The quarterly numbers came in a little higher than we expected. Let's keep the budget where it is for now and revisit it next month once the new hires have started.",
        "I'm running about ten minutes late because of traffic. Go ahead and start without me, and I'll catch up on anything I missed when I get there.",
    ]

    public struct Result: Equatable, Sendable {
        public let wordsPerMinute: Double
        public let accuracy: Double
    }

    /// `typed` compared word by word against `passage`; `seconds` is the time from first
    /// keystroke to finishing. Nil when there's too little to measure.
    public static func score(typed: String, passage: String, seconds: Double) -> Result? {
        let target = passage.split(whereSeparator: \.isWhitespace)
        let words = typed.split(whereSeparator: \.isWhitespace)
        guard seconds >= 5, words.count >= 5 else { return nil }
        let correct = zip(words, target).filter { $0 == $1 }.count
        return Result(wordsPerMinute: Double(correct) / (seconds / 60),
                      accuracy: Double(correct) / Double(words.count))
    }
}
