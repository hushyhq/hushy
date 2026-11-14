import Foundation

/// Counts-only tracing for where a screen key term was lost on one dictation. Invented eval text only;
/// the app uses the aggregate counts for logging, never the term strings.
public enum ContextTermTrace {
    public enum Stage: String, Sendable, CaseIterable {
        case notExtracted = "not_extracted"
        case notBoosted = "not_in_vocabulary"
        case boostReverted = "boost_reverted"
        case notRepaired = "not_repaired"
        case cleanupDamaged = "cleanup_damaged"
        case ok = "ok"
    }

    public struct KeyTerm: Sendable, Equatable {
        public let term: String
        public let stage: Stage
        public init(term: String, stage: Stage) { self.term = term; self.stage = stage }
    }

    /// Terms the widened extractor would take from `screenText` (production window path).
    public static func extractedTerms(from screenText: String) -> [String] {
        ContextExtractor.extractWidened(from: screenText)
    }

    /// Terms dropped only because `LearningLexicon.isCommonWord` or `commonWordDenylist` would exclude them
    /// from the widened pass (still present in the raw window text).
    public static func commonWordFiltered(from screenText: String) -> Int {
        let windowed = String(screenText.suffix(ContextExtractor.widenedWindowLength))
        var count = 0
        for token in Regex.matchesCaseSensitive(windowed, "[A-Za-z][A-Za-z0-9]*(?:[.'’-][A-Za-z0-9]+)*") {
            guard let word = token.string(at: 0, in: windowed), word.count >= ContextExtractor.widenedMinLength else { continue }
            let key = word.lowercased()
            guard LearningLexicon.isCommonWord(key) || ContextExtractor.commonWordDenylist.contains(key) else { continue }
            if windowed.range(of: word, options: .caseInsensitive) != nil { count += 1 }
        }
        return count
    }

    /// Classifies each `keyTerm` after the pipeline stages the eval can observe without logging words.
    public static func classify(
        keyTerms: [String],
        screenText: String,
        extracted: [String],
        baseASR: String,
        afterBoost: String,
        afterRepair: String,
        finalText: String
    ) -> [KeyTerm] {
        let extractedKeys = Set(extracted.map { $0.lowercased() })
        return keyTerms.map { term in
            let key = term.lowercased()
            guard extractedKeys.contains(key) || extracted.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
                return KeyTerm(term: term, stage: .notExtracted)
            }
            guard ScreenTermMatch.contains(afterBoost, term: term)
                || ScreenTermMatch.occurrences(of: term, in: afterBoost, caseSensitive: false) else {
                if ScreenTermMatch.contains(baseASR, term: term)
                    || ScreenTermMatch.occurrences(of: term, in: baseASR, caseSensitive: false) {
                    return KeyTerm(term: term, stage: .boostReverted)
                }
                return KeyTerm(term: term, stage: .notBoosted)
            }
            if ScreenTermMatch.contains(afterRepair, term: term)
                || ScreenTermMatch.occurrences(of: term, in: afterRepair, caseSensitive: false) {
                if ScreenTermMatch.contains(finalText, term: term)
                    || ScreenTermMatch.occurrences(of: term, in: finalText, caseSensitive: false) {
                    return KeyTerm(term: term, stage: .ok)
                }
                return KeyTerm(term: term, stage: .cleanupDamaged)
            }
            return KeyTerm(term: term, stage: .notRepaired)
        }
    }

    public static func stageCounts(_ traced: [KeyTerm]) -> [Stage: Int] {
        var counts: [Stage: Int] = [:]
        for item in traced { counts[item.stage, default: 0] += 1 }
        return counts
    }
}

/// Whole-word presence checks for screen key terms (invented eval text and tracing only).
public enum ScreenTermMatch {
    public static func contains(_ output: String, term: String) -> Bool {
        if occurrences(of: term, in: output, caseSensitive: true) { return true }
        guard let first = term.first, first.isLowercase else { return false }
        let capitalised = first.uppercased() + term.dropFirst()
        let pattern = "(?:^|[.!?]\\s+)" + NSRegularExpression.escapedPattern(for: capitalised) + "(?![A-Za-z0-9])"
        return output.range(of: pattern, options: .regularExpression) != nil
    }

    public static func occurrences(of term: String, in text: String, caseSensitive: Bool) -> Bool {
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Za-z0-9])"
        return text.range(of: pattern, options: caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]) != nil
    }
}
