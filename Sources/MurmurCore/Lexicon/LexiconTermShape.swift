import Foundation

/// Which personal-lexicon terms may reach the recogniser: names and code-like tokens only, never an ordinary word
/// (the 2026-10-24 regression where an on-screen "text" turned a spoken "next" into "Next").
///
/// This is the lexicon's one copy of the rule. It builds on `ScreenBoostPolicy.shouldBoost` (ordinary English,
/// UI labels, length) and adds the shape test. It is deliberately not folded into `ScreenTermShape` (integration
/// 2026-11-11): the screen filter caps names at three words, needs every word capitalized, and treats "3pm" as a
/// quantity, while the lexicon keeps particles and suffixes ("Kevin de Bruyne", "Jr."), lowercase coinages
/// ("kubectl") and dotted names. Folding them changes what either path boosts and needs its own accuracy-v1 run.
public enum LexiconTermShape {
    /// Lowercase joiners inside a person's name ("Kevin de Bruyne", "Ruud van Nistelrooy").
    static let nameParticles: Set<String> = ["de", "da", "di", "del", "der", "van", "von", "la", "le", "du", "bin", "al"]
    /// Name suffixes that are fine as they are ("Jr.", "III").
    static let nameSuffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]

    public static func isBoostable(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ScreenBoostPolicy.shouldBoost(trimmed) else { return false }
        return isNameLike(trimmed) || isCodeLike(trimmed) || isUnknownWord(trimmed)
    }

    /// Every word capitalized (allowing name particles and suffixes) and at least one word that is not ordinary English.
    static func isNameLike(_ term: String) -> Bool {
        let words = term.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        var hasRareWord = false
        for word in words {
            let key = word.lowercased()
            if nameSuffixes.contains(key) { continue }
            if nameParticles.contains(key), words.count > 1 { continue }
            guard let first = word.first, first.isUppercase else { return false }
            let core = key.filter { $0.isLetter }
            if !core.isEmpty, !LearningLexicon.isCommonWord(core) { hasRareWord = true }
        }
        return hasRareWord
    }

    /// One token that reads as code or an identifier: a digit next to letters (rl-v9, TRY-95), an underscore,
    /// a dot between letters (tryhushy.com), or a capital inside the word (useEffect, iPhone).
    static func isCodeLike(_ term: String) -> Bool {
        guard !term.contains(where: \.isWhitespace), term.contains(where: \.isLetter) else { return false }
        if term.contains("_") { return true }
        if term.contains(where: \.isNumber) { return true }
        if term.contains("."), term.split(separator: ".").count >= 2 { return true }
        return term.dropFirst().contains(where: \.isUppercase) && term.contains(where: \.isLowercase)
    }

    /// A lowercase coinage no English list knows ("kubectl"), which cannot overwrite a word a person said.
    static func isUnknownWord(_ term: String) -> Bool {
        guard !term.contains(where: \.isWhitespace), term.count >= 4, term.allSatisfy(\.isLetter) else { return false }
        return !WordFrequency.shared.isKnown(term)
    }

    /// What kind of term a surface reads as, for a source that does not say.
    static func kind(of term: String) -> PersonalTerm.Kind {
        if isCodeLike(term) { return .identifier }
        if isNameLike(term) { return term.contains(where: \.isWhitespace) ? .person : .term }
        return .term
    }
}
