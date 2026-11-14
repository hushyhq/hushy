import Foundation

/// Capitalization English always wants but a lowercase, unpunctuated ASR transcript lacks: the
/// pronoun "I" (and "I'm", "I've", "I'll", "I'd"), and weekday and month names. Sentence starts
/// are handled separately by `Punctuation.tidy`.
///
/// English-only (Italian "i" is an article), and never run on a code context, where casing is
/// literal. "march" and "may" are only capitalized directly before a number ("march 3rd", "may
/// 12"), since both are also ordinary words.
public enum EnglishCasing {
    private static let alwaysCapitalized: [String: String] = [
        "monday": "Monday", "tuesday": "Tuesday", "wednesday": "Wednesday", "thursday": "Thursday",
        "friday": "Friday", "saturday": "Saturday", "sunday": "Sunday",
        "january": "January", "february": "February", "april": "April", "june": "June", "july": "July",
        "august": "August", "september": "September", "october": "October", "november": "November",
        "december": "December",
    ]

    public static func apply(_ text: String) -> String {
        var out = Regex.replaceCaseSensitive(text, "(?<![\\w'\u{2019}./@#-])i(?=(?:['\u{2019}](?:m|ve|ll|d|s))?(?![\\w'\u{2019}@-])(?!\\.\\w))", with: "I")
        for (word, capitalized) in alwaysCapitalized {
            out = Regex.replaceCaseSensitive(out, "(?<![\\w./@#-])\(word)(?![\\w@-])", with: capitalized)
        }
        out = Regex.replaceCaseSensitive(out, "(?<![\\w./@#-])march(?=\\s+\\d)", with: "March")
        out = Regex.replaceCaseSensitive(out, "(?<![\\w./@#-])may(?=\\s+\\d)", with: "May")
        return out
    }
}
