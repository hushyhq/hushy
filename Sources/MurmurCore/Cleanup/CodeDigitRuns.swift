import Foundation

/// Digits read out one after another in a code line are one number: "eight zero eight zero" is `8080`,
/// "one two zero" is `120`. Ports, ids and sizes are spoken this way, and a code line has no use for
/// the words.
///
/// Evidence for the number: three or more single-digit words in a row, each a bare word (no comma or
/// full stop between them), that are not a plain count. "one two three" and "five four three two one"
/// step by one in one direction, which is how people count, so they stay words. Comment lines are
/// prose and are skipped, as are runs of two ("one two"), which are as likely to be a pair of choices.
enum CodeDigitRuns {
    private static let minimumRun = 3

    static func apply(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            CodeComments.startsWithDelimiter(line) ? line : convert(line)
        }.joined(separator: "\n")
    }

    private static func convert(_ line: String) -> String {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            var end = index
            while end < tokens.count, CodeSymbolWords.digitWords[tokens[end].lowercased()] != nil { end += 1 }
            let words = tokens[index..<end].map { $0.lowercased() }
            if words.count >= minimumRun, !isCount(words) {
                out.append(words.compactMap { CodeSymbolWords.digitWords[$0] }.joined())
                index = end
            } else {
                out.append(tokens[index])
                index += 1
            }
        }
        return out.joined(separator: " ")
    }

    /// Steps of exactly +1 or exactly -1 all the way: a count, not a digit string.
    private static func isCount(_ words: [String]) -> Bool {
        let values = words.compactMap { CodeSymbolWords.digitWords[$0].flatMap(Int.init) }
        let steps = zip(values, values.dropFirst()).map { $1 - $0 }
        return Set(steps) == [1] || Set(steps) == [-1]
    }
}
