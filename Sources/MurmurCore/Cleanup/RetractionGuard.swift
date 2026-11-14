import Foundation

enum RetractionGuard {
    /// Verbs/markers that introduce the retracted item directly (no "the"/"a" required to
    /// match, but usually present): "forget the eggs", "skip oranges", "not Tom".
    private static let retractionVerbs = "(?:forget(?: about)?|skip|cancel|scratch|drop|remove)"

    static func violation(answer: String, draft: String) -> String? {
        guard let item = retractedItem(in: draft) else { return nil }
        let answerKeys = Set(OutputGuard.words(answer))
        let itemKeys = Set(item.split(whereSeparator: \.isWhitespace).map { BoostGuard.key(String($0)) })
            .filter { !$0.isEmpty }
        if let clause = trailingClause(in: draft) {
            // With a reason clause, the item must stay named in an explicit retraction ("Not the
            // cups, …") or the reason re-attaches to the remaining items and changes meaning.
            let retraction = "\\b(?:not|skip|forget(?: about)?|cancel|never ?mind|scratch|drop|remove)\\s+(?:the\\s+|an?\\s+)?"
                + NSRegularExpression.escapedPattern(for: item) + "\\b"
            if answer.range(of: retraction, options: [.regularExpression, .caseInsensitive]) == nil {
                return "reason detached from retracted item: \(item)"
            }
            // The mention inside the explicit retraction is allowed, but the item must not
            // also survive in the active request before that retraction. Checking the entire
            // answer would count the required "Forget X" wording as evidence that X remains.
            if activeRequestKeeps(item, answer: answer) {
                return "kept retracted item: \(item)"
            }
            let clauseKeys = Set(OutputGuard.words(clause))
            if clauseKeys.count >= 3, clauseKeys.intersection(answerKeys).count < (clauseKeys.count + 1) / 2 {
                return "dropped trailing clause: \(clause)"
            }
            return nil
        }
        if !itemKeys.isEmpty, itemKeys.isSubset(of: answerKeys) {
            // Every content word of the retracted item still present verbatim means the model
            // kept what it was told to drop, rather than folding a reason clause in around a
            // real deletion.
            return "kept retracted item: \(item)"
        }
        // The correction correctly dropped the item; now check it didn't also drop a trailing
        // reason/new-information clause that came after it (the original over-deletion failure
        // this feature exists to fix — instructions rule 2 asks the model to keep this, but a
        // model that already gets the deletion right can still silently drop the clause after
        // it). Most of the clause's content words (a couple may legitimately get folded into a
        // shorter join) missing from the answer means it was dropped, not merged.
        if let clause = trailingClause(in: draft) {
            let clauseKeys = Set(OutputGuard.words(clause))
            let survivors = clauseKeys.intersection(answerKeys)
            if clauseKeys.count >= 3, survivors.count < (clauseKeys.count + 1) / 2 {
                return "dropped trailing clause: \(clause)"
            }
        }
        return nil
    }

    private static func activeRequestKeeps(_ item: String, answer: String) -> Bool {
        let escapedItem = NSRegularExpression.escapedPattern(for: item)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        let pattern = "\\b(?:not|skip|forget(?: about)?|cancel|never ?mind|scratch|drop|remove)\\s+(?:the\\s+|an?\\s+)?"
            + escapedItem + "\\b"
        guard let match = Regex.firstMatch(answer, pattern) else { return false }
        let prefix = (answer as NSString).substring(to: match.range.location)
        let itemPattern = "\\b" + escapedItem + "\\b"
        return prefix.range(of: itemPattern, options: .regularExpression.union(.caseInsensitive)) != nil
    }

    /// A model answer that resolved a retraction and then *also* restated it as a bare closing
    /// sentence with no reason ("Let's bring potato and ketchup. Forget about tomato.") keeps the
    /// retracted item in the text only as an echo of the cue. When the draft gives no reason for
    /// the retraction (a reason must stay attached — see `violation`), that echo sentence is
    /// dropped so the resolved answer can be judged on its own.
    static func droppingBareRetraction(_ answer: String, draft: String) -> String {
        guard trailingClause(in: draft) == nil, retractedItem(in: draft) != nil else { return answer }
        let pattern = "\\s*(?<=[.!?])\\s*(?:forget(?: about)?|skip|scratch|cancel|drop|remove|not)\\s+(?:the\\s+|an?\\s+)?[A-Za-z'\u{2019} -]{1,30}[.!]\\s*$"
        let stripped = Regex.replace(answer, pattern, with: "")
        return stripped.trimmingCharacters(in: .whitespaces).isEmpty ? answer : stripped
    }

    /// The reason/new-information clause that follows the retraction, up to the next sentence
    /// boundary — the part instructions rule 2 asks the model to keep. Uses the same clause-start
    /// markers as `retractedItem`'s lookahead so the two stay in sync.
    static func trailingClause(in draft: String) -> String? {
        let pattern = "\\b(?:no|nope|actually|wait|sorry|never ?mind|scratch|forget(?: about)?|skip|cancel|drop|remove)\\b" +
            "[,.]?\\s+.*?,\\s*((?:i|we|he|she|they|it)\\b[^.!?]*|because\\b[^.!?]*|since\\b[^.!?]*|(?-i:[A-Z][a-z]+)\\s+(?:is|was|has|had|will|would|can|could|does|did|moved|works|already|lives|travels)\\b[^.!?]*)[.!?]?\\s*$"
        guard let match = Regex.matches(draft, pattern).first(where: { !isNegatedCue($0, in: draft) && !isOrdinaryUse($0, in: draft) }),
              let clause = match.string(at: 1, in: draft) else {
            return nil
        }
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Finds "<retraction verb> [the/a] <item>" or "not <item>" following a correction cue, up
    /// to the next clause boundary (comma, period, or a conjunction like "we"/"because" starting
    /// the trailing reason clause). Returns nil when no such pattern is found — most drafts have
    /// no retraction at all, and this guard only fires when one is confidently identified.
    static func retractedItem(in draft: String) -> String? {
        let pattern = "\\b(?:no|nope|actually|wait|sorry)\\b[,.]?\\s+" +
            "(?:\(retractionVerbs)\\s+(?:the\\s+|an?\\s+)?|not\\s+(?:the\\s+|an?\\s+)?)" +
            "([A-Za-z][A-Za-z' -]*?)(?=[,.!?]|\\s+(?:i|we|he|she|they|it|because|since)\\b|\\s+(?-i:[A-Z][a-z]+)\\s+(?:is|was|has|had|will|would|can|could|does|did|moved|works|already|lives|travels)\\b|$)"
        // "Never mind X" / "Scratch X" are themselves the retraction verb, with no separate cue
        // word in front of them.
        let selfCuePattern = "\\b(?:never ?mind|scratch|forget(?: about)?|skip|cancel|drop|remove)\\s+" +
            "(?:the\\s+|an?\\s+)?([A-Za-z][A-Za-z' -]*?)(?=[,.!?]|\\s+(?:i|we|he|she|they|it|because|since)\\b|\\s+(?-i:[A-Z][a-z]+)\\s+(?:is|was|has|had|will|would|can|could|does|did|moved|works|already|lives|travels)\\b|$)"
        let match = (Regex.matches(draft, pattern) + Regex.matches(draft, selfCuePattern))
            .first { !isNegatedCue($0, in: draft) && !isOrdinaryUse($0, in: draft) }
        guard let match, let item = match.string(at: 1, in: draft) else { return nil }
        let trimmed = Restatement.cleanItem(item)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Words that, right before "skip", "cancel", "drop" or "remove" (or before an "actually" that precedes one), say the
    /// verb is part of what the speaker is asking for ("we should skip the demo", "they might cancel unless", "can we
    /// drop the vendor"), not a correction of what came before.
    private static let ordinaryUseLeads: Set<String> = [
        "to", "should", "shall", "might", "may", "will", "would", "could", "can", "must", "need", "needs", "want",
        "wants", "we", "i", "you", "they", "he", "she", "it", "please", "lets", "let's", "gonna", "wanna", "gotta",
        "unless", "if", "who", "that", "which",
    ]
    private static let ordinaryUseFillers: Set<String> = ["actually", "just", "really", "also", "then", "even"]

    /// A match that follows a modal, "to" or a subject in the same clause is the speaker's request, not a retraction. A
    /// match after a comma or a sentence end (or at the start) is read as a correction as before.
    private static func isOrdinaryUse(_ match: NSTextCheckingResult, in draft: String) -> Bool {
        let source = draft as NSString
        let start = max(0, match.range.location - 60)
        var prefix = source.substring(with: NSRange(location: start, length: match.range.location - start))
        if let boundary = prefix.lastIndex(where: { ",.;:!?".contains($0) }) { prefix = String(prefix[prefix.index(after: boundary)...]) }
        var words = prefix.split(whereSeparator: \.isWhitespace).map {
            $0.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        }
        while let last = words.last, ordinaryUseFillers.contains(last) { words.removeLast() }
        guard let last = words.last else { return false }
        if ordinaryUseLeads.contains(last), !namesAnEarlierItem(match, in: draft) { return true }
        // A subject or modal earlier in the same clause makes the verb the clause's own ("can we, to cut costs, drop the
        // second vendor"), even when other words stand between them; what a retraction takes back must have been said
        // before it, at any length of word, so a verb whose object was never named is a request.
        return words.contains(where: ordinaryUseLeads.contains) && !namesAnEarlierItem(match, in: draft, minimumLength: 3)
    }

    /// Words that follow a retraction verb without being the item ("skip the pencils because ...").
    static let notAnItem: Set<String> = ["because", "since", "unless", "that", "with", "this", "then", "when", "before", "after"]

    /// True when what the verb takes was named earlier in the dictation ("bring pens and pencils, we should actually skip
    /// the pencils"): then the verb takes an item back, whatever words lead it. When the object was not named before
    /// ("skip the Friday demo", "cancel unless we"), the verb is a plain one.
    private static func namesAnEarlierItem(_ match: NSTextCheckingResult, in draft: String, minimumLength: Int = 4) -> Bool {
        let source = draft as NSString
        let tail = source.substring(from: match.range.location)
        guard let object = Regex.firstMatch(tail, "\\b\(retractionVerbs)\\s+(?:the\\s+|an?\\s+)?([A-Za-z]+(?:\\s+[A-Za-z]+)?)"),
              let words = object.string(at: 1, in: tail) else { return false }
        let before = source.substring(to: match.range.location).lowercased()
        return OutputGuard.words(words.lowercased()).contains {
            $0.count >= minimumLength && !notAnItem.contains($0) && before.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
        }
    }

    /// A negated instruction names something to keep ("do not remove", "never forget"), not a
    /// self-correction. Examine only the local prefix without crossing punctuation. Skip that
    /// cue rather than stopping the search, so a later genuine correction can still be found.
    private static func isNegatedCue(_ match: NSTextCheckingResult, in draft: String) -> Bool {
        let source = draft as NSString
        let start = max(0, match.range.location - 100)
        let prefix = source.substring(with: NSRange(location: start, length: match.range.location - start))
        let negation = #"\b(?:not|never|don['’]t|doesn['’]t|didn['’]t|can['’]t|cannot|couldn['’]t|mustn['’]t|shouldn['’]t|wouldn['’]t|won['’]t)(?:\s+[A-Za-z]+){0,2}\s+$"#
        return Regex.firstMatch(prefix, negation) != nil
    }

}
