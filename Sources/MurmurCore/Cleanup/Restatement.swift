import Foundation

/// Resolves whole-request corrections: "I need one tomato and two carrots. No, I just need
/// two carrots" → "I just need two carrots". A correction cue ("no", "actually", "wait",
/// "sorry", "I mean") starts a clause whose subject and verb repeat the previous clause's,
/// so the new clause replaces the old one. Different subject or verb → left alone; this is
/// deliberately narrow so literal "no" and ordinary follow-ups are never deleted.
enum Restatement {
    private static let cue = "(?:no|nope|no wait|wait no|actually|wait|sorry|oops|I mean|I meant|correction)"
    private static let subjects: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "let's", "lets"]
    private static let adverbs: Set<String> = ["just", "only", "actually", "really", "still", "also", "do", "don't"]
    private static let quantity = "(?:\\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|some|a few|a couple of)"
    /// Words that make the follow-up an addition, not a replacement ("no, one more").
    private static let additive: Set<String> = ["more", "also", "too", "extra", "another", "else", "plus"]
    /// Same marker SelfCorrection uses to skip a cue it must not reinterpret.
    private static let protectedMarker = "\u{2060}"

    static func apply(_ text: String) -> String {
        var current = text
        for _ in 0..<4 {
            guard let next = resolveFirst(current) else { break }
            current = next
        }
        return current
    }

    private static func resolveFirst(_ text: String) -> String? {
        // `before` ends at a sentence or clause boundary; the cue starts the next clause.
        let pattern = "^(.*?)([.!?,])\\s+\(cue)[,.]?\\s+(?!\(protectedMarker))(.+)$"
        guard let match = Regex.firstMatch(text, pattern),
              let head = match.string(at: 1, in: text),
              let after = match.string(at: 3, in: text),
              let afterRange = Range(match.range(at: 3), in: text)
        else { return nil }

        // "no, one more" adds rather than corrects: protect it from SelfCorrection too.
        let afterWords = Set(after.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !afterWords.isDisjoint(with: additive) {
            var protected = text
            protected.insert(contentsOf: protectedMarker, at: afterRange.lowerBound)
            return protected
        }

        // The replaced clause is the last sentence of `head` (earlier sentences stay).
        let sentenceStart = head.range(of: "[.!?]\\s+(?=[^.!?]*$)", options: .regularExpression)
        let kept = sentenceStart.map { String(head[..<$0.upperBound]) } ?? ""
        let previous = sentenceStart.map { String(head[$0.upperBound...]) } ?? head

        if let restated = subjectVerb(of: after), let original = subjectVerb(of: previous), original == restated {
            return kept + capitalizedFirst(after)
        }
        // "I need two carrots, two beans, no, just one carrot": a restricted quantity
        // replaces the listed items after the verb.
        if after.range(of: "^(?:just|only)\\s+(?:\(quantity)|a|an)\\b", options: [.regularExpression, .caseInsensitive]) != nil,
           let listStart = previous.range(of: "(?<=\\s)\(quantity)\\b", options: [.regularExpression, .caseInsensitive]) {
            return kept + String(previous[..<listStart.lowerBound]) + after
        }
        return nil
    }

    /// Subject pronoun and main verb at the start of a clause, skipping adverbs:
    /// "I just need two carrots" → ("i", "need"); "let's meet Tuesday" → ("let's", "meet").
    private static func subjectVerb(of clause: String) -> [String]? {
        let words = clause.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard let subject = words.first, subjects.contains(subject) else { return nil }
        guard let verb = words.dropFirst().first(where: { !adverbs.contains($0) }) else { return nil }
        return [subject == "lets" ? "let's" : subject, verb]
    }

    /// Trailing filler that follows the item in speech ("skip the tent actually") isn't part of it.
    static func cleanItem(_ item: String) -> String {
        item.replacingOccurrences(of: "(?:\\s+(?:actually|instead|too|then|please|anyway))+\\s*$", with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

/// Deterministic fallback for a correction `RetractionGuard` rejected the model's answer to:
/// "<head with item(s)>, <cue>, <retract verb> [the] <item>, <trailing reason clause>." becomes
/// "<head with the item removed>, <trailing reason clause>." Used only when `SmartCleaner`
/// already found and rejected a model rewrite that kept the retracted item — this is the "merged
/// candidate" fallback for goal 1(b): resolve the correction with rules rather than surface the
/// unresolved draft (cue and retracted item still in it) when the model can't be trusted here.
enum RetractionMerge {
    /// Lists followed by a short tail ("Invite Sam, Lisa and Noah to dinner", "Reserve the cabin
    /// and the boat for the offsite"): remove the item from the list part, keep the tail.
    private static func removeItemBeforeTail(_ item: String, from head: String) -> String? {
        guard let tail = head.range(of: "\\s+(?:to|for|at|in|on|from|with|by)\\s+[^,]+$", options: .regularExpression)
        else { return nil }
        guard let list = removeItem(item, from: String(head[..<tail.lowerBound])) else { return nil }
        return list + head[tail.lowerBound...]
    }

    private static let cue = "(?:no wait|no|nope|actually|wait|sorry)"
    private static let retractionVerbs = "(?:forget(?: about)?|skip|cancel|scratch|drop|remove)"
    /// "Never mind X" / "Scratch X" are themselves the retraction verb, with no separate cue
    /// word in front of them — same split `RetractionGuard.retractedItem` uses.
    private static let selfCueVerbs = "(?:never ?mind|scratch|forget(?: about)?|skip|cancel|drop|remove)"

    static func apply(_ text: String) -> String? {
        // `head` ends where the correction clause begins; `item` is what to remove from `head`;
        // `after` is the trailing reason clause kept as-is.
        // Groups: 1 head, 2 retraction ("not the ", "skip the "), 3 item, 4 trailing clause.
        let withCue = "^(.*?),\\s*\(cue)[,.]?\\s+" +
            "((?:\(retractionVerbs)|not)\\s+(?:the\\s+|an?\\s+)?)" +
            "([A-Za-z][A-Za-z' -]*?)\\s*[,.]\\s+(.+)$"
        let selfCue = "^(.*?),\\s*(\(selfCueVerbs)\\s+(?:the\\s+|an?\\s+)?)" +
            "([A-Za-z][A-Za-z' -]*?)\\s*[,.]\\s+(.+)$"
        guard let match = Regex.firstMatch(text, withCue) ?? Regex.firstMatch(text, selfCue),
              let head = match.string(at: 1, in: text),
              let retraction = match.string(at: 2, in: text),
              let rawItem = match.string(at: 3, in: text),
              let after = match.string(at: 4, in: text)
        else { return nil }

        let item = Restatement.cleanItem(rawItem)
        guard !item.isEmpty, let trimmedHead = removeItem(item, from: head) ?? removeItemBeforeTail(item, from: head)
        else { return nil }
        // Keep the retraction explicit: the reason is about the dropped item, and attaching it
        // to the remaining list would change its meaning ("Call the electrician, he already
        // came by" makes the electrician the one who came). → "Call the electrician. Not the
        // plumber, he already came by last week."
        let lead = retraction.hasPrefix("no") || retraction.lowercased().hasPrefix("not") ? "Not " : capitalizedFirst(retraction)
        let retractionPhrase = (lead == "Not " ? "Not " + retraction.dropFirst(4) : lead) + item
        let sentence = trimmedHead.hasSuffix(".") ? trimmedHead : trimmedHead + "."
        return sentence + " " + retractionPhrase + ", " + after
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Removes `item` from a comma/"and"-joined list inside `head` (e.g. "apples, bananas, and
    /// oranges", "the charger and the adapter", "Maria and to Devon") and rejoins the remaining
    /// items in standard list style ("X, Y and Z" / "X and Y" / "X"). Returns nil if `item` isn't
    /// found as a standalone list item, so the caller can decline rather than guess.
    private static func removeItem(_ item: String, from head: String) -> String? {
        // Split the trailing list off the lead-in verb phrase: the last run of words before the
        // list is the lead-in ("We need", "Bring the", "Grab", "Send the report to"); the list
        // itself is comma/"and"-separated items, each 1-3 words (a bare noun through a short
        // phrase like "the small one" or "the checkout flow"). The naive greedy match over-grows
        // into the lead-in when it also contains short comma/"and"-joined words (`Restatement`'s
        // own tests caught "The proposal covers staffing" being mistaken for list items), so this
        // tries the match anchored at every comma/start-of-string boundary, preferring the
        // longest list that still contains `item` as one of its own elements — the lead-in verb
        // phrase itself essentially never repeats `item`, so requiring the match to contain it
        // rules out the over-grown case without needing `item` to be the list's last element.
        let listItem = "(?:to\\s+|the\\s+)?\\S+(?:\\s+\\S+){0,2}"
        let listPattern = "\\b\(listItem)(?:,\\s*\(listItem))*(?:,?\\s+and\\s+\(listItem))$"
        guard let fullRange = head.range(of: listPattern, options: [.regularExpression, .backwards])
        else { return nil }

        let itemKey = BoostGuard.key(item)
        func candidateItems(_ list: Substring) -> [String] {
            String(list).components(separatedBy: ",").flatMap { part -> [String] in
                part.range(of: "\\s+and\\s+", options: .regularExpression).map { range in
                    [String(part[part.startIndex..<range.lowerBound]), String(part[range.upperBound...])]
                } ?? [part]
            }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func matches(_ candidate: String) -> Bool {
            let stripped = candidate.replacingOccurrences(of: "^(?:to|the|an?)\\s+", with: "", options: .regularExpression)
            if BoostGuard.key(stripped) == itemKey || BoostGuard.key(candidate) == itemKey { return true }
            // "skip the vendor call" retracts the list item "the vendor": every content word of
            // the list item appears in the retracted phrase.
            let itemWords = Set(item.lowercased().split(separator: " ").map { BoostGuard.key(String($0)) })
            let candidateWords = stripped.lowercased().split(separator: " ").map { BoostGuard.key(String($0)) }
            return !candidateWords.isEmpty && candidateWords.allSatisfy { itemWords.contains($0) }
        }

        // Prefer the full greedy match if it already contains the item as its own list element;
        // otherwise walk forward from each comma to find the narrowest suffix list that does.
        var listRange = fullRange
        if !candidateItems(head[fullRange]).contains(where: matches) {
            var searchStart = head.startIndex
            var found: Range<String.Index>?
            while let comma = head.range(of: ",", range: searchStart..<fullRange.upperBound) {
                let candidateRange = head.index(after: comma.lowerBound)..<fullRange.upperBound
                if candidateItems(head[candidateRange]).contains(where: matches) {
                    found = candidateRange
                    break
                }
                searchStart = head.index(after: comma.lowerBound)
            }
            // No narrower list contains the item; keep the full match and let the lead-in peel
            // below try ("Invite Tom and Priya" → lead-in "Invite", items Tom / Priya).
            if let found { listRange = found }
        }

        var leadIn = String(head[head.startIndex..<listRange.lowerBound])
        var items = candidateItems(head[listRange])
        guard items.count >= 2 else { return nil }

        // The list regex can swallow the lead-in verb into the first item ("Invite Tom" in
        // "Invite Tom and Priya"). When nothing matches, peel leading words off the first item
        // into the lead-in until its remainder is the retracted item.
        if !items.contains(where: matches) {
            let firstWords = items[0].split(separator: " ").map(String.init)
            if let split = (1..<max(firstWords.count, 1)).first(where: { matches(firstWords[$0...].joined(separator: " ")) }) {
                leadIn += (leadIn.isEmpty ? "" : " ") + firstWords[..<split].joined(separator: " ")
                items[0] = firstWords[split...].joined(separator: " ")
            }
        }

        guard let index = items.firstIndex(where: matches) else { return nil }
        items.remove(at: index)
        guard !items.isEmpty else { return nil }

        let joined: String
        if items.count == 1 {
            joined = items[0]
        } else {
            joined = items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
        return Punctuation.tidy(leadIn + " " + joined)
    }

    private static func lowercasingFirstWord(_ text: String) -> String {
        Punctuation.lowercasingFirst(text)
    }
}
