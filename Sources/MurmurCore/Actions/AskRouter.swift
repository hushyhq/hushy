import Foundation

/// The kind of question a chord-triggered utterance asks, if any. Runs *before* the Do path
/// (`ActionExtractor`); nothing here fires without the explicit action chord. A rule here may only
/// say yes to a shape it recognises; `.none` hands the sentence to the model, never to a failure.
public enum AskIntent: Sendable, Equatable {
    /// "Ask Claude what …": hand the question to that service (`AIHandoffLink`).
    case askAI(service: AIHandoffLink.Service, question: String)
    /// "What groceries do I need", "what did we decide about pricing": answer from the user's
    /// own notes, history, reminders, calendar (`OwnStuffAnswerer`).
    case askOwn(question: String)
    /// "Summarize this": read the front window and summarize it (`ScreenSummarizer`).
    case summarizeScreen(focus: String?)
    /// "Find and fetch my resume": look for one file on this Mac (`FileFindEngine`). The query is
    /// typed and validated; it is never a path or a command.
    case findFile(FileRequest)
    /// "Where is my passport": the shape of a file request with nothing that says "file". The
    /// caller asks the model once (`FileQueryExtractor`); if it isn't one, this is `askOwn`.
    case maybeFile(question: String)
    /// Not a question for Hushy: the Do path (or plain dictation) decides.
    case none
}

/// Deterministic, model-free routing of the three ask shapes. It judges only the *frame* the
/// utterance opens with: "ask claude …" is a hand-off, "i asked claude
/// yesterday …" is dictation, "remind me to ask claude …" is a reminder. Tested in
/// `AskRouterTests` and measured by `murmur-eval ask` on `Evals/ask-routing-dev.json`.
public enum AskRouter {
    public static func route(_ utterance: String, now: Date = Date()) -> AskIntent {
        let frame = Self.frame(utterance)
        guard !frame.isEmpty else { return .none }
        if let handoff = aiHandoff(frame) { return handoff }
        if reachesPeople(frame) { return .none }
        if let summary = summarizeScreen(frame) { return summary }
        let own = askOwn(frame)
        // Before the own-stuff answer: "find my resume" opens with askOwn's "find" and "my".
        switch FileRouter.decide(frame, now: now) {
        case .file(let request): return .findFile(request)
        case .undecided: if own != nil { return .maybeFile(question: frame) }
        case .no: break
        }
        return own ?? .none
    }

    // MARK: - Frame

    /// Lead-ins spoken before the request ("okay so", "hey hushy", "can you", "please").
    static let leadIns: [String] = [
        "okay so", "ok so", "okay", "ok", "so", "right", "um", "uh", "umm", "hmm", "oh", "and", "like", "alright",
        "yeah", "well", "hey hushy", "hey", "hushy", "please", "also", "then", "actually", "just", "quick", "quickly",
        "can you", "could you", "would you", "will you", "i want you to", "i'd like you to", "i would like you to",
        "i need you to", "go ahead and", "let's", "lets",
    ]

    /// Lowercased, punctuation-free, single-spaced, with lead-ins removed from the front.
    public static func frame(_ utterance: String) -> String {
        var text = normalize(utterance)
        var stripped = true
        while stripped {
            stripped = false
            for lead in leadIns where text == lead || text.hasPrefix(lead + " ") {
                text = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
                break
            }
        }
        return text
    }

    /// Punctuation goes, except an apostrophe and a `.`, `/` or `-` *between* letters or digits
    /// ("example.com", "acme/site", "claude-code" survive; a trailing "." doesn't).
    public static func normalize(_ text: String) -> String {
        let chars = Array(text.lowercased().replacingOccurrences(of: "’", with: "'"))
        var kept: [Character] = []
        for (index, char) in chars.enumerated() {
            if char.isLetter || char.isNumber || char == "'" || char == " " {
                kept.append(char)
            } else if char == "." || char == "/" || char == "-",
                      index > 0, index + 1 < chars.count,
                      chars[index - 1].isLetter || chars[index - 1].isNumber,
                      chars[index + 1].isLetter || chars[index + 1].isNumber {
                kept.append(char)
            } else {
                kept.append(" ")
            }
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Ask an AI

    static let handoffLeads = ["ask", "go ask", "hand this to", "send this to", "search"]

    static func aiHandoff(_ frame: String) -> AskIntent? {
        for lead in handoffLeads where frame.hasPrefix(lead + " ") {
            let rest = String(frame.dropFirst(lead.count + 1))
            guard let (service, after) = leadingService(rest) else { continue }
            var question = after
            if lead == "search" { question = stripping(["for", "about"], from: question) ?? question }
            question = questionForm(question)
            guard !question.isEmpty else { return .none }
            return .askAI(service: service, question: question)
        }
        return nil
    }

    /// "claude what is …" → (.claude, "what is …"); nil when no service opens `text`.
    static func leadingService(_ text: String) -> (AIHandoffLink.Service, String)? {
        for service in AIHandoffLink.Service.allCases {
            for name in service.spokenNames.sorted(by: { $0.count > $1.count }) {
                if text == name { return (service, "") }
                if text.hasPrefix(name + " ") { return (service, String(text.dropFirst(name.count + 1))) }
            }
        }
        return nil
    }

    /// Turns the spoken remainder into something to type into a chat box.
    static func questionForm(_ rest: String) -> String {
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let about = stripping(["about"], from: text) { return "tell me about " + about }
        if let to = stripping(["to"], from: text) { text = to }
        if let whether = stripping(["whether", "if"], from: text) { text = "whether " + whether }
        return text
    }

    /// `text` without a leading word from `words`, or nil if none leads it.
    static func stripping(_ words: [String], from text: String) -> String? {
        for word in words where text.hasPrefix(word + " ") {
            return String(text.dropFirst(word.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Summarize this

    static let summarizeLeads = [
        "summarize", "summarise", "sum up", "tldr", "tl dr", "give me the gist of", "what's the gist of",
        "whats the gist of", "give me a summary of", "give me the summary of", "give me a recap of", "recap",
        "what does", "what's", "whats", "what is", "what am i looking at", "read", "explain",
    ]

    /// Things on screen. "my …", "the meeting", "yesterday's" are the user's own stuff instead.
    static let screenObjects = [
        "this page", "the page", "this email", "this mail", "this article", "this pdf", "this document", "this doc",
        "this thread", "this window", "this note", "this chat", "this conversation", "this post", "this",
        "the screen", "my screen", "what's on screen", "whats on screen", "what's on my screen", "whats on my screen",
        "on screen", "the current page", "the article", "the email", "the document", "the thread", "it", "these",
    ]

    static func summarizeScreen(_ frame: String) -> AskIntent? {
        // Whole phrases that already name the screen.
        if ["what am i looking at", "what's on my screen", "whats on my screen", "what's on screen"].contains(frame) {
            return .summarizeScreen(focus: nil)
        }
        for lead in summarizeLeads {
            guard frame == lead || frame.hasPrefix(lead + " ") else { continue }
            let rest = String(frame.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            guard let object = screenObjects.sorted(by: { $0.count > $1.count })
                .first(where: { rest == $0 || rest.hasPrefix($0 + " ") }) else { continue }
            let tail = String(rest.dropFirst(object.count)).trimmingCharacters(in: .whitespaces)
            // "what does this say about pricing" → the focus is "pricing"; a bare "what's this"
            // with a page word is a summary, a bare "read this" is too.
            let isQuestionLead = lead.hasPrefix("what")
            if isQuestionLead {
                guard tail.hasPrefix("say") || tail.hasPrefix("about") || tail.hasPrefix("page")
                    || tail.isEmpty && object != "this" && object != "it" else { continue }
            }
            return .summarizeScreen(focus: focus(in: tail))
        }
        return nil
    }

    static func focus(in tail: String) -> String? {
        for marker in ["about", "focusing on", "focused on", "regarding", "on"] {
            if let index = tail.range(of: " \(marker) ")?.upperBound {
                let focus = tail[index...].trimmingCharacters(in: .whitespaces)
                return focus.isEmpty ? nil : String(focus)
            }
            if tail.hasPrefix(marker + " ") { return String(tail.dropFirst(marker.count + 1)) }
        }
        return nil
    }

    // MARK: - Ask about your own stuff

    static let ownOpeners = [
        "what", "what's", "whats", "when", "when's", "whens", "where", "which", "who", "how many", "how much",
        "how long", "do i", "did i", "did we", "have i", "have we", "am i", "is there", "are there", "is my",
        "are my", "was there", "were there", "any", "show me", "find", "look up", "pull up", "search my",
        "search for", "check my", "check", "tell me", "remind me what", "remind me when", "remind me who",
        "list my", "read me", "read back", "recap", "summarize my", "summarise my", "summarize the",
        "summarize yesterday's", "summarize yesterdays", "summarize last",
    ]

    /// A word that makes a question about the user's own stuff, not the world.
    static let ownSignals = [
        "my", "i", "we", "our", "me", "groceries", "grocery", "shopping list", "the list", "to do", "todo", "reminder",
        "reminders", "calendar", "schedule", "meeting", "meetings", "notes", "note", "decide", "decided", "decision",
        "decisions", "discussed", "discuss", "agreed", "agree", "said", "appointment", "appointments", "dictated",
        "dictation", "dictations", "yesterday", "last week", "this weekend", "the weekend", "tomorrow", "today",
        "tonight", "standup", "stand up", "action items", "follow ups", "follow up", "offsite", "off site", "the launch",
        "the deadline", "the sprint", "the retro", "one on one", "1 1",
    ]

    /// Hedges that open with a question word but aren't a question to answer.
    static let hedges = ["what if", "what about if", "i wonder", "i don't know", "not sure"]

    /// Questions about the world, not the user: never answered from their notes.
    static let worldQuestions = [
        "what time is it", "what's the time", "whats the time", "what day is it", "what's the date", "whats the date",
        "what's the weather", "whats the weather", "how's the weather", "hows the weather",
    ]

    static func askOwn(_ frame: String) -> AskIntent? {
        for world in worldQuestions where frame == world || frame.hasPrefix(world + " ") { return nil }
        for hedge in hedges where frame.hasPrefix(hedge + " ") { return nil }
        guard ownOpeners.contains(where: { frame == $0 || frame.hasPrefix($0 + " ") }) else { return nil }
        let padded = " \(frame) "
        guard ownSignals.contains(where: { padded.contains(" \($0) ") }) else { return nil }
        return .askOwn(question: frame)
    }

    // MARK: - Shared

    /// Verbs that send to people: a question that also asks to send is the Do path's business
    /// (it refuses or cards multi-intent), never a read.
    static let sendVerbs = ["send", "email", "mail", "text", "message", "post", "tweet", "share", "forward", "reply"]

    /// Only a *verb* use counts: "email it to dana", "and text priya", "send this to…". "This
    /// email", "the post" are things on screen.
    static func reachesPeople(_ frame: String) -> Bool {
        let padded = " \(frame) "
        return sendVerbs.contains { verb in
            frame.hasPrefix(verb + " ") || padded.contains(" and \(verb) ") || padded.contains(" then \(verb) ")
                || padded.contains(" \(verb) it ") || padded.contains(" \(verb) this to ") || padded.contains(" \(verb) that to ")
        }
    }
}
