import Foundation

extension StyleFormatter {
    /// Words that can follow a greeting without being a person's name ("hi again,", "hey sure,",
    /// "hi everyone,"). A closed class of fillers and group addressees, never a list of names.
    private static let notAName: Set<String> = [
        "all", "everyone", "everybody", "team", "folks", "guys", "sure", "yeah", "yep", "yes", "nope", "cool",
        "great", "awesome", "nice", "anyway", "actually", "honestly", "wait", "hmm", "oh", "ah", "alright",
        "right", "morning", "afternoon", "evening",
    ]

    /// "hi dev, ..." -> "Hi Dev, ...": the one word after a greeting that the existing greeting
    /// split accepts is an addressee, so it gets a capital. Greetings the split refuses ("hi all of
    /// you", "hi there"), longer addressees ("dear customer success team") and function words or
    /// group words are left as they are.
    static func capitalizingGreetingAddressee(_ text: String) -> String {
        // A greeting already alone on its first line ("Hi dev,\n\n...") is probed as if text followed.
        let head = text.prefix { $0 != "\n" }
        guard let split = splitGreeting(head.hasSuffix(",") ? head + " x" : String(head)) else { return text }
        let words = split.greeting.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, let first = words[1].first, first.isLowercase, words[1].allSatisfy(\.isLetter) else { return text }
        let lower = words[1].lowercased()
        guard !TokenLexicon.functionWords.contains(lower), !notAName.contains(lower) else { return text }
        return "\(words[0]) \(first.uppercased())\(words[1].dropFirst())" + text.dropFirst(split.greeting.count)
    }
}
