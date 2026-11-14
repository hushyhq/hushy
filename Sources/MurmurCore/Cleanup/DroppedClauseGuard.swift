import Foundation

/// Safety net for a model answer that deletes a whole clause the draft has before a hedge or
/// discourse marker, or the request the dictation opens with:
///
/// - "the import it fails on files over two gigs I think we should never…" → "I think we should
///   never…" (the problem report is gone);
/// - "can you remind me what we decided about the free tier I think it was…" → "I think the free
///   tier was…" (the question is gone);
/// - "Send it to John, no, Sarah, she also I think needs the file" → "I think Sarah also needs the
///   file" (the instruction is gone).
///
/// A fine-tuned candidate (v5.2, not promoted) learned this, and `OutputGuard`'s "dropped too much"
/// floor (a quarter of the draft) let it through. Model-agnostic and deterministic: it compares
/// content words (lowercased, crudely stemmed, number words as digits) and never rewrites the
/// answer. When it fires the rules draft is used and the log says
/// `why=rejected-by-guard(dropped-clause-before-hedge)` or `(dropped-leading-request)`, like
/// `ListStructureGuard`, so how often a backend does this is countable.
///
/// A self-correction still passes: the words it drops are the corrected slot ("Tuesday, I mean
/// Wednesday": a same-kind replacement, `SelfCorrection`'s notion) or a frame the speaker restates
/// ("Our landlord won't, I mean our landlord will fix it").
enum DroppedClauseGuard {
    static let droppedClause = "dropped-clause-before-hedge"
    static let droppedRequest = "dropped-leading-request"

    /// Content words a dropped clause must lose before the answer is rejected.
    static let minimumDroppedWords = 4

    static func violation(answer: String, draft: String) -> String? {
        let answerStems = Set(contentWords(answer).map(stem))
        // Light verbs are not content words, but an answer that keeps "do" keeps the request it carried.
        let requestStems = answerStems.union(OutputGuard.words(answer).filter { lightVerbs.contains($0) }.map(stem))
        if dropsLeadingRequest(answerStems: requestStems, draft: draft) { return droppedRequest }
        if dropsClauseBeforeMarker(answerStems: answerStems, draft: draft) { return droppedClause }
        return nil
    }

    // MARK: - Clause before a hedge or discourse marker

    /// Hedges and discourse markers a model may keep while deleting what came before them.
    private static let markerPattern = "\\b(?:i think|i feel|i guess|i mean|honestly|basically)\\b"
    /// Markers that can also open a self-correction ("Tuesday, I mean Wednesday").
    private static let correctionMarkers: Set<String> = ["i mean"]

    private static func dropsClauseBeforeMarker(answerStems: Set<String>, draft: String) -> Bool {
        let nsDraft = draft as NSString
        var segmentStart = 0
        for match in Regex.matchesCaseSensitive(draft, "(?i)" + markerPattern) {
            let markerStart = match.range.location
            let before = nsDraft.substring(with: NSRange(location: segmentStart, length: markerStart - segmentStart))
            segmentStart = markerStart + match.range.length
            // The clause runs from its sentence start (or the previous marker) to the marker.
            let clause = before.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? before
            let clauseWords = contentWords(clause)
            guard clauseWords.count >= minimumDroppedWords else { continue }
            let marker = nsDraft.substring(with: match.range).lowercased()
            let after = nsDraft.substring(from: segmentStart)
            if correctionMarkers.contains(marker), restatesFrame(clause: clause, after: after) { continue }
            let correctedKinds = correctionMarkers.contains(marker) ? replacementKinds(after) : []
            let dropped = clauseWords.filter { word in
                !answerStems.contains(stem(word)) && !isCorrectedSlot(word, clause: clause, kinds: correctedKinds)
            }
            if dropped.count >= minimumDroppedWords { return true }
        }
        return false
    }

    /// "Our landlord won't, I mean our landlord will…": the words after the cue restate the
    /// clause's opening frame, so the clause is being corrected, not lost.
    private static func restatesFrame(clause: String, after: String) -> Bool {
        let clauseKeys = OutputGuard.words(clause)
        let afterKeys = OutputGuard.words(after)
        let frameLength = min(2, clauseKeys.count)
        guard frameLength > 0, afterKeys.count >= frameLength else { return false }
        return Array(clauseKeys.prefix(frameLength)) == Array(afterKeys.prefix(frameLength))
    }

    /// The kinds (number, weekday, month, time, name) of the first few tokens after a cue.
    private static func replacementKinds(_ after: String) -> [Token.Kind] {
        Token.split(after).prefix(3).compactMap(\.kind).filter { $0 != .word }
    }

    /// "Tuesday" in "on Tuesday, I mean Wednesday": the slot the replacement corrects.
    private static func isCorrectedSlot(_ word: String, clause: String, kinds: [Token.Kind]) -> Bool {
        guard !kinds.isEmpty else { return false }
        let token = Token.split(clause).first { OutputGuard.words($0.text).contains(word) }
        guard let kind = token?.kind else { return false }
        return kinds.contains { $0.isCompatible(with: kind) }
    }

    // MARK: - Leading request

    /// Lead-ins spoken before a request ("okay so can you…").
    private static let leadIns: Set<String> = ["okay", "ok", "so", "um", "uh", "hey", "alright", "oh", "and", "well"]
    /// Openers whose verb follows them: "can you remind…", "please send…".
    private static let requestOpeners: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["can", "we"], ["could", "we"], ["please"],
    ]
    /// Verbs that open an imperative request to the person or app receiving the text.
    private static let imperativeVerbs: Set<String> = [
        "send", "remind", "email", "text", "call", "tell", "add", "schedule", "book", "set", "create", "put",
        "move", "cancel", "forward", "reply", "message", "ask", "write", "draft", "save", "check", "find",
        "open", "share", "invite", "update", "delete", "remove", "change", "order", "pick", "bring", "show",
        "review", "fix", "make",
    ]
    private static let correctionCues: Set<String> = ["no", "sorry", "wait", "actually", "oops"]

    /// True when the draft opens with a question or imperative ("can you remind…", "send…") whose
    /// verb the answer no longer has. A verb corrected on the spot ("Send, no, email the report")
    /// is exempt: the answer keeps the correction's verb instead.
    private static func dropsLeadingRequest(answerStems: Set<String>, draft: String) -> Bool {
        // A single letter after the opener is a stutter ("can we m make", "please s send"), never the verb. Without
        // this the stutter letter is read as the verb, and the model removing it looks like a lost request.
        let keys = Array(OutputGuard.words(draft).drop { leadIns.contains($0) }.filter { $0.count > 1 || $0 == "i" || $0 == "a" })
        var verbIndex: Int?
        if let opener = requestOpeners.first(where: { keys.starts(with: $0) }) {
            var index = opener.count
            while index < keys.count, keys[index] == "please" { index += 1 }
            if index < keys.count { verbIndex = index }
        } else if let first = keys.first, imperativeVerbs.contains(first) {
            verbIndex = 0
        }
        // "can we to cut costs actually drop the vendor": a function word after the opener is the speaker's false start,
        // not the verb; the verb is the first content word after it. Light verbs ("can you do the dishes by Friday",
        // "can you have the report ready") are the request itself, so they stay possible verbs.
        while let index = verbIndex, index < keys.count, stopWords.contains(keys[index]), !lightVerbs.contains(keys[index]) {
            verbIndex = index + 1 < keys.count ? index + 1 : nil
        }
        guard let verbIndex else { return false }
        if verbIndex + 1 < keys.count, correctionCues.contains(keys[verbIndex + 1]) { return false }
        return !answerStems.contains(stem(keys[verbIndex]))
    }

    /// Verbs that are on the stop list for the content-word count but can carry a request on their own.
    private static let lightVerbs: Set<String> = ["do", "does", "did", "have", "has", "had"]

    // MARK: - Content words

    /// Function words, fillers, hedges and light verbs: never the content a clause carries.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "then", "than", "that", "this", "these", "those",
        "it", "its", "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his", "she", "her",
        "they", "them", "their", "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "into",
        "over", "under", "up", "down", "out", "off", "as", "is", "are", "was", "were", "am", "be", "been",
        "being", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "shall", "may", "might", "must", "not", "no", "yes", "also", "too", "just", "really", "very", "um",
        "uh", "like", "okay", "ok", "yeah", "well", "oh", "actually", "basically", "honestly", "literally",
        "think", "feel", "guess", "mean", "what", "which", "who", "when", "where", "why", "how", "there",
        "here", "some", "any", "all", "every", "each", "much", "many", "more", "most", "t", "s", "ll", "re",
        "ve", "d", "m", "please", "one",
    ]
    private static let numberWords: [String: Int] = InverseTextNormalizer.ones
        .merging(InverseTextNormalizer.teens) { first, _ in first }
        .merging(InverseTextNormalizer.tens) { first, _ in first }

    /// Content words of `text`, number words as digits ("two gigs" → "2", "gigs").
    static func contentWords(_ text: String) -> [String] {
        OutputGuard.words(text).compactMap { word in
            if let value = numberWords[word] { return String(value) }
            return stopWords.contains(word) ? nil : word
        }
    }

    /// A crude shared root, so "files"/"file", "decided"/"decide", "fixes"/"fix" match.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ies", "ed", "es", "s", "e"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }
}
