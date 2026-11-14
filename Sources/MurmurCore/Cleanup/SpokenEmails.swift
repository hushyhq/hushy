import Foundation

/// "john at gmail dot com" and "John at gmail.com" are the address john@gmail.com. The ending is the evidence: an "at"
/// that is followed by a domain and one of the known top-level domains has no other reading, as "email me at noon" and
/// "meet me at the station dot" have (no domain, so they stay as spoken). `SpokenAddressNormalizer` writes the same
/// address in the rules draft; this is the same join for the text before and after the model, where the recogniser's
/// "John at gmail.com" and the model's "John at @gmail.com" are left.
///
/// A word before "at" is the mailbox only when it can be one: not a function word ("meet me at x.com", "you at x.com"),
/// not a verb that takes "at" ("look at gmail dot com"), and, when the domain is written rather than spoken and the word
/// is an ordinary English word, only at a mail provider's domain ("sales at gmail.com" is sales@gmail.com; "sales at
/// acme.com" is left, for it can be a place).
enum SpokenEmails {
    static func apply(_ text: String) -> String {
        guard text.range(of: "at", options: .caseInsensitive) != nil,
              let regex = RegexCache.compiled(pattern, caseInsensitive: true) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: output),
                  let local = Range(match.range(at: 1), in: output).map({ String(output[$0]) }),
                  let domain = Range(match.range(at: 2), in: output).map({ String(output[$0]) }),
                  isMailbox(local, domain: domain) else { continue }
            let written = domain.replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: [.regularExpression, .caseInsensitive])
            output.replaceSubrange(whole, with: (local + "@" + written).lowercased())
        }
        return output
    }

    private static let separator = "(?:\\s+dot\\s+|\\.)"
    private static let pattern = "(?<!\\S)([A-Za-z0-9](?:[A-Za-z0-9._%+-]*[A-Za-z0-9])?)\\s+at\\s+@?"
        + "(\(SpokenAddressNormalizer.label)(?:\(separator)\(SpokenAddressNormalizer.label))*\(separator)\(SpokenAddressNormalizer.tld))"

    private static func isMailbox(_ local: String, domain: String) -> Bool {
        let word = local.lowercased()
        guard word.count >= 2, !TokenLexicon.functionWords.contains(word), !verbsTakingAt.contains(word) else { return false }
        // The speaker said "dot": the ending is spoken as an address, whatever the mailbox is called ("maria", "sales").
        let host = domain.lowercased().replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: .regularExpression)
        if host == domain.lowercased(), BoostGuard.isEnglishWord(word, in: BoostGuard.systemWords), !word.contains(where: \.isNumber) {
            return mailProviders.contains(host)
        }
        return true
    }

    private static let mailProviders: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "icloud.com",
        "me.com", "aol.com", "proton.me", "protonmail.com", "fastmail.com", "hey.com", "zoho.com",
    ]

    /// "look at", "arrive at", "stop at": the word before "at" is an action, not a mailbox.
    private static let verbsTakingAt: Set<String> = [
        "look", "looks", "looked", "looking", "stare", "glance", "arrive", "arrives", "arrived", "meet", "meets", "met",
        "stop", "stops", "stopped", "aim", "aimed", "laugh", "laughed", "point", "pointed", "shout", "yell", "work",
        "works", "worked", "working", "live", "lives", "lived", "shop", "shopped", "check", "checked", "stay", "stayed",
        "sit", "sat", "wait", "waited", "stand", "stood", "play", "played", "study", "studied", "talk", "talked",
        "start", "starts", "started", "begin", "begins", "begins", "ends", "ended", "available", "good", "bad", "great",
        "here", "there", "home", "now", "today", "tonight", "tomorrow", "once", "least", "most", "best", "worst",
    ]
}
