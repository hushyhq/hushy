import Foundation

/// A conservative comparison draft for an explicit correction in the intent transcript.
/// Only a repeated opening or a later value of the same kind identifies the abandoned span.
enum IntentCorrection {
    struct Resolved {
        let reference: String
        let retracted: String
    }

    static func resolve(_ raw: String) -> Resolved? {
        let cues = ModelHints.correctionCues + ["my mistake", "my bad", "hold on", "no wait", "scratch that"]
        let pattern = "(?i)(?:[,;—–]\\s*|\\s+)(?:" + cues
            .sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            + ")\\b[,;]?\\s*"
        for marker in Regex.matches(raw, pattern) {
            guard let range = Range(marker.range, in: raw) else { continue }
            let before = Token.split(String(raw[..<range.lowerBound]))
            let after = Token.split(String(raw[range.upperBound...]))
            if let resolved = resolve(before: before, after: after) { return resolved }
        }
        return nil
    }

    private static func resolve(before: [Token], after: [Token]) -> Resolved? {
        guard before.count >= 2, !after.isEmpty else { return nil }
        let repeated = min(2, min(before.count, after.count))
        if repeated == 2 && zip(before.prefix(repeated), after.prefix(repeated)).allSatisfy({ $0.0.normalized == $0.1.normalized }),
           before.map(\.normalized) != after.map(\.normalized) {
            return Resolved(reference: after.map(\.text).joined(separator: " "), retracted: before.map(\.text).joined(separator: " "))
        }
        guard let replacement = after.first, let kind = replacement.kind, kind != .word,
              let old = before.lastIndex(where: { $0.kind?.isCompatible(with: kind) == true }), old > 0,
              before[old].normalized != replacement.normalized else { return nil }
        let tail = Array(before.dropFirst(old + 1))
        let afterTail = Array(after.dropFirst())
        var overlap = 0
        for (earlier, later) in zip(tail, afterTail) {
            guard earlier.normalized == later.normalized else { break }
            overlap += 1
        }
        let reference = (before[..<old].map(\.text) + after.map(\.text) + tail.dropFirst(overlap).map(\.text))
            .joined(separator: " ")
        return Resolved(reference: reference, retracted: before[old..<(old + overlap + 1)].map(\.text).joined(separator: " "))
    }

    static func violation(answer: String, raw: String, resolved: Resolved) -> String? {
        if let reason = CorrectionBound.violation(answer: answer, draft: raw) { return reason }
        if let reason = CorrectionBound.violation(answer: answer, draft: resolved.reference) { return reason }
        if !SpokenNumberRuns(resolved.reference).isSaid(by: SpokenNumberRuns(answer)) { return "dropped number" }
        let retracted = OutputGuard.words(resolved.retracted)
        let active = Set(OutputGuard.words(resolved.reference))
        let answerWords = Set(OutputGuard.words(answer))
        if retracted.contains(where: { !active.contains($0) && answerWords.contains($0) }) {
            return "kept retracted item"
        }
        return nil
    }
}
