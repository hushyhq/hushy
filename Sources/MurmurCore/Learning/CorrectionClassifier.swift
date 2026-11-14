import Foundation

/// One classified change the user made to a dictation shortly after it was inserted.
public struct CorrectionEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// The recognizer misheard a name or term: "Pria" → "Priya", "Kubernetis" → "Kubernetes".
        case asrTerm
        /// Cleanup removed words the speaker meant; the user typed them back ("actually").
        case cleanupOverEdit
        /// Cleanup left a filler the user then deleted ("like", "you know").
        case cleanupUnderEdit
        /// Same words, different casing or punctuation ("Hey." → "hey").
        case formatting
        /// Anything else: a different word, a rewrite, a deliberate one-off change. Never learned.
        case rewrite
    }

    public let kind: Kind
    /// What Hushy inserted (normalized surface, space-joined; empty for a pure insertion).
    public let before: String
    /// What the user left instead (empty for a pure deletion).
    public let after: String

    public init(kind: Kind, before: String, after: String) {
        self.kind = kind
        self.before = before
        self.after = after
    }
}

/// Formatting habits that can be read off surface-only changes.
public enum FormattingSignal: String, Sendable, Codable, CaseIterable {
    /// The user lowercased a capital Hushy produced (sentence start, "I").
    case lowercased
    /// The user removed the terminal period Hushy added.
    case droppedTerminalPeriod
    case noGreeting
    case noExclamation
    case signOffComma = "signOff:,"
}

/// Classifies word-level edits conservatively. Only `asrTerm` feeds vocabulary; everything the
/// classifier is unsure about is `rewrite`, which is never learned.
public enum CorrectionClassifier {
    /// Longest run (in words) considered a term correction; longer runs are rewrites.
    public static let maxTermWords = 3
    /// Words cleanup might remove or leave that a user might restore or delete.
    public static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "like", "so", "well", "basically",
        "actually", "literally", "right", "okay", "ok", "just", "really", "you", "know", "i", "mean",
        "kind", "sort", "of",
    ]

    /// Day and month names. The word list grades them as names (they are always capitalized), so without this a
    /// changed day would read as a misheard term.
    static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
    ]

    /// Classifies each edit. `raw` is the ASR transcript before cleanup (to tell a restored word
    /// from new content); `isCommonWord` is injectable for tests (defaults to the system list).
    public static func classify(
        _ alignment: CorrectionAlignment, raw: String, evidence: TermEvidence = .none,
        isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord
    ) -> [CorrectionEvent] {
        let rawKeys = CorrectionAlignment.tokens(raw).map(CorrectionAlignment.key).filter { !$0.isEmpty }
        var events = alignment.edits.map { classify($0, rawKeys: rawKeys, evidence: evidence, isCommonWord: isCommonWord) }
        events += alignment.surfaceChanges.compactMap { change in
            let before = clean([change.before]), after = clean([change.after])
            if before != after, before.lowercased() == after.lowercased(),
               after.first?.isUppercase == true, evidence.supports(after) {
                return CorrectionEvent(kind: .asrTerm, before: before, after: after)
            }
            guard let signal = formattingSignal(before: change.before, after: change.after) else { return nil }
            // A period only counts as dropped at the very end, and not when the user kept typing.
            if signal == .droppedTerminalPeriod, !change.isFinal || alignment.continuesAfter { return nil }
            if signal == .signOffComma, !change.isFinal || alignment.continuesAfter { return nil }
            return CorrectionEvent(kind: .formatting, before: change.before, after: change.after)
        }
        return events
    }

    static func classify(_ edit: WordEdit, rawKeys: [String], evidence: TermEvidence = .none, isCommonWord: (String) -> Bool) -> CorrectionEvent {
        let beforeKeys = edit.before.map(CorrectionAlignment.key).filter { !$0.isEmpty }
        let afterKeys = edit.after.map(CorrectionAlignment.key).filter { !$0.isEmpty }
        let before = clean(edit.before)
        let after = clean(edit.after)
        let rewrite = CorrectionEvent(kind: .rewrite, before: before, after: after)

        if afterKeys.isEmpty, !beforeKeys.isEmpty {
            return beforeKeys.allSatisfy(fillerWords.contains)
                ? CorrectionEvent(kind: .cleanupUnderEdit, before: before, after: "") : rewrite
        }
        if beforeKeys.isEmpty, !afterKeys.isEmpty {
            // Restored only when the typed words were spoken (a contiguous run in the raw
            // transcript) and are short — otherwise it's new content.
            guard afterKeys.count <= maxTermWords, containsRun(rawKeys, afterKeys) else { return rewrite }
            return CorrectionEvent(kind: .cleanupOverEdit, before: "", after: after)
        }
        guard !beforeKeys.isEmpty, beforeKeys.count <= maxTermWords, afterKeys.count <= maxTermWords else { return rewrite }
        // Numbers, dates and amounts are edits of meaning ("10" → "11", "Tuesday" → "Thursday"), never vocabulary.
        guard !(beforeKeys + afterKeys).contains(where: { $0.contains(where: \.isNumber) || calendarWords.contains($0) }) else { return rewrite }
        guard isTermCorrection(before: beforeKeys, after: edit.after, afterKeys: afterKeys, evidence: evidence, isCommonWord: isCommonWord) else {
            return rewrite
        }
        return CorrectionEvent(kind: .asrTerm, before: before, after: after)
    }

    /// A misrecognized name or term: the replacement looks like a term (capitalized, mixed-case,
    /// or not an ordinary English word), isn't just swapping one ordinary word for another, and
    /// sounds/spells like what was heard.
    static func isTermCorrection(
        before: [String], after surface: [String], afterKeys: [String], evidence: TermEvidence = .none, isCommonWord: (String) -> Bool
    ) -> Bool {
        let afterWords = surface.map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        let supportedCapital = afterWords.contains { $0.first?.isUppercase == true } && evidence.supports(afterWords.joined(separator: " "))
        let looksLikeTerm = supportedCapital || afterWords.contains { word in
            let key = CorrectionAlignment.key(word)
            let hasInnerCapital = word.dropFirst().contains { $0.isUppercase }
            return hasInnerCapital || !isCommonWord(key)
        }
        guard looksLikeTerm else { return false }
        // "their" → "there", "nodes" → "notes": when every heard word and every typed word is
        // ordinary English it's an edit of meaning (or grammar), not a misrecognized term —
        // the same line `BoostGuard` draws for boosting.
        let allCommon = (before + afterKeys).allSatisfy(isCommonWord)
        if allCommon && !supportedCapital { return false }
        return soundsAlike(before.joined(), afterKeys.joined())
    }

    /// How much of the longer word, and of the longer consonant skeleton, may differ for two
    /// words to sound alike. Memory's term recall (`RecallKeys`) applies the same two limits.
    static let alikeWordRatio = 0.4
    static let alikeSkeletonRatio = 0.34

    /// Cheap phonetic/orthographic closeness: normalized edit distance of the joined keys, or
    /// matching consonant skeletons ("Preeya"/"Priya", "Kubernetis"/"Kubernetes").
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Same letters, different spacing ("Terra form" → "Terraform"): a split term.
        if a == b { return true }
        let longer = max(a.count, b.count)
        let distance = levenshtein(Array(a), Array(b))
        if Double(distance) / Double(longer) <= alikeWordRatio { return true }
        let skeletonA = skeleton(a), skeletonB = skeleton(b)
        guard skeletonA.count >= 2, a.first == b.first || skeletonA.first == skeletonB.first else { return false }
        let skeletonDistance = levenshtein(Array(skeletonA), Array(skeletonB))
        return Double(skeletonDistance) / Double(max(skeletonA.count, skeletonB.count)) <= alikeSkeletonRatio
    }

    /// Consonants with common sound-alike letters merged and repeats collapsed.
    static func skeleton(_ word: String) -> String {
        let merged: [Character: Character] = ["c": "k", "q": "k", "z": "s", "v": "f", "w": "f", "j": "g", "x": "k", "d": "t", "b": "p"]
        var out: [Character] = []
        for character in word.lowercased() where character.isLetter && !"aeiouyh".contains(character) {
            let mapped = merged[character] ?? character
            if out.last != mapped { out.append(mapped) }
        }
        return String(out)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Formatting habit read from one same-word pair, if any.
    public static func formattingSignal(before: String, after: String) -> FormattingSignal? {
        guard before.filter({ $0 == "?" }).count == after.filter({ $0 == "?" }).count else { return nil }
        if CorrectionAlignment.key(before) == "thanks", CorrectionAlignment.key(after) == "thanks", before.hasSuffix("!"), after.hasSuffix(",") { return .signOffComma }
        if before == StyleEditSignals.greetingMarker { return .noGreeting }
        if before.hasSuffix("!"), after == String(before.dropLast()) || after == String(before.dropLast()) + "." { return .noExclamation }
        let beforeWord = before.trimmingCharacters(in: .punctuationCharacters)
        let afterWord = after.trimmingCharacters(in: .punctuationCharacters)
        if beforeWord != afterWord, beforeWord.lowercased() == afterWord, beforeWord.first?.isUppercase == true {
            return .lowercased
        }
        if before.hasSuffix("."), after == String(before.dropLast()), beforeWord == afterWord {
            return .droppedTerminalPeriod
        }
        return nil
    }

    private static func clean(_ tokens: [String]) -> String {
        tokens.map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-"))) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
}
