import Foundation

/// Conservative address recognition in the rules draft. The TLD is the evidence that a run of
/// labels is an address; ordinary uses of "dot", sentence punctuation, and explicit literal
/// mentions are left alone.
public enum SpokenAddressNormalizer {
    public static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "ai", "app", "dev", "co", "us", "in", "uk",
        "edu", "gov", "me", "xyz", "so", "sh", "gg", "info", "biz", "tech"
    ]

    static let tld = "(?:co\\.uk|com|org|net|io|ai|app|dev|co|us|in|uk|edu|gov|me|xyz|so|sh|gg|info|biz|tech)(?![A-Za-z0-9-])"
    static let label = "[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*"

    public static func protectedAddresses(in text: String) -> [String] {
        let pattern = "(?i)(?:[A-Za-z0-9._%+-]+@)?\(label)(?:\\.\(label))*\\.\(tld)(?:/[A-Za-z0-9-]+)*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        }
    }

    /// True when `text` is one web address or email and nothing else (a subdomain and a path are part of it).
    /// Same labels and endings as the rest of this type, so there is no second definition of "an address".
    public static func isOnlyAnAddress(_ text: String) -> Bool {
        let web = "(?:(?:https?|ftp)://)?(?:www\\.)?\(label)(?:\\.\(label))*\\.\(tld)(?:/[A-Za-z0-9-]+)*/?"
        let email = "[A-Za-z0-9._%+-]+@\(label)(?:\\.\(label))*\\.\(tld)"
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(web)|\(email))$", options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func changedAddress(answer: String, draft: String) -> Bool {
        let answerLower = answer.lowercased()
        return protectedAddresses(in: draft).contains { !answerLower.contains($0) }
    }

    /// Code contexts keep literal punctuation; spoken domains still normalize there.
    public static func apply(_ input: String, repairPunctuation: Bool = true) -> String {
        let spokenAddress = "(?i)\\b(?:https?\\s+colon\\s+slash\\s+slash\\s+)?(?:www\\s+(?:dot|\\.)\\s+)?(?:\(label)\\s+(?:dot|\\.)\\s+)+\(tld)\\b"
        let spokenEmail = "(?i)\\b[A-Za-z0-9][A-Za-z0-9._%+-]*\\s+at\\s+(?:\(label)\\s+(?:dot|\\.)\\s+)+\(tld)\\b"
        let writtenAddress = "(?i)\\b(?:(?:https?|ftp)://)?(?:www\\.)?\(label)(?:\\.\(label))*\\.\(tld)(?:/[A-Za-z0-9-]+)*"
        let writtenEmail = "(?i)\\b[A-Za-z0-9._%+-]+@\(label)(?:\\.\(label))*\\.\(tld)\\b"
        let literalMask = LiteralAddressContext.mask(
            in: input,
            addressPatterns: [spokenAddress, spokenEmail, writtenAddress, writtenEmail]
        )
        var text = literalMask.text
        text = replaceMatches(text, pattern: "(?i)\\btry(?:hashi|hushi|husshy)\\b(?=\\s*[.,]\\s*com\\b)") { _ in "tryhushy" }
        text = replaceMatches(text, pattern: "(?i)\\btry\\s+(?:hashi|hushi|husshy|hushy)\\b(?=\\s+(?:dot|[.,])\\s*com\\b)") { _ in "tryhushy" }
        text = replaceMatches(text, pattern: "(?i)\\b(?:hashi|hushi|husshy)\\b(?=\\s+app\\b)") { _ in "Hushy" }
        text = replaceMatches(text, pattern: "(?i)\\bw\\s+w\\s+w\\b(?=\\s+dot\\s+)") { _ in "www" }
        // An address that already ends in its top-level domain, followed by the speaker's own "dot com", is one address:
        // the spoken run below would read the written ending as a label and write it twice.
        let endingSaidAgain = "(?i)\\b\(label)(?:\\.\(label))*\\.(\(tld))\\s+(?:dot|\\.)\\s+\\1(?![A-Za-z0-9-])"
        text = replaceMatches(text, pattern: endingSaidAgain) { match in
            match.replacingOccurrences(of: "\\s+(?:dot|\\.)\\s+[A-Za-z0-9-]+$", with: "", options: .regularExpression)
        }
        // Restrict the spoken run to labels, so prose around it cannot be swallowed.
        let spoken = "(?i)\\b(?:\(label)\\s+(?:dot|\\.)\\s+)+\(tld)\\b"
        text = replaceMatches(text, pattern: spoken) { match in
            // In a code line "the dot in the corner" is a sentence: a determiner is never a domain label,
            // and "in" alone is too common a word to make it one. Prose keeps the old behaviour.
            if !repairPunctuation, startsWithDeterminer(match) { return match }
            return match.replacingOccurrences(of: "(?i)\\s+(?:dot|\\.)\\s+", with: ".", options: .regularExpression).lowercased()
        }
        // ASR often inserts a sentence-like comma or full stop before the final TLD. A lower-case
        // TLD may continue into path/text when it's not a common English word. Exclude ambiguous
        // word TLDs there: otherwise "complete, so don't" becomes the fictitious domain
        // "complete.so". Capitalized TLDs still need to end the address, which avoids treating
        // "startup. Co-founders" as `startup.co`.
        if repairPunctuation {
            let punctuated = "(?i)\\b\(label)[.,]\\s+(?:(?-i:(?![A-Z]))(?!(?:so|in|us|me|co)\\b)\(tld)\\b|\(tld)(?=\\s*(?:[.,!?;:/]|$)))"
                + "|\\b\(label),\\s*\(label)(?:\\.\(tld))\\b"
            text = replaceMatches(text, pattern: punctuated) { match in
                match.replacingOccurrences(of: "[.,]\\s*", with: ".", options: .regularExpression).lowercased()
            }
        }
        // A spoken email uses the same domain parser. Only an address-shaped suffix permits
        // "at" to become @; "email me at" remains prose.
        let email = "(?i)\\b([A-Za-z0-9][A-Za-z0-9._%+-]*)\\s+at\\s+(\(label)(?:\\.\(label))*\\.\(tld))\\b"
        text = replaceMatches(text, pattern: email) { match in
            match.replacingOccurrences(of: "(?i)\\s+at\\s+", with: "@", options: .regularExpression).lowercased()
        }
        let address = "(?i)\\b\(label)(?:\\.\(label))*\\.\(tld)\\b"
        text = replaceMatches(text, pattern: address) { $0.lowercased() }
        text = replaceMatches(text, pattern: "(?i)\\bhttps\\s+colon\\s+slash\\s+slash\\s+(?=\(address))") { _ in "https://" }
        // URL path commands are only interpreted immediately after an established domain.
        text = replaceMatches(text, pattern: "(?i)(?:\(address))(?:\\s+slash\\s+\(label))+") { match in
            match.replacingOccurrences(of: "(?i)\\s+slash\\s+", with: "/", options: .regularExpression)
        }
        return literalMask.restoring(in: text)
    }

    private static func startsWithDeterminer(_ match: String) -> Bool {
        let first = match.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        return CodeSymbolWords.determiners.contains(first)
    }

    private static func replaceMatches(_ text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
