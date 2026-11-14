import Foundation

/// "Did you mean…": when `best` is not sure, how close is anything? `resolve` keeps `best`'s
/// answer exactly when it has one; otherwise it ranks the installed apps by how much they look
/// or sound like what was heard and offers the few closest, or says nothing is close.
///
/// General rules only: every app is scored the same way (spelling, shared start, shared
/// consonants), against its whole name and against each word of it. Nothing here knows an
/// app's name or a particular mishearing.
extension AppNameMatcher {
    public enum Resolution: Equatable, Sendable {
        /// `best` is sure: open it, as always.
        case confident(Candidate)
        /// Not sure, but these (closest first, at most `maxSuggestions`) are near. The user picks.
        case suggestions([Candidate])
        /// Nothing installed resembles what was heard.
        case nothingClose
    }

    /// The most apps offered at once.
    public static let maxSuggestions = 3
    /// The least similarity (0…1, 1 = identical) worth offering. Three letters one edit apart
    /// score 0.67; two edits apart on five letters score 0.6; one edit on two letters, 0.5.
    public static let suggestionFloor = 0.5
    /// Fewer letters than this say too little to suggest anything from.
    public static let minimumLettersToSuggest = 2
    /// A heard word that starts an app's name (at least `minimumPrefixLetters` of it).
    static let prefixScore = 0.75
    static let minimumPrefixLetters = 3
    /// A match on one word of a longer name counts for a little less than the whole name.
    static let wordDiscount = 0.9
    static let minimumWordLetters = 3
    /// Matching consonants is weaker evidence than matching letters; it needs enough of them.
    static let soundDiscount = 0.9
    static let minimumSoundLetters = 3

    /// The ranked answer for `spoken` among the installed apps.
    public static func resolve(spoken: String, among candidates: [Candidate]) -> Resolution {
        if let match = best(spoken: spoken, among: candidates) { return .confident(match) }
        let wanted = normalize(spoken)
        guard wanted.count >= minimumLettersToSuggest else { return .nothingClose }
        let scored = usableCandidates(candidates).compactMap { candidate -> (candidate: Candidate, score: Double)? in
            let score = similarity(of: wanted, to: candidate)
            return score >= suggestionFloor ? (candidate, score) : nil
        }
        let ordered = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.name.count != rhs.candidate.name.count { return lhs.candidate.name.count < rhs.candidate.name.count }
            return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name) == .orderedAscending
        }
        var seen = Set<String>()
        let unique = ordered.map(\.candidate).filter { seen.insert(normalize($0.name)).inserted }
        return unique.isEmpty ? .nothingClose : .suggestions(Array(unique.prefix(maxSuggestions)))
    }

    /// 0…1: the best of how alike `wanted` is to the whole name or to any one word of it.
    static func similarity(of wanted: String, to candidate: Candidate) -> Double {
        let whole = normalize(candidate.name)
        let words = spokenForm(candidate.name).split(separator: " ").map(String.init)
            .filter { $0.count >= minimumWordLetters && $0 != whole }
        let wholeScore = score(wanted, against: whole)
        let wordScore = words.map { score(wanted, against: $0) * wordDiscount }.max() ?? 0
        return max(wholeScore, wordScore)
    }

    private static func score(_ wanted: String, against name: String) -> Double {
        guard !name.isEmpty else { return 0 }
        var result = closeness(wanted, name)
        if wanted.count >= minimumPrefixLetters, name.hasPrefix(wanted) { result = max(result, prefixScore) }
        let heardSound = skeleton(wanted), nameSound = skeleton(name)
        if heardSound.count >= minimumSoundLetters, nameSound.count >= minimumSoundLetters {
            result = max(result, closeness(heardSound, nameSound) * soundDiscount)
        }
        return result
    }

    /// 1 for identical strings, falling by one edit's share of the longer one.
    private static func closeness(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(editDistance(a, b)) / Double(longest)
    }
}
