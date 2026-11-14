import Foundation

/// Pull-request and ticket references: "pr 482" -> "PR 482", "eng 1423" -> "ENG-1423". Part of
/// `SpokenTechnicalTokens`. The ticket rule needs evidence that the word is a project key: the
/// same key in the browser tab title, or a ticket word right before an unfamiliar (non-dictionary)
/// key. A bare "word number" is a quantity or a name, so it stays.
enum SpokenTrackerTokens {
    static func apply(_ text: String, context: TechnicalTokenContext) -> String {
        let keys = titleKeys(context.windowTitle)
        let withPRs = TokenRewrite.replace(text, pattern: prPattern, pullRequest)
        return TokenRewrite.replace(withPRs, pattern: ticketPattern) { ticket($0, titleKeys: keys) }
    }

    // MARK: Pull requests

    private static let prPattern = #"(?<![\w#-])pr\s+(\d{1,6})(?![\w%]|[.:]\d)"#

    private static func pullRequest(_ match: TokenMatch) -> String? {
        guard let number = match.group(1) else { return nil }
        if let next = match.wordsAfter(1).first, TokenLexicon.quantityWords.contains(next) { return nil }
        return "PR " + number
    }

    // MARK: Tickets

    private static let ticketPattern = #"(?<![\w#-])([A-Za-z]{2,6})\s+(\d{3,6})(?![\w%-]|[.:]\d)"#
    private static let titleKeyPattern = #"(?<![A-Za-z0-9])([A-Z][A-Z0-9]{1,5})-\d{1,6}(?![A-Za-z0-9])"#
    private static let ticketWords: Set<String> = ["ticket", "tickets", "issue", "jira", "bug", "epic", "story", "incident"]
    private static let ticketNumberWords: Set<String> = ["number", "id", "no"]

    /// Project keys that appear in the tab title ("ENG-1510 Cache stampede - Linear" -> ENG).
    private static func titleKeys(_ title: String?) -> Set<String> {
        guard let title, let regex = RegexCache.compiled(titleKeyPattern, caseInsensitive: false) else { return [] }
        let matches = regex.matches(in: title, range: NSRange(title.startIndex..., in: title))
        return Set(matches.compactMap { Range($0.range(at: 1), in: title).map { String(title[$0]) } })
    }

    private static func ticket(_ match: TokenMatch, titleKeys: Set<String>) -> String? {
        guard let key = match.group(1), let number = match.group(2) else { return nil }
        let lower = key.lowercased(), upper = key.uppercased()
        if let next = match.wordsAfter(1).first, TokenLexicon.quantityWords.contains(next) { return nil }
        guard !TokenLexicon.functionWords.contains(lower), !TokenLexicon.numberWords.contains(lower) else { return nil }
        if titleKeys.contains(upper) { return "\(upper)-\(number)" }
        let before = match.wordsBefore(2)
        let afterTicketWord = before.last.map(ticketWords.contains) == true
            || (before.count == 2 && ticketNumberWords.contains(before[1]) && ticketWords.contains(before[0]))
        guard afterTicketWord, !BoostGuard.isEnglishWord(lower, in: BoostGuard.systemWords) else { return nil }
        return "\(upper)-\(number)"
    }
}
