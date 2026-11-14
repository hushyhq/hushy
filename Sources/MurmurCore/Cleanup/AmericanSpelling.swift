import Foundation

/// Optional en-US orthography: rewrites British spellings the recognizer emits ("colour",
/// "programme", "organisation", "cancelled") to American ones. Parakeet (every version we ship)
/// writes a British spelling about 15–21 times per 10,000 words on US benchmarks; Apple's
/// recognizers about once — see docs/product/US-ENGLISH-ACCURACY.md. WER normalisers fold
/// UK/US spelling, so this never shows up in a WER number, but a US user sees it.
///
/// Conservative by design (AGENTS rule 2: spelling only, never a different word):
/// - words both spellings are standard for in American English are left alone (`keepAsIs`:
///   "dialogue", "aesthetic", "disc", "omelette", …);
/// - a capitalised word in the middle of a sentence is treated as a name and left alone
///   ("Earl Grey", "Lincoln Centre"); sentence-initial capitals and ALL CAPS keep their case;
/// - off unless `CleanupOptions.americanSpelling` is set (default false).
public enum AmericanSpelling {
    /// Entries from the upstream list whose British-looking form is also standard (or preferred)
    /// in American usage, or where the "American" target is rare.
    public static let keepAsIs: Set<String> = [
        "aesthete", "aesthetes", "aesthetic", "aesthetically", "aesthetics",
        "analogue", "analogues", "dialogue", "dialogues", "disc", "discs",
        "omelette", "omelettes", "accoutrements", "gasses", "tabu",
    ]

    public static let map: [String: String] = BritishAmericanSpellings.map.filter { !keepAsIs.contains($0.key) }

    private static let word = try? NSRegularExpression(pattern: "[A-Za-z]+(?:'[A-Za-z]+)?")

    public static func apply(_ text: String) -> String {
        guard let word else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in word.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += replacement(for: token, sentenceStart: startsSentence(ns, before: match.range.location)) ?? token
            cursor = match.range.location + match.range.length
        }
        return out + ns.substring(from: cursor)
    }

    static func replacement(for token: String, sentenceStart: Bool) -> String? {
        let lower = token.lowercased()
        guard let american = map[lower] else { return nil }
        if token == lower { return american }
        if token == token.uppercased(), token.count > 1 { return american.uppercased() }
        // Capitalised: a name mid-sentence, a sentence opener otherwise.
        guard sentenceStart, token.first?.isUppercase == true, token.dropFirst() == lower.dropFirst() else { return nil }
        return american.prefix(1).uppercased() + american.dropFirst()
    }

    /// True when only whitespace, opening quotes/brackets and list markers separate `location`
    /// from the start of the text or from a sentence-ending mark or line break.
    static func startsSentence(_ text: NSString, before location: Int) -> Bool {
        var index = location - 1
        while index >= 0 {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            if "\n.!?:".unicodeScalars.contains(scalar) { return true }
            if !(CharacterSet.whitespaces.contains(scalar) || "\"'“‘([-•*".unicodeScalars.contains(scalar)) { return false }
            index -= 1
        }
        return true
    }
}
