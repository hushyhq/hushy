import Foundation

/// Code checks that keep a digest's facts tied to the transcript: an owner must be someone in the
/// meeting (a speaker label, "You", or a name said in the transcript), and a due date's day, month
/// or number must have been said. A check that fails empties the field (the item is unassigned or
/// undated) rather than dropping the item. People's top complaint about meeting notes is invented
/// or misassigned action items; an empty owner is honest, a guessed one is not.
enum DigestGrounding {
    /// The transcript's words and speaker labels, read once per summary.
    struct Source {
        let words: Set<String>
        let labels: Set<String>

        init(_ transcript: String) {
            words = Set(DigestGrounding.tokens(transcript))
            var labels: Set<String> = ["you"]
            for line in transcript.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 40 else { continue }
                labels.insert(line[..<colon].trimmingCharacters(in: .whitespaces).lowercased())
            }
            self.labels = labels
        }
    }

    static func grounded(_ item: DigestActionItem, in source: Source) -> DigestActionItem {
        var item = item
        if !isGroundedOwner(item.owner, in: source) { item.owner = "" }
        if !isGroundedDue(item.due, in: source) { item.due = "" }
        return item
    }

    static func isGroundedOwner(_ owner: String, in source: Source) -> Bool {
        let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || source.labels.contains(trimmed) { return true }
        let words = tokens(trimmed).filter { !ownerFiller.contains($0) }
        return !words.isEmpty && words.allSatisfy(source.words.contains)
    }

    /// True when every day, month, date number or relative day in `due` was said.
    static func isGroundedDue(_ due: String, in source: Source) -> Bool {
        tokens(due).allSatisfy { token in
            if calendarWords.contains(token) { return source.words.contains(token) }
            guard let number = Int(token.trimmingCharacters(in: .letters)) else { return true }
            return source.words.contains(String(number)) || numberWords[number].map(source.words.contains) == true
                || ordinalWords[number].map(source.words.contains) == true
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static let ownerFiller: Set<String> = ["and", "the", "team", "group", "everyone", "all", "both", "of", "or"]

    private static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
        "april", "june", "july", "august", "september", "october", "november", "december", "tomorrow", "tonight", "today",
    ]

    private static let numberWords: [Int: String] = [
        1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten",
        11: "eleven", 12: "twelve", 13: "thirteen", 14: "fourteen", 15: "fifteen", 20: "twenty", 30: "thirty",
    ]

    private static let ordinalWords: [Int: String] = [
        1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", 6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth",
        10: "tenth", 11: "eleventh", 12: "twelfth", 13: "thirteenth", 14: "fourteenth", 15: "fifteenth", 16: "sixteenth",
        17: "seventeenth", 18: "eighteenth", 19: "nineteenth", 20: "twentieth", 30: "thirtieth",
    ]
}
