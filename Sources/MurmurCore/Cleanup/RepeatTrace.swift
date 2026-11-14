import Foundation

/// Counts that say which stage of a dictation wrote a repeated ending ("lordcom.com.com.com."), for the app's log.
///
/// A line made from this carries a fixed stage name and numbers: the word count of the text before and after the
/// stage and the longest run of one word said back to back (words are the pieces between punctuation, so
/// "lord.com.com.com" has a run of 2 on "com"). It never carries the text, so it is safe in a log.
public struct RepeatTrace: Sendable, Equatable {
    /// Words in the text, the pieces between anything that is not a letter or a digit.
    public let tokens: Int
    /// The most times one word comes in a row, ignoring case (1 when no word is repeated, 0 for no words).
    public let longestRun: Int

    public init(_ text: String) {
        var count = 0
        var best = 0
        var run = 0
        var previous: Substring?
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            count += 1
            run = token == previous ? run + 1 : 1
            previous = token
            best = max(best, run)
        }
        tokens = count
        longestRun = best
    }

    /// A word said this many times in a row is rare enough in speech that a recogniser writing it is worth a line of its own.
    public static let recogniserRun = 3

    /// The stage made a word repeat further than its input did.
    public static func added(from input: RepeatTrace, to output: RepeatTrace) -> Bool {
        output.longestRun >= 2 && output.longestRun > input.longestRun
    }

    /// The text as it came from the recogniser already repeats a word `recogniserRun` times or more.
    public var isLoopedRecogniserText: Bool { longestRun >= Self.recogniserRun }

    /// The log line: stage, then counts only. `stage` must be a fixed name, never text from the dictation.
    public static func line(stage: StaticString, from input: RepeatTrace, to output: RepeatTrace) -> String {
        "repeat_added stage=\(stage) words=\(input.tokens)->\(output.tokens) longest_run=\(input.longestRun)->\(output.longestRun)"
    }

    /// Same, for text that was already repeated when this stage first saw it.
    public static func looped(stage: StaticString, _ trace: RepeatTrace) -> String {
        "repeat_in_input stage=\(stage) words=\(trace.tokens) longest_run=\(trace.longestRun)"
    }
}
