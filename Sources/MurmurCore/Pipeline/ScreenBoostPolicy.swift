import Foundation

/// Which on-screen strings may enter the recogniser's boosting session for one dictation.
/// Product names and rare words only; ordinary English and typical UI chrome are dropped.
public enum ScreenBoostPolicy {
    /// Common words that often appear as button or field labels on screen.
    static let uiLabelDenylist: Set<String> = [
        "next", "done", "cancel", "text", "paste", "copy", "cut", "save", "close", "submit",
        "continue", "back", "send", "edit", "delete", "add", "remove", "search", "settings",
        "help", "menu", "ok", "yes", "no", "open", "new", "more", "less", "view", "show", "hide",
        "skip", "retry", "apply", "confirm", "dismiss", "share", "reply", "forward", "attach",
        "upload", "download", "print", "undo", "redo", "select", "clear", "reset", "filter", "sort",
    ]

    public struct FilterResult: Sendable, Equatable {
        public let terms: [String]
        /// Ordinary English or UI labels removed from the boost list.
        public let droppedOrdinary: Int
        public let keptNames: Int
    }

    public static func filter(_ terms: [String]) -> FilterResult {
        var kept: [String] = []
        var dropped = 0
        for term in terms {
            if shouldBoost(term) { kept.append(term) } else { dropped += 1 }
        }
        return FilterResult(terms: kept, droppedOrdinary: dropped, keptNames: kept.count)
    }

    public static func shouldBoost(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= ContextExtractor.minTermLength, trimmed.count <= ContextExtractor.widenedMaxLength else {
            return false
        }
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2 {
            return parts.contains { part in
                let key = part.lowercased()
                return !LearningLexicon.isCommonWord(key) && !uiLabelDenylist.contains(key)
            }
        }
        let key = trimmed.lowercased()
        if ContextExtractor.commonWordDenylist.contains(key) { return false }
        if uiLabelDenylist.contains(key) { return false }
        if LearningLexicon.isCommonWord(key) { return false }
        return true
    }
}
