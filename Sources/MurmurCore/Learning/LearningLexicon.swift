import Foundation

/// Ordinary English words for the learning loop and the boost guards: those `WordFrequency` grades at or above its
/// `ordinaryThreshold`. The grade comes from how often the word is written in lowercase, so a name that is almost
/// always capitalized ("Aaron", "Sarah") is *not* an ordinary word here: a user fixing "Sara" to "Sarah" is correcting
/// a name, which is exactly what we learn. A word that is both ("mark", "will", "grace") stays ordinary.
public enum LearningLexicon {
    /// True for an ordinary English word or a regular inflection of one ("voices", "invited").
    public static func isCommonWord(_ key: String) -> Bool {
        WordFrequency.shared.isOrdinary(key) || shortFunctionWords.contains(key)
    }

    /// Contractions and short words the table may lack.
    public static let shortFunctionWords: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "it's", "don't", "can't", "won't", "isn't", "aren't", "we're",
        "you're", "they're", "that's", "there's", "let's", "ok", "okay",
    ]
}
