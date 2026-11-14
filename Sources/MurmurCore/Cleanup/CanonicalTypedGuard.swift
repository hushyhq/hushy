import Foundation

/// A typed number or code token is licensed only by the rules' reading of the words in the
/// draft. Keep this separate from the model's broad word-overlap allowance: digits embedded in
/// `2nd`, `2x`, `#2` or `2%` are still digits even when the draft has no numerals at all.
enum CanonicalTypedGuard {
    private static let monthsPattern = InverseTextNormalizer.months.map(Regex.escape).joined(separator: "|")
    private static let ordinalsPattern = InverseTextNormalizer.ordinalWords.keys.map(Regex.escape).joined(separator: "|")
    private static let digitWordsPattern = InverseTextNormalizer.allDigitWords.map(Regex.escape).joined(separator: "|")
    private static let determinerPattern = CodeSymbolWords.determiners.map(Regex.escape).joined(separator: "|")
    private static let monthOrdinalPattern = "\\b(\(monthsPattern))\\s+(\(ordinalsPattern))\\b"
    private static let digitWordPattern = "\\b([A-Za-z]+)\\s+(\(digitWordsPattern))\\b"
    private static let determinerOrdinalPattern = "\\b(\(determinerPattern))\\s+(\(ordinalsPattern))\\b"
    static func needsWork(answer: String, draft: String) -> Bool {
        answer.contains(where: \.isNumber) || draft.contains(where: \.isNumber)
            || CodeTokenGuard.tokens(in: answer).contains(where: isTechnical)
            || CodeTokenGuard.tokens(in: draft).contains(where: isTechnical)
    }

    static func canonicalDraft(_ draft: String, answer: String? = nil) -> String {
        var text = TokenRewrite.replace(draft, pattern: monthOrdinalPattern) { match in
            guard let month = match.group(1), let word = match.group(2),
                  let value = InverseTextNormalizer.ordinalWords[word.lowercased()]
            else { return nil }
            let written = "\(month) \(value)\(CompoundOrdinals.suffix(of: value))"
            if let answer, !answer.lowercased().contains(written.lowercased()) { return nil }
            return written
        }
        text = SpokenPathTokens.apply(InverseTextNormalizer.apply(text))
        text = TokenRewrite.replace(text, pattern: correctedClockPattern) { match in
            guard let firstHour = match.group(1), let firstMinute = match.group(2), let cues = match.group(3),
                  let lastHour = match.group(4), let lastMinute = match.group(5),
                  cues.split(whereSeparator: \.isWhitespace).allSatisfy({ ModelHints.correctionCues.contains(String($0).lowercased()) }),
                  let first = clock(firstHour, firstMinute), let last = clock(lastHour, lastMinute)
            else { return nil }
            return "\(match.group(0)?.split(separator: " ").first ?? "at") \(first) \(cues)\(last)"
        }
        // These two single-slot spellings use the same cardinal/ordinal value tables as ITN.
        // ITN leaves them as words for style reasons, while a model may choose the typed form.
        text = TokenRewrite.replace(text, pattern: #"\b([A-Za-z])\s+([A-Za-z]+)\b"#) { match in
            guard let letter = match.group(1), let word = match.group(2),
                  !TokenLexicon.functionWords.contains(letter.lowercased()),
                  let value = InverseTextNormalizer.parseCardinal(word), (0...9).contains(value)
            else { return nil }
            if let answer, !answer.lowercased().contains("\(letter.lowercased())\(value)") { return nil }
            return "\(letter)\(value)"
        }
        text = TokenRewrite.replace(text, pattern: determinerOrdinalPattern) { match in
            guard let determiner = match.group(1), let word = match.group(2),
                  let value = InverseTextNormalizer.ordinalWords[word.lowercased()]
            else { return nil }
            if let answer, !answer.lowercased().contains("\(value)\(CompoundOrdinals.suffix(of: value))") { return nil }
            return "\(determiner) \(value)\(CompoundOrdinals.suffix(of: value))"
        }
        if let answer {
            text = TokenRewrite.replace(text, pattern: digitWordPattern) { match in
                guard let lead = match.group(1), let word = match.group(2),
                      let value = InverseTextNormalizer.parseCardinal(word) else { return nil }
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: lead))\\s+\(value)\\b(?![:%A-Za-z0-9])"
                guard answer.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
                return "\(lead) \(value)"
            }
            for token in CodeTokenGuard.tokens(in: answer).filter(isTechnical) where exactlySpoken(token, in: text) {
                let phrase = NSRegularExpression.escapedPattern(for: spokenForm(of: token))
                text = text.replacingOccurrences(of: "(?<![A-Za-z0-9])\(phrase)(?![A-Za-z0-9])", with: token,
                                                 options: [.regularExpression, .caseInsensitive])
            }
        }
        return text
    }

    static func violation(answer: String, draft: String) -> String? {
        guard needsWork(answer: answer, draft: draft) else { return nil }
        let canonical = canonicalDraft(draft, answer: answer)
        if let match = Regex.firstMatch(canonical, "\\b\(InverseTextNormalizer.clockTimeCuePattern)\\s+(\\d+:\\d{2})\\s+((?:[A-Za-z]+\\s+){1,2})(\\d+:\\d{2})\\b"),
           let earlier = match.string(at: 1, in: canonical), let cues = match.string(at: 2, in: canonical),
           let later = match.string(at: 3, in: canonical),
           cues.split(whereSeparator: \.isWhitespace).allSatisfy({ ModelHints.correctionCues.contains(String($0).lowercased()) }),
           typedNumbers(in: answer).contains(earlier), !typedNumbers(in: answer).contains(later),
           !ModelHints.correctionCues.contains(where: { answer.lowercased().contains($0) }) {
            return "kept retracted number"
        }
        let sourceNumbers = typedNumbers(in: canonical)
        let answerNumbers = typedNumbers(in: answer)
        // The rules intentionally leave some spoken numbers as words. Compare the value of
        // every remaining typed number with the speaker's words, including joined suffixes.
        let spokenNumbers = SpokenNumberRuns(draft)
        for token in answerNumbers where !sourceNumbers.contains(token) {
            if !SpokenNumberRuns(token).isSaid(by: spokenNumbers) { return "changed digits" }
        }
        let sourceCode = CodeTokenGuard.tokens(in: canonical).filter(isTechnical)
        let answerCode = CodeTokenGuard.tokens(in: answer).filter(isTechnical)
        var cursor = 0
        for token in answerCode {
            if sourceCode.contains(token) {
                guard let index = sourceCode[cursor...].firstIndex(of: token) else { return "changed code-context text" }
                cursor = index + 1
            } else if !exactlySpoken(token, in: draft) && !joinedSpoken(token, in: draft) {
                return "changed code-context text"
            }
        }
        return nil
    }

    private static func isTechnical(_ token: String) -> Bool {
        token.contains("_") || token.contains("/") || token.contains(".")
    }

    private static func spokenForm(of token: String) -> String {
        token.lowercased().replacingOccurrences(of: "_", with: " underscore ")
            .replacingOccurrences(of: "/", with: " slash ")
            .replacingOccurrences(of: ".", with: " dot ")
    }

    private static func exactlySpoken(_ token: String, in draft: String) -> Bool {
        let phrase = NSRegularExpression.escapedPattern(for: spokenForm(of: token))
        return draft.range(of: "(?<![A-Za-z0-9])\(phrase)(?![A-Za-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func joinedSpoken(_ token: String, in draft: String) -> Bool {
        let pieces = token.lowercased().split(whereSeparator: { "._/".contains($0) }).map(String.init)
        guard pieces.count > 1, pieces.allSatisfy({ !$0.isEmpty }) else { return false }
        let join = #"(?:\s+(?:dot|slash|underscore)\s+|\s+|[._/])"#
        let pattern = "(?<![A-Za-z0-9])" + pieces.map(NSRegularExpression.escapedPattern).joined(separator: join) + "(?![A-Za-z0-9])"
        return draft.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func resolvedClockDraft(_ draft: String, answer: String) -> String? {
        let matches = Regex.matches(draft, correctedClockPattern)
        guard matches.count == 1, let match = matches.first,
              let firstHour = match.string(at: 1, in: draft), let firstMinute = match.string(at: 2, in: draft),
              let cues = match.string(at: 3, in: draft), let lastHour = match.string(at: 4, in: draft),
              let lastMinute = match.string(at: 5, in: draft),
              cues.split(whereSeparator: \.isWhitespace).allSatisfy({ ModelHints.correctionCues.contains(String($0).lowercased()) }),
              let first = clock(firstHour, firstMinute), let last = clock(lastHour, lastMinute),
              typedNumbers(in: answer).contains(last), !typedNumbers(in: answer).contains(first),
              CorrectionBound.violation(answer: answer, draft: draft) == nil
        else { return nil }
        let lead = match.string(at: 0, in: draft)?.split(separator: " ").first.map(String.init) ?? "at"
        let replaced = TokenRewrite.replace(draft, pattern: correctedClockPattern) { _ in "\(lead) \(last)" }
        guard let range = replaced.range(of: "\(lead) \(last)") else { return nil }
        let suffix = String(replaced[range.upperBound...])
        let echoPattern = #"^\s+([A-Za-z]+)\s+([A-Za-z]+)\s+([A-Za-z]+)\s+([A-Za-z]+)\b"#
        // Only a complete anaphoric echo can be removed. Another subject, a negation, or
        // trailing content may be a separate assertion even when it names the same time.
        guard let echo = Regex.firstMatch(suffix, echoPattern),
              let subject = echo.string(at: 1, in: suffix), let copula = echo.string(at: 2, in: suffix),
              let hour = echo.string(at: 3, in: suffix), let minute = echo.string(at: 4, in: suffix),
              subject.lowercased() == "it", RestartedFrame.copulas.contains(copula.lowercased()),
              clock(hour, minute) == last, let echoRange = Range(echo.range, in: suffix),
              suffix[echoRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
        else { return replaced }
        return String(replaced[..<range.upperBound]) + suffix.replacingCharacters(in: echoRange, with: "")
    }

    private static let correctedClockPattern = "\\b\(InverseTextNormalizer.clockTimeCuePattern)\\s+([A-Za-z]+)\\s+([A-Za-z]+)\\s+((?:[A-Za-z]+\\s+){1,2})([A-Za-z]+)\\s+([A-Za-z]+)\\b"

    private static func clock(_ hourWord: String, _ minuteWord: String) -> String? {
        guard let hour = InverseTextNormalizer.parseCardinal(hourWord), (1...12).contains(hour),
              let minute = InverseTextNormalizer.parseCardinal(minuteWord), (0...59).contains(minute)
        else { return nil }
        return String(format: "%d:%02d", hour, minute)
    }

    private static func typedNumbers(in text: String) -> [String] {
        Regex.matches(text, #"(?<![\p{L}\p{N}])[#-]?[\p{L}\p{N}]+(?:[.:/_%-][\p{L}\p{N}]+)*%?(?![\p{L}\p{N}])"#)
            .compactMap { $0.string(at: 0, in: text) }
            .filter { $0.contains(where: \.isNumber) }.map { $0.lowercased() }
    }
}
