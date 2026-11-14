import Foundation

/// Which person a numbered speaker label ("Speaker 2") is, from how people talk to them: a turn
/// that addresses someone by name ("Ben, can you draft it?", "…by Friday, Ben?") is usually
/// answered by that person, and people introduce themselves ("I'm Luis from SchedulePro").
///
/// Used only to turn an action item's owner "Speaker 2" into "Ben" — the note's own speaker
/// labels are never renamed. Conservative: a label gets a name only with at least two votes, twice
/// as many as any other name, and no two labels share a name.
public enum SpeakerNameInference {
    static let minimumVotes = 2

    public static func names(in transcript: String) -> [String: String] {
        let (turns, words) = TranscriptChunker.parse(transcript)
        guard turns.contains(where: { isNumbered($0.speaker) }) else { return [:] }
        let labels = Set(turns.compactMap(\.speaker))
        let text = turns.map { turn in words[turn.range].map(\.text).joined(separator: " ") }
        var votes: [String: [String: Int]] = [:]
        for index in turns.indices {
            if let label = turns[index].speaker, isNumbered(label) {
                for name in introductions(in: text[index]) where !labels.contains(name) { votes[label, default: [:]][name, default: 0] += 1 }
            }
            guard index + 1 < turns.count, let next = turns[index + 1].speaker, isNumbered(next),
                  next != turns[index].speaker else { continue }
            for name in vocatives(in: text[index]) where !labels.contains(name) { votes[next, default: [:]][name, default: 0] += 1 }
        }
        return decide(votes)
    }

    static func decide(_ votes: [String: [String: Int]]) -> [String: String] {
        var names: [String: String] = [:]
        for (label, counts) in votes {
            let ranked = counts.sorted { $0.value > $1.value }
            guard let top = ranked.first, top.value >= minimumVotes,
                  ranked.count == 1 || top.value >= 2 * ranked[1].value else { continue }
            names[label] = top.key
        }
        let shared = Dictionary(grouping: names, by: \.value).filter { $0.value.count > 1 }.keys
        return names.filter { !shared.contains($0.value) }
    }

    static func isNumbered(_ label: String?) -> Bool {
        label?.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// "Ben, can you…" at the start of a sentence, "so, Ben, the…" inside one, or "…, Ben?" at
    /// its end.
    static func vocatives(in turn: String) -> [String] {
        let patterns = [#"(?:^|[.?!]\s+)([A-Z][a-z]{2,}),\s"#, #",\s([A-Z][a-z]{2,})(?:[?.!]|,\s)"#]
        return patterns.flatMap { pattern in
            Regex.matchesCaseSensitive(turn, pattern).compactMap { $0.string(at: 1, in: turn) }
        }.filter { !notNames.contains($0.lowercased()) }
    }

    /// "I'm Luis", "this is Anita", "my name is Omar".
    static func introductions(in turn: String) -> [String] {
        // Case-sensitive, so the name must be capitalised; the lead-in may be any case.
        Regex.matchesCaseSensitive(turn, #"\b(?i:I'm|I am|this is|my name is|it's)\s+([A-Z][a-z]{2,})\b"#)
            .compactMap { $0.string(at: 1, in: turn) }
            .filter { !notNames.contains($0.lowercased()) }
    }

    /// Capitalised words that start or end a clause but are not names.
    static let notNames: Set<String> = [
        "okay", "yes", "yeah", "yep", "nope", "right", "well", "also", "and", "but", "actually", "great", "sure",
        "thanks", "thank", "sorry", "hey", "alright", "honestly", "look", "now", "then", "fine", "cool", "wait",
        "anyway", "again", "sounds", "good", "true", "totally", "exactly", "perfect", "agreed", "absolutely", "hmm",
        "like", "basically", "because", "though", "too", "yet", "still", "maybe", "probably", "definitely", "please",
        "here", "there", "today", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "march", "april", "june", "july", "august", "september", "october",
        "november", "december", "everyone", "everybody", "guys", "folks", "team", "all", "one", "two", "the",
        "not", "just", "going", "happy", "glad", "back", "done", "fair", "noted", "interesting", "both", "either",
        "neither", "anyone", "someone", "nobody", "everything", "nothing", "something", "you", "we", "they",
        "same", "correct", "nice", "oh", "ah", "um", "uh", "so", "ok", "honest", "seriously", "really", "gotcha",
        "got", "makes", "love", "wow", "huh", "ooh", "anyways", "otherwise", "meanwhile", "plus", "hey",
    ]
}
