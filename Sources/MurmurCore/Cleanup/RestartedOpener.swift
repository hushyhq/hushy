import Foundation

/// A clause started twice with the same opener: "so the report is so the issue is that the queue
/// is stale" -> "so the issue is that the queue is stale". The speaker opened "so the", got as far
/// as a noun and a bare "is", and began again with "so the" and a new noun and "is".
///
/// Narrow on purpose, because "so" is also the purpose word ("this is so the team can plan") and an
/// intensifier ("is so simple"). It fires only when all of these hold: the same "so" + article or
/// demonstrative opens both halves; the first half is one to three words ending in a bare "is",
/// "was", "are" or "were" (a clause that never got its complement); and the second half is again
/// one to two words and a copula followed by "that", "because" or "to" (the complementizer a
/// restarted frame lands on). A purpose clause ("so the plan is so the team can plan") has a modal
/// or a plain verb there instead, and is left alone.
enum RestartedOpener {
    private static let determiners = "(?:the|a|an|this|that|my|our|their|his|her|its)"
    private static let copula = "(?:is|was|are|were)"
    private static let word = "[A-Za-z][A-Za-z'\u{2019}-]*"
    private static let pattern =
        "\\bso\\s+(\(determiners))\\s+(?:\(word)\\s+){1,3}?\(copula)\\s+so\\s+\\1\\s+" +
        "((?:\(word)\\s+){1,2}?\(copula))\\s+(?=(?:that|because|to)\\b)"

    static func apply(_ text: String) -> String {
        Regex.replace(text, pattern) { whole, groups in
            guard groups.count > 2 else { return whole }
            let opener = String(whole.prefix(2))
            return "\(opener) \(groups[1]) \(groups[2]) "
        }
    }
}
