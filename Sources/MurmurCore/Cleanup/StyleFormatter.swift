import Foundation

/// How dictation reads in a given kind of app. Styles only change formatting — capitals,
/// punctuation, line breaks — never the words the user said.
public enum WritingStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case formal, casual, veryCasual, excited

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .formal: "Formal."
        case .casual: "Casual"
        case .veryCasual: "very casual"
        case .excited: "Excited!"
        }
    }

    public var detail: String {
        switch self {
        case .formal: "Caps + punctuation"
        case .casual: "Caps + less punctuation"
        case .veryCasual: "No caps + less punctuation"
        case .excited: "More exclamations"
        }
    }
}

/// The kinds of places people write, each with its own style.
public enum StyleContext: String, CaseIterable, Codable, Sendable, Identifiable {
    case personalMessages, workMessages, email, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .personalMessages: "Personal messages"
        case .workMessages: "Work messages"
        case .email: "Email"
        case .other: "Everything else"
        }
    }

    public var symbol: String {
        switch self {
        case .personalMessages: "bubble.left.and.bubble.right"
        case .workMessages: "briefcase"
        case .email: "envelope"
        case .other: "square.grid.2x2"
        }
    }

    /// Which styles make sense here.
    public var styles: [WritingStyle] {
        switch self {
        case .personalMessages: [.formal, .casual, .veryCasual]
        case .workMessages, .email, .other: [.formal, .casual, .excited]
        }
    }

    public var defaultStyle: WritingStyle {
        switch self {
        case .personalMessages: .casual
        default: .formal
        }
    }

    /// The same sentence in each style, for the picker.
    public var sample: String {
        switch self {
        case .personalMessages: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .workMessages: "Hey, if you're free, let's chat about the great results."
        case .email: "Hi Alex, it was great talking with you today. Looking forward to our next chat. Best, Mary"
        case .other: "So far, I am enjoying the new workout routine. I am excited for tomorrow's workout, especially after a full night of rest."
        }
    }

    /// Well-known apps for this context (shown on the Style page; kept in sync by tests).
    public var representativeApps: [String] {
        switch self {
        case .personalMessages: ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord", "org.whispersystems.signal-desktop"]
        case .workMessages: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.linear"]
        case .email: ["com.apple.mail", "com.superhuman.electron", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.mimestream.Mimestream"]
        case .other: ["com.apple.Notes", "notion.id", "com.openai.chat", "com.anthropic.claudefordesktop", "md.obsidian"]
        }
    }

    /// Code editors and terminals are never styled: punctuation there is syntax.
    public static func from(_ category: AppCategory) -> StyleContext? {
        switch category {
        case .personalMessages: .personalMessages
        case .workMessages: .workMessages
        case .email: .email
        case .code: nil
        case .aiPrompts, .documents, .other: .other
        }
    }
}

public enum StyleFormatter {
    public static func apply(_ style: WritingStyle, to text: String, in context: StyleContext) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Lists keep their structure untouched.
        if trimmed.contains("\n- ") || trimmed.contains("\n1. ") { return trimmed }

        // Polished keeps a casual target's casing (see `TextCleaner.preserveCasing`), so the style
        // decides: every style but very casual starts sentences with a capital.
        var cased = style == .veryCasual ? trimmed : capitalizingSentences(trimmed)
        if context == .email || context == .workMessages { cased = capitalizingGreetingAddressee(cased) }
        var out = context == .email ? layoutEmail(cased, style: style) : cased
        switch style {
        case .formal:
            out = ensureTerminalPunctuation(out)
        case .casual:
            out = dropFinalPeriod(out)
            if context != .email { out = Regex.replace(out, "^(hey|hi|hello|yo),\\s", with: "$1 ") }
        case .veryCasual:
            out = dropFinalPeriod(lowercaseSentenceStarts(out))
            out = Regex.replace(out, "^(hey|hi|hello|yo),\\s", with: "$1 ")
        case .excited:
            out = ensureTerminalPunctuation(out)
            if out.hasSuffix("."), !out.hasSuffix("...") { out = String(out.dropLast()) + "!" }
        }
        return LiteralSyntaxProtection.violation(candidate: out, draft: trimmed) == nil ? out : trimmed
    }

    /// Greeting and sign-off on their own lines for formal emails; sign-off always separated.
    static func layoutEmail(_ text: String, style: WritingStyle) -> String {
        var body = text
        var signOff: String?
        if let split = splitSignOff(body) {
            body = split.body
            signOff = split.signOff
        }
        if style != .casual, let split = splitGreeting(body) {
            body = split.greeting + ",\n\n" + Punctuation.capitalizeSentences(split.rest)
        }
        if let signOff { body += "\n\n" + signOff }
        return body
    }

    /// A comma ends the greeting when one follows within three words of the salutation, so a
    /// multi-word addressee ("Dear customer success team,") stays whole. A title abbreviation
    /// (a closed list) may carry its full stop inside the addressee ("Dear Ms. Patel,"); no other
    /// full stop is allowed there. Without a comma the greeting is "hi", "hey" or "hello" plus
    /// one name word that arrives capitalised ("Hi can you send this?" is a sentence, not a
    /// greeting); "dear" takes titles and multi-word addressees, so with no comma there is no
    /// way to tell where it ends and it is left unsplit.
    private static let addresseeToken = "(?:(?:mr|mrs|ms|mx|dr|prof)\\.|[^\\s,.!?]+)"
    private static let greetingCommaPattern =
        "^((?:hi|hey|hello|dear)\\s+\(addresseeToken)(?:\\s+\(addresseeToken)){0,2}),\\s+(.+)$"
    private static let greetingWordPattern = "^((?:hi|hey|hello)\\s+(?-i:[A-Z][a-z]+)),?\\s+(.+)$"
    /// A closed class of group addressees is a greeting in any case ("hi all quick reminder");
    /// "of" after it ("hi all of you") means a sentence, and "there" is deliberately not in the class.
    private static let greetingGroupPattern =
        "^((?:hi|hey|hello)\\s+(?:all|everyone|everybody|team|folks))(?!\\s+of\\b),?\\s+(.+)$"

    static func splitGreeting(_ text: String) -> (greeting: String, rest: String)? {
        for pattern in [greetingCommaPattern, greetingWordPattern, greetingGroupPattern] {
            if let match = Regex.firstMatch(text, pattern),
               let greeting = match.string(at: 1, in: text), let rest = match.string(at: 2, in: text) {
                return (greeting, rest)
            }
        }
        return nil
    }

    /// A closing only counts when it starts a clause: directly after . ! ? or a comma, so
    /// "this works best today" is body text. Longest phrases first so "best regards" is never
    /// read as "best" + a name.
    private static let signOffPattern =
        "^(.*?)(?<=[.!?,])\\s+(best regards|kind regards|thank you|best|thanks|cheers|regards|warmly|sincerely),?\\s+([A-Z][a-z]+)\\.?$"

    /// Splits a trailing "<closing> <name>" off the body. The closing and name may arrive in any
    /// case; the body keeps its own end mark (a comma before the closing becomes a full stop) and
    /// the closing line is capitalised here. Only a comma is stripped from the body's end.
    static func splitSignOff(_ text: String) -> (body: String, signOff: String)? {
        guard let match = Regex.firstMatch(text, signOffPattern),
              let rest = match.string(at: 1, in: text), let closing = match.string(at: 2, in: text),
              let name = match.string(at: 3, in: text) else { return nil }
        var body = rest.trimmingCharacters(in: .whitespaces)
        while body.last == "," { body.removeLast() }
        guard !body.isEmpty else { return nil }
        let line = "\(Punctuation.capitalizeSentences(closing)),\n\(Punctuation.capitalizeSentences(name))"
        return (ensureTerminalPunctuation(body), line)
    }

    /// The Clean path's sentence capitalisation, applied outside backtick literals.
    static func capitalizingSentences(_ text: String) -> String {
        let literals = LiteralSyntaxProtection(text, codeContext: false)
        return literals.restore(Punctuation.capitalizeSentences(literals.masked)) ?? text
    }

    static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        // Don't punctuate a trailing sign-off name line.
        if text.contains("\n"), let lastLine = text.components(separatedBy: "\n").last,
           lastLine.split(separator: " ").count == 1 { return text }
        return text + "."
    }

    static func dropFinalPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("...") else { return text }
        return String(text.dropLast())
    }

    static func lowercaseSentenceStarts(_ text: String) -> String {
        var result = ""
        var atStart = true
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if atStart, char.isLetter {
                let word = text[index...].prefix { $0.isLetter || $0 == "'" }
                // Keep "I", "I'm" and acronyms.
                let keep = word == "I" || word.hasPrefix("I'") || (word.count > 1 && word == word.uppercased())
                result.append(keep ? String(char) : char.lowercased())
                atStart = false
            } else {
                result.append(char)
                if char.isLetter || char.isNumber { atStart = false }
                if ".!?\n".contains(char) { atStart = true }
            }
            index = text.index(after: index)
        }
        return result
    }
}
