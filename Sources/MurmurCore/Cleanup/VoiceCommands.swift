import Foundation

/// Spoken editing commands: "scratch that", "new line", "new paragraph", "press enter".
///
/// Command phrases are matched conservatively: a spurious command can submit a chat message
/// or delete dictated speech, which costs far more than a missed command (one extra keystroke).
/// So every command here only fires as its own clause, and "press enter" additionally backs off
/// when the clause containing it is reporting, quoting or negating the phrase rather than
/// issuing it ("the instructions say press enter", "don't press enter yet").
enum VoiceCommands {
    struct PressEnter {
        let text: String
        let found: Bool
    }

    /// Cues earlier in the same clause that mean the command phrase is being talked about,
    /// not issued: reporting/quoting verbs, negation, or an explicit reference to the words.
    private static let literalContextCue =
        "(?:\\bsays?\\b|\\bsaid\\b|\\btype\\b|\\btyping\\b|\\bthe words?\\b|\\bcalled\\b|" +
        "\\bdon't\\b|\\bdo not\\b|\\bdoesn't\\b|\\bnever\\b|\\bnot\\b|\\bno\\b|\\binstructions?\\b|[\"'\u{201C}\u{2018}])"

    /// "press enter" only counts as a command when it is the whole utterance or the final
    /// phrase after a clause boundary, and the clause containing it carries no reporting,
    /// quoting or negation cue.
    static func extractPressEnter(_ text: String) -> PressEnter {
        let phrase = "(?:press|hit) (?:enter|return)"
        let pattern = "(?:^|[,;:]\\s*|\\s+)(\(phrase))[.!]?\\s*$"
        guard let match = Regex.firstMatch(text, pattern) else { return PressEnter(text: text, found: false) }

        let clauseStart = clauseBoundaryStart(of: match.range(at: 0).location, in: text)
        let clause = (text as NSString).substring(with: NSRange(location: clauseStart, length: match.range(at: 0).location - clauseStart))
        guard Regex.firstMatch(clause, literalContextCue) == nil else {
            return PressEnter(text: text, found: false)
        }
        // A closing quote right after the phrase also means it is being quoted, not issued.
        let tail = (text as NSString).substring(from: match.range.location + match.range.length)
        guard Regex.firstMatch(tail, "^\\s*[\"'\u{201D}\u{2019}]") == nil else {
            return PressEnter(text: text, found: false)
        }
        return PressEnter(text: Regex.replace(text, pattern, with: ""), found: true)
    }

    /// Finds the start of the clause containing `location`: the character after the nearest
    /// preceding clause-ending punctuation, or the start of the text.
    private static func clauseBoundaryStart(of location: Int, in text: String) -> Int {
        let ns = text as NSString
        var index = location - 1
        while index >= 0 {
            let char = ns.character(at: index)
            if let scalar = Unicode.Scalar(char), ",;:.!?".unicodeScalars.contains(scalar) {
                return index + 1
            }
            index -= 1
        }
        return 0
    }

    /// "scratch that" deletes what came before it in the same sentence, or the previous
    /// sentence when it starts a sentence. Only fires as a standalone clause: a clause
    /// boundary (or start/end of the sentence) on both sides, and not preceded by negation
    /// ("do not scratch that surface" stays literal) nor followed by more words in the same
    /// clause, which would make it a noun phrase ("scratch that itch").
    static func applyScratchThat(_ text: String) -> String {
        let verb = "(?:scratch|strike|delete) that"
        let negation = "(?:don't|do not|doesn't|does not|never|not|no)"
        // Standalone clause: start-of-sentence or a clause boundary before, and a clause
        // boundary, sentence end, or end-of-text right after (no trailing noun phrase).
        let cue = "(?:^|(?<=[,;:.!?]))\\s*\(verb)\\s*(?=[,;:.!?]|$)"
        guard Regex.firstMatch(text, cue) != nil else { return text }

        var kept: [String] = []
        for sentence in Sentences.split(text) {
            guard let match = Regex.firstMatch(sentence, "^(.*?)\(cue)[.,!]?\\s*(.*)$"),
                  let before = match.string(at: 1, in: sentence),
                  let after = match.string(at: 2, in: sentence)
            else {
                kept.append(sentence)
                continue
            }
            // Negation immediately before the verb ("please do not scratch that surface")
            // means this is literal, not a command.
            if Regex.firstMatch(before, "\\b\(negation)\\s*$") != nil {
                kept.append(sentence)
                continue
            }
            let trimmedBefore = Punctuation.stripTrailing(before)
            if trimmedBefore.isEmpty, !kept.isEmpty {
                kept.removeLast()
            }
            let remainder = after.trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty {
                // The remainder may itself contain another "scratch that".
                kept.append(applyScratchThat(remainder))
            }
        }
        return kept.joined(separator: " ")
    }

    /// "new line"/"new paragraph" only fire as a standalone clause: preceded by a clause
    /// boundary or the start, and followed by a clause boundary, sentence end, or end of
    /// text — never followed by more words ("new line of products", "new paragraph style").
    static func applyLineBreaks(_ text: String) -> String {
        var out = Regex.replace(
            text, "(?:[,;:]\\s*|\\s+|^)new paragraph\\b(?:[,.;:!?]\\s*|\\s*$)", with: "\n\n")
        out = Regex.replace(
            out, "(?:[,;:]\\s*|\\s+|^)(?:new line|next line)\\b(?:[,.;:!?]\\s*|\\s*$)", with: "\n")
        return out
    }
}

enum Sentences {
    /// Splits on sentence-ending punctuation, keeping the punctuation with its sentence.
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if ".!?".contains(char) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.filter { !$0.isEmpty }
    }
}

/// Removes hesitation words that carry no meaning.
///
/// Fillers are matched case-sensitively so a short filler spelling that is also a real acronym —
/// "ER", "IT", "AH" as a unit abbreviation, spoken names — is never eaten just because it happens
/// to share letters with "er"/"it"/"ah". A dictated acronym is almost always rendered upper case
/// by the recognizer; only lowercase or capitalized forms are hesitation sounds.
///
/// Capitalization: the recognizer capitalizes a hesitation after a pause even mid-sentence
/// ("…tool calls Uh what"), so the forms that are never a word — Um, Uh, Hmm and their spellings —
/// are removed capitalized anywhere. "Er", "Ah" and "Mm" can be names or abbreviations, so those
/// three are only removed capitalized at the start of a sentence, as before.
///
/// Never inside a hyphenated word ("uh-huh", "mm-hmm" mean yes and stay), and "mm" after a number
/// is millimetres ("a 5 mm screw"), not a hum.
enum Fillers {
    private static let pure = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm"]
    /// Hesitation spellings that are never an English word, a name or an abbreviation.
    private static let neverWords: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "hmm"]

    private static let alternatives: String = pure.map { filler -> String in
        let lower = Regex.escapeCaseSensitive(filler)
        let capitalized = Regex.escapeCaseSensitive(filler.prefix(1).uppercased() + filler.dropFirst())
        let lowerForm = filler == "mm" ? "(?<!\\d\\s)\(lower)" : lower
        if neverWords.contains(filler) { return "\(lowerForm)|\(capitalized)" }
        return "\(lowerForm)|(?<=^)\(capitalized)|(?<=[.!?\\n]\\s)\(capitalized)"
    }.joined(separator: "|")

    /// Word edges that also exclude hyphens and apostrophes, so "uh-huh" is one word.
    private static let start = "(?<![\\w'-])"
    private static let end = "(?![\\w'-])"

    static func remove(_ text: String) -> String {
        // Filler set off by commas: "we, uh, need" -> "we need"; a leading "Um, so" -> "so".
        var out = Regex.replaceCaseSensitive(text, ",\\s*\(start)(?:\(alternatives))\(end)\\s*,", with: "")
        out = Regex.replaceCaseSensitive(out, "\(start)(?:\(alternatives))\(end)[,.]?\\s*", with: "")
        // "like" / "you know" only when set off by commas on both sides.
        out = Regex.replace(out, ",\\s*(?:like|you know|I guess|kind of|sort of)\\s*,", with: ",")
        // Word and phrase stutters ("the the", "it's it's", "we should we should") are collapsed
        // by `StutterCollapse`, which knows the closed set of legitimate doublings
        // (`LegitDoubles`: "that that", "had had", "so so", "what it is is", …).
        return out
    }
}
