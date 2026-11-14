import Foundation

/// Temporarily masks address-shaped spans only when local wording explicitly treats them as
/// literal text. Nearby URLs in the same sentence remain eligible for normal normalization.
enum LiteralAddressContext {
    struct MaskedText {
        let text: String
        private let replacements: [(token: String, original: String)]

        init(text: String, replacements: [(token: String, original: String)]) {
            self.text = text
            self.replacements = replacements
        }

        func restoring(in text: String) -> String {
            replacements.reduce(text) { result, item in
                result.replacingOccurrences(of: item.token, with: item.original)
            }
        }
    }

    static func mask(in text: String, addressPatterns: [String]) -> MaskedText {
        let source = text as NSString
        let candidates = addressPatterns.flatMap { matches($0, in: text) }
        let mergedCandidates = mergeOverlapping(candidates)
        let quotedRanges = quoteContents(in: text)
        let literalRanges = mergedCandidates.filter { range in
            quotedRanges.contains { NSLocationInRange(range.location, $0) && NSMaxRange(range) <= NSMaxRange($0) }
                || hasExplicitLiteralFraming(range, in: source)
        }

        var nonce = 0
        var marker = "\u{F0000}ADDR\(nonce)_"
        while text.contains(marker) {
            nonce += 1
            marker = "\u{F0000}ADDR\(nonce)_"
        }

        var masked = text
        var replacements: [(token: String, original: String)] = []
        for (index, range) in literalRanges.enumerated().reversed() {
            let token = "\(marker)\(index)\u{F0001}"
            guard let stringRange = Range(range, in: masked) else { continue }
            replacements.append((token, source.substring(with: range)))
            masked.replaceSubrange(stringRange, with: token)
        }
        return MaskedText(text: masked, replacements: replacements)
    }

    private static func hasExplicitLiteralFraming(_ range: NSRange, in text: NSString) -> Bool {
        let prefixStart = max(0, range.location - 160)
        let prefix = text.substring(with: NSRange(location: prefixStart, length: range.location - prefixStart))
        let suffixEnd = min(text.length, NSMaxRange(range) + 120)
        let suffix = text.substring(with: NSRange(location: NSMaxRange(range), length: suffixEnd - NSMaxRange(range)))
        let literalLead = #"(?is)\b(?:say|says|said|pronounce|pronounces|pronounced)\s+(?:(?:the|a|this|following|word|phrase|domain|address|url|website|web)\s+){0,4}$"#
        let literalTail = #"(?is)^\s*(?:,\s*)?(?:(?:slash\s+[A-Za-z0-9-]+)\s+)*(?:out\s+loud|as\s+(?:(?:individual|spoken)\s+)?words|literally|verbatim)\b"#
        return firstMatch(prefix, pattern: literalLead) != nil && firstMatch(suffix, pattern: literalTail) != nil
    }

    private static func quoteContents(in text: String) -> [NSRange] {
        let patterns = [
            #"(?s)(?<![A-Za-z0-9])"([^"\n]{1,240})"(?![A-Za-z0-9])"#,
            #"(?s)(?<![A-Za-z0-9])'([^'\n]{1,240})'(?![A-Za-z0-9])"#,
            #"(?s)`([^`\n]{1,240})`"#,
            #"(?s)“([^”\n]{1,240})”"#,
            #"(?s)‘([^’\n]{1,240})’"#,
        ]
        return patterns.flatMap { pattern -> [NSRange] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                let capture = match.range(at: 1)
                return capture.location == NSNotFound ? nil : capture
            }
        }
    }

    private static func mergeOverlapping(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            guard let last = result.last, range.location <= NSMaxRange(last) else {
                result.append(range)
                continue
            }
            let end = max(NSMaxRange(last), NSMaxRange(range))
            result[result.count - 1] = NSRange(location: last.location, length: end - last.location)
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private static func firstMatch(_ text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
