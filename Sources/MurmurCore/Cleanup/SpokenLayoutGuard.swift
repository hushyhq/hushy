import Foundation

/// Rejects rewrites that move or flatten line structure already present in the rules draft.
/// Explicit voice commands are converted to newlines before the model call, so the draft is the
/// source of truth for where each line or paragraph break belongs. Ordinary sentence rewrites
/// remain available as long as each existing break stays between the same nearby words.
enum SpokenLayoutGuard {
    static let reason = "spoken-layout-changed"

    private struct Break {
        let newlineCount: Int
        let leftContext: [String]
        let rightContext: [String]
    }

    /// Restores flattened explicit breaks only when every normalized word is unchanged and
    /// in the same order. Punctuation/case refinements survive; ambiguous boundaries do not.
    static func restoringFlattenedBreaks(answer: String, draft: String) -> String {
        let expected = Regex.matches(draft, "\\n+")
        guard !expected.isEmpty, !answer.contains("\n"),
              OutputGuard.words(answer) == OutputGuard.words(draft) else { return answer }
        let tokens = Regex.matches(answer, "[\\p{L}\\p{N}]+")
        guard tokens.count == OutputGuard.words(answer).count else { return answer }
        let original = answer as NSString
        let source = draft as NSString
        var replacements: [(NSRange, String)] = []
        for boundary in expected {
            let wordIndex = OutputGuard.words(source.substring(to: boundary.range.location)).count
            guard wordIndex > 0, wordIndex < tokens.count else { return answer }
            let start = NSMaxRange(tokens[wordIndex - 1].range)
            let end = tokens[wordIndex].range.location
            let gap = original.substring(with: NSRange(location: start, length: end - start))
            guard gap.range(of: "^[.!?,;:\\s]*$", options: .regularExpression) != nil else { return answer }
            let whitespace = Regex.matches(gap, "\\s+")
            guard whitespace.count <= 1 else { return answer }
            let localRange = whitespace.first?.range ?? NSRange(location: (gap as NSString).length, length: 0)
            replacements.append((NSRange(location: start + localRange.location, length: localRange.length),
                                 String(repeating: "\n", count: boundary.range.length)))
        }
        var restored = answer
        for (range, replacement) in replacements.reversed() {
            guard let swiftRange = Range(range, in: restored) else { return answer }
            restored.replaceSubrange(swiftRange, with: replacement)
        }
        return violation(answer: restored, draft: draft) == nil ? restored : answer
    }

    static func violation(answer: String, draft: String) -> String? {
        let expected = breaks(in: draft)
        guard !expected.isEmpty else { return nil }
        let actual = breaks(in: answer)
        guard actual.count == expected.count else { return reason }

        for (expectedBreak, actualBreak) in zip(expected, actual) {
            guard expectedBreak.newlineCount == actualBreak.newlineCount,
                  nearestLeftAnchor(expectedBreak.leftContext, appearsNear: actualBreak.leftContext),
                  nearestRightAnchor(expectedBreak.rightContext, appearsNear: actualBreak.rightContext) else {
                return reason
            }
        }
        return nil
    }

    private static func breaks(in text: String) -> [Break] {
        let nsText = text as NSString
        let ranges = Regex.matches(text, "\\n+").compactMap { match -> NSRange? in
            let range = match.range(at: 0)
            return range.location == NSNotFound ? nil : range
        }
        return ranges.map { range in
            let before = nsText.substring(to: range.location)
            let after = nsText.substring(from: NSMaxRange(range))
            return Break(
                newlineCount: range.length,
                leftContext: Array(OutputGuard.words(before).suffix(3)),
                rightContext: Array(OutputGuard.words(after).prefix(3))
            )
        }
    }

    private static func nearestLeftAnchor(_ expected: [String], appearsNear actual: [String]) -> Bool {
        guard let anchor = expected.last else { return false }
        return actual.suffix(3).contains(anchor)
    }

    private static func nearestRightAnchor(_ expected: [String], appearsNear actual: [String]) -> Bool {
        guard let anchor = expected.first else { return false }
        return actual.prefix(3).contains(anchor)
    }
}
