import Foundation

/// Product and app names an answer may write for a word the recogniser heard as something else ("figment" for Figma).
///
/// The names check (`CorrectionBound.unsaidNames`) refuses a capitalised word nobody said, and `SpokenNameRepair` lets
/// through only a close sound-alike. A recogniser often hears a product name as a longer ordinary word, "figment" for
/// "Figma", which no sound-alike rule should accept for any word. So this accepts it only for a name the person or Hushy
/// knows:
/// - the person's Dictionary terms and the names of their installed apps (`CleanupOptions.knownNames`);
/// - the built-in list: the AI products `AIProductNameFixer` spells, the writing apps Hushy knows (`KnownWritingApps`),
///   and a few work tools people name in dictation.
///
/// And only when, in addition:
/// - the name is one word of four letters or more and not an ordinary English word ("Slack", "Linear" and "Notion" are
///   words too, and a word is never turned into one);
/// - one or two spoken words in the same place, written together, start with the same letter and either are one or two
///   letters off the name ("figna"), or share its first four letters or more, up to at most its last letter, with at
///   most three letters more ("figment" holds "figm" of "Figma");
/// - the word before or after it is the same in what was said and in the answer.
enum KnownProductNames {
    /// Work tools people name in dictation that neither list above holds.
    private static let workTools = [
        "Figma", "GitHub", "GitLab", "Jira", "Confluence", "Trello", "Canva", "Dropbox", "Vercel", "Supabase", "Firebase",
        "Kubernetes", "Postgres", "PostgreSQL", "TypeScript", "JavaScript", "YouTube", "Spotify", "Raycast", "Hushy",
        "Gemini", "Copilot", "Perplexity", "Midjourney", "Anthropic", "OpenAI", "Airtable", "Zapier", "HubSpot",
        "Salesforce", "Calendly", "Grammarly",
    ]

    static let builtIn: [String] = AIProductNameFixer.productNames + KnownWritingApps.all.map(\.name) + workTools

    private static let minimumLetters = 4
    private static let longestSpan = 2
    private static let sharedPrefix = 4
    private static let extraLetters = 3

    /// True when the capitalised answer word `word` is a known name that stands where a spoken word that sounds like it stood.
    static func repairs(
        _ word: String, answer: String, draft: String, knownNames: [String], isOrdinaryWord: (String) -> Bool
    ) -> Bool {
        let name = letters(word)
        guard name.count >= minimumLetters, !isOrdinaryWord(name),
              (builtIn + knownNames).contains(where: { letters($0) == name }) else { return false }
        let answerTokens = tokens(answer), spoken = tokens(draft)
        for index in answerTokens.indices where answerTokens[index] == name {
            let before = index > 0 ? answerTokens[index - 1] : nil
            let after = index + 1 < answerTokens.count ? answerTokens[index + 1] : nil
            for start in spoken.indices {
                for length in 1...longestSpan where start + length <= spoken.count {
                    let heard = spoken[start..<start + length].joined()
                    guard heard != name, soundsLike(heard, name) else { continue }
                    let spokenBefore = start > 0 ? spoken[start - 1] : nil
                    let spokenAfter = start + length < spoken.count ? spoken[start + length] : nil
                    if (before != nil && before == spokenBefore) || (after != nil && after == spokenAfter) { return true }
                }
            }
        }
        return false
    }

    private static func soundsLike(_ heard: String, _ name: String) -> Bool {
        guard heard.first == name.first, heard.count >= minimumLetters else { return false }
        let allowed = name.count >= 8 ? 2 : 1
        if abs(heard.count - name.count) <= allowed, ContextSpellingFixer.levenshtein(heard, name) <= allowed { return true }
        let prefix = zip(heard, name).prefix { $0 == $1 }.count
        return prefix >= sharedPrefix && prefix >= name.count - 1 && heard.count - prefix <= extraLetters
    }

    private static func letters(_ text: String) -> String {
        String(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter(\.isLetter))
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { letters(String($0)) }.filter { !$0.isEmpty }
    }
}
