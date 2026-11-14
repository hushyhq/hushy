import Foundation

/// Guards a transform mode's model answer before it is allowed to replace the cleaned text.
///
/// Transform modes (Email/Message/Note/Bullet points, and any custom mode with a prompt) are
/// explicitly allowed to add structural words a plain cleanup pass never would (greetings,
/// sign-offs, bullet markers, "Hi," / "Best,") — so they skip `SmartCleaner`'s word-preservation
/// check (`OutputGuard`'s word-overlap bounds are tuned for a formatting-neutral rewrite, not a
/// reformat). What they must never do is invent a fact or drop one, or comply with an
/// instruction smuggled inside the dictated text. `ModeGuards.check` is the combination of
/// those two checks; either failing rejects the answer and the pipeline falls back to the rules
/// fallback / cleaned text.
public enum ModeGuards {
    public enum Result: Equatable {
        case accepted(String)
        case rejected(String)
    }

    public static func check(answer: String, raw: String, instruction: String) -> Result {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^(Output|Text|Transformed( text)?):\\s*", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return .rejected("empty") }
        if let reason = PromptInjectionGuard.violation(answer: cleaned, raw: raw) {
            return .rejected(reason)
        }
        if let reason = FactPreservationGuard.violation(answer: cleaned, raw: raw) {
            return .rejected(reason)
        }
        return .accepted(cleaned)
    }
}

/// Rejects an answer that dropped a fact (named entity, number, or date) present in the raw
/// text, or that appears to have invented one that wasn't. Facts are compared as sets rather
/// than positionally, since a transform mode is expected to reorder/reformat freely (a bulleted
/// list reorders nothing, but an email adds a greeting before the first fact and a sign-off
/// after the last).
public enum FactPreservationGuard {
    public static func violation(answer: String, raw: String) -> String? {
        let rawFacts = extractFacts(raw)
        let answerFacts = extractFacts(answer)

        let dropped = rawFacts.numbers.subtracting(answerFacts.numbers)
        if !dropped.isEmpty { return "dropped number(s): \(dropped.sorted().joined(separator: ", "))" }

        let droppedNames = rawFacts.names.subtracting(answerFacts.names)
        if !droppedNames.isEmpty { return "dropped name(s): \(droppedNames.sorted().joined(separator: ", "))" }

        let droppedDates = rawFacts.dates.subtracting(answerFacts.dates)
        if !droppedDates.isEmpty { return "dropped date(s)/time(s): \(droppedDates.sorted().joined(separator: ", "))" }

        // Invented numbers are the cheapest hallucination to check for confidently (a digit
        // sequence that appears nowhere in the source almost never belongs there). Names/dates
        // are not checked in the "invented" direction: a formatting instruction ("format as an
        // email") legitimately introduces name-shaped words that are not new facts (a sign-off
        // "Best," followed by the user's own name is expected, not an invented fact — see
        // `Mode.builtIns`'s email prompt, which supplies that name explicitly).
        let inventedNumbers = answerFacts.numbers.subtracting(rawFacts.numbers)
        if !inventedNumbers.isEmpty { return "invented number(s): \(inventedNumbers.sorted().joined(separator: ", "))" }

        return nil
    }

    struct Facts {
        var numbers: Set<String>
        var names: Set<String>
        var dates: Set<String>
    }

    static func extractFacts(_ text: String) -> Facts {
        let numbers = Set(Regex.matches(text, "\\d+(?:[.,:]\\d+)*").compactMap { $0.string(at: 0, in: text) })
        let dates = Set(Regex.matches(
            text,
            "(?i)\\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?\\b|" +
            "(?i)\\b(?:Mon|Tue|Tues|Wed|Thu|Thurs|Fri|Sat|Sun)[a-z]*\\.?\\b"
        ).compactMap { $0.string(at: 0, in: text)?.lowercased() })
        let sentences = Sentences.split(text)
        var names: Set<String> = []
        for sentence in sentences {
            let tokens = sentence.split(separator: " ").map(String.init)
            for (index, rawToken) in tokens.enumerated() {
                let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
                guard let first = token.first, first.isUppercase, token != "I" else { continue }
                if index == 0 { continue }
                names.insert(token.lowercased())
            }
        }
        return Facts(numbers: numbers, names: names, dates: dates)
    }
}

/// Rejects an answer that looks like it *complied* with an instruction embedded in the dictated
/// text rather than treating that text as data to reformat. This is a coarse, conservative
/// check — it only fires on strong signals — because the base rate of a real dictation
/// containing an imperative sentence ("call Sarah", "remind me to...") is high, and this guard
/// must not reject ordinary transcripts.
public enum PromptInjectionGuard {
    /// Phrases that, if they appear in the model's answer but never in the raw text, strongly
    /// suggest the model started responding *to* the transcript (as if it were a chat prompt)
    /// rather than reformatting it.
    private static let complianceMarkers = [
        "as an ai", "i cannot", "i can't help", "here is a poem", "here's a poem",
        "i'm unable to", "as a language model", "sure, here", "i'd be happy to",
    ]

    public static func violation(answer: String, raw: String) -> String? {
        let lowerAnswer = answer.lowercased()
        let lowerRaw = raw.lowercased()
        for marker in complianceMarkers where lowerAnswer.contains(marker) && !lowerRaw.contains(marker) {
            return "possible instruction compliance: contains \"\(marker)\""
        }
        // A raw transcript that contains an explicit "ignore/disregard previous/above
        // instructions" style phrase is a classic injection attempt; if the answer grew
        // dramatically longer than the raw text (more than double, with a floor so short
        // texts don't trip this on rounding), that's consistent with the model generating new
        // content instead of reformatting the given text.
        let injectionAttempt = Regex.firstMatch(
            lowerRaw, "\\b(?:ignore|disregard|forget)\\b[^.!?]{0,40}\\b(?:previous|above|prior|earlier)\\b[^.!?]{0,20}\\b(?:instructions?|rules?|prompt)\\b"
        ) != nil
        if injectionAttempt {
            let rawWords = OutputGuard.words(raw).count
            let answerWords = OutputGuard.words(answer).count
            if answerWords > max(20, rawWords * 2) {
                return "possible injection compliance: answer grew from \(rawWords) to \(answerWords) words after an embedded 'ignore instructions' phrase"
            }
        }
        return nil
    }
}
