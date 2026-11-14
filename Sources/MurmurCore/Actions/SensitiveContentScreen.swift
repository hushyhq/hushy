import Foundation

/// Conservative heuristics for text that must never travel inside a proposal: passwords, API
/// keys and tokens, payment card numbers and security codes, bank account numbers, government
/// IDs and one-time codes. Used by `ProposalFields` on every free-text field of the `propose_*`
/// tools (titles, notes, bodies, message text, issue descriptions).
///
/// Deliberately narrow, so ordinary language passes: "reset your password" is fine, "my
/// password is hunter2" is not; a phone number or an order number is fine, a Luhn-valid 13–19
/// digit run is not. False negatives are acceptable here (the user still reviews every card);
/// false positives on everyday sentences are not.
public enum SensitiveContentScreen {
    public struct Finding: Equatable, Sendable {
        /// "a password", "a payment card number", … for the rejection message.
        public let description: String
    }

    /// The first thing in `text` that looks like a credential or payment detail, or nil.
    public static func finding(in text: String) -> Finding? {
        if let card = paymentCardNumber(in: text) { return card }
        for rule in rules {
            let matched = rule.caseInsensitive
                ? Regex.firstMatch(text, rule.pattern) != nil
                : !Regex.matchesCaseSensitive(text, rule.pattern).isEmpty
            if matched { return Finding(description: rule.description) }
        }
        return keywordValue(in: text)
    }

    private struct Rule: Sendable {
        let description: String
        let pattern: String
        var caseInsensitive = true
    }

    /// ICU patterns, compiled once through `RegexCache`.
    private static let rules: [Rule] = [
        // A credential keyword *followed by a value*: "password: hunter2", "the passphrase is
        // 'tr0ub4dor'". After "is", the value must be quoted or carry a digit/symbol so that
        // "the password is wrong" passes.
        Rule(description: "a password",
             pattern: #"\b(?:password|passcode|passphrase|passwd|pwd)\b\s*(?:[:=]\s*\S{4,}|is\s+(?:"[^"]{4,}"|'[^']{4,}'|“[^”]{4,}”|(?=\S*[\d!@#$%^&*_+=-])\S{6,}))"#),
        Rule(description: "a PIN",
             pattern: #"\bpin(?: code)?\b\s*(?:is|:|=)\s*\d{4,8}\b"#),
        Rule(description: "a card security code",
             pattern: #"\b(?:cvv2?|cvc|csc|security code)\b\s*(?:is|:|=|-)?\s*\d{3,4}\b"#),
        // "account number 12345678", "IBAN: GB82 …", "sort code is 40-47-84": the value must
        // contain a digit, so "account number for Dana" passes.
        Rule(description: "a bank account number",
             pattern: #"\b(?:(?:routing|account) (?:number|no\.?|#)|iban|sort code)\s*(?:is|:|=)?\s*(?=[A-Z0-9 -]*\d)[A-Z0-9][A-Z0-9 -]{5,33}\b"#),
        // IBAN shape: country code, two check digits, then 12–30 alphanumerics in groups of four.
        Rule(description: "a bank account number",
             pattern: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,4})?\b"#, caseInsensitive: false),
        Rule(description: "a Social Security number",
             pattern: #"\b\d{3}-\d{2}-\d{4}\b"#),
        Rule(description: "an API key or token",
             pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, caseInsensitive: false),
        Rule(description: "an API key or token",
             pattern: #"\b(?:sk|pk|rk)[-_](?:live|test)[-_][A-Za-z0-9]{8,}"#, caseInsensitive: false),
        Rule(description: "an API key or token",
             pattern: #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}"#, caseInsensitive: false),
        Rule(description: "an API key or token",
             pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, caseInsensitive: false),
        Rule(description: "an API key or token",
             pattern: #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, caseInsensitive: false),
        Rule(description: "an API key or token",
             pattern: #"\bAKIA[0-9A-Z]{16}\b"#, caseInsensitive: false),
        Rule(description: "an API key or token",
             pattern: #"\bBearer\s+[A-Za-z0-9._~+/-]{20,}"#, caseInsensitive: false),
        // "api key: abc123…", "the token is eyJhbGci…": the value must be long and carry a
        // digit, so "the token is expiring" passes.
        Rule(description: "an API key or token",
             pattern: #"\b(?:api[ _-]?key|secret(?: key)?|access[ _-]?(?:key|token)|auth(?:orization)? token|token)\b\s*(?:is|:|=)\s*(?=[A-Za-z0-9._~+/-]*\d)[A-Za-z0-9._~+/-]{12,}"#),
        Rule(description: "a one-time code",
             pattern: #"\b(?:one[- ]time (?:code|password)|verification code|otp|2fa code|two[- ]factor code|authentication code)\b\s*(?:is|:|=)?\s*\d{4,8}\b"#),
    ]

    // MARK: Keyword + value, whatever the value's shape

    /// A credential or ID keyword, then the value it introduces. After a password-like keyword
    /// the value must follow "is"/":"/"=" ("the password reset email" has none); an ID keyword may
    /// be followed by its number directly ("my ssn 208 71 4432"); a bare "code" only after a
    /// possessive or "the" ("the code is 4419", never "the error code is 404").
    private static let valueKeywords: [(description: String, pattern: String)] = [
        ("a password", #"\b(?:password|passcode|passphrase|passwd|pwd|login)\s*(?:is|:|=)\s+"#),
        ("a PIN", #"\bpin(?: code| number)?\s*(?:is|:|=)\s+"#),
        ("an access code",
         #"\b(?:(?:door|gate|garage|alarm|entry|access|security|lock|keypad|building|safe|unlock|lockbox|locker|wi-?fi)\s+code|(?:the|my|our|your) code)\s*(?:is|:|=)\s+"#),
        ("a government ID number",
         #"\b(?:social security number|ssn|aadhaa?r(?: number| card number)?|passport number|national id(?: number)?|tax id(?: number)?)\s*(?:is|:|=)?\s+"#),
        // "sk live 1234…": an API key as speech recognition writes it, with spaces for "_".
        ("an API key or token", #"\b(?:sk|pk|rk)\s+(?:live|test)\s+(?=[a-z0-9]*\d)"#),
    ]

    /// Words that start a *description* of the secret rather than the secret itself ("is wrong",
    /// "is at least 12 characters", "is on the router", "is the same as before").
    private static let descriptionWords: Set<String> = [
        "the", "a", "an", "my", "your", "our", "their", "his", "her", "its", "this", "that", "these", "those",
        "in", "on", "at", "to", "for", "of", "from", "with", "by", "about", "after", "before", "until", "since",
        "under", "over", "around", "near", "between", "per", "during", "not", "no", "never", "still", "also",
        "just", "only", "too", "very", "really", "so", "and", "or", "but", "if", "because", "when", "what",
        "why", "how", "which", "who", "is", "are", "was", "were", "be", "been", "being", "will", "would",
        "should", "can", "could", "may", "might", "must", "same", "different", "wrong", "correct", "right",
        "fine", "ok", "okay", "good", "bad", "weak", "strong", "easy", "hard", "simple", "long", "short", "new",
        "old", "temporary", "case", "something", "anything", "nothing", "somewhere", "here", "there", "down",
        "up", "out", "off", "broken", "ready", "due", "done", "version", "like", "um", "uh", "it", "one",
    ]
    /// A number followed by one of these measures the secret ("8 characters"), it isn't the secret.
    private static let unitWords: Set<String> = [
        "character", "characters", "chars", "digit", "digits", "letter", "letters", "word", "words", "number",
        "numbers", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks", "month", "months",
        "year", "years", "time", "times", "line", "lines", "percent", "am", "pm",
    ]
    /// How many words the value may run before its first digit ("orange kite 51").
    private static let wordsBeforeDigit = 3

    static func keywordValue(in text: String) -> Finding? {
        let nsText = text as NSString
        for keyword in valueKeywords {
            for match in Regex.matchesCaseSensitive(text, "(?i)" + keyword.pattern) {
                let rest = nsText.substring(from: match.range.location + match.range.length)
                if valueHasSecret(rest) { return Finding(description: keyword.description) }
            }
        }
        return nil
    }

    /// True when `rest` opens with a value: up to `wordsBeforeDigit` plain words, then a token
    /// with a digit that isn't a measurement.
    private static func valueHasSecret(_ rest: String) -> Bool {
        let tokens = rest.split(whereSeparator: \.isWhitespace).map { token in
            token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'“”()"))
        }
        for (index, token) in tokens.prefix(wordsBeforeDigit + 1).enumerated() {
            if token.contains(where: \.isNumber) {
                let next = index + 1 < tokens.count ? tokens[index + 1] : ""
                return !unitWords.contains(next)
            }
            // "is changed", "is expiring", "is probably": a description, not a value.
            let describes = token.count > 4 && (token.hasSuffix("ed") || token.hasSuffix("ing") || token.hasSuffix("ly"))
            if token.isEmpty || descriptionWords.contains(token) || describes {
                return false
            }
        }
        return false
    }

    // MARK: Payment cards

    /// Digits separated by at most one space or dash, as long as the run goes.
    private static let digitRun = #"\d(?:[ -]?\d)+"#

    /// A 13–19 digit run (spaces or dashes allowed) that passes the Luhn check. A longer run
    /// (a phone number next to an order number) is not a card.
    static func paymentCardNumber(in text: String) -> Finding? {
        let nsText = text as NSString
        for match in Regex.matchesCaseSensitive(text, digitRun) {
            let digits = nsText.substring(with: match.range).filter(\.isNumber)
            if (13...19).contains(digits.count), passesLuhn(digits) {
                return Finding(description: "a payment card number")
            }
        }
        return nil
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard let value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return sum % 10 == 0
    }
}
