import Foundation

/// The names of AI models and coding agents that the recogniser writes wrongly or in lower case, in a dictation about
/// AI work: "son at agent" for "Sonnet agent", "sonnet" for "Sonnet", "opus", "haiku", "codex", "claude code", "g p t".
/// `AIProductNameFixer` does the products that are mis-heard as other words ("clawed", "chat gpt"); this does the model
/// names, in the style of `AIProductCloudCues`: a swap needs a cue AND no blocker, because "sonnet" and "haiku" are
/// poems, "opus" is a piece of music, "gemini" a star sign and "my son at school" is a sentence.
///
/// Three kinds of heard words, from safest to riskiest:
/// 1. the name's own words in another case ("codex", "GPT" as "gpt", "claude code"): a non-word needs no cue; a word
///    that is also English ("sonnet", "opus", "haiku", "gemini") needs a strong cue, or an Anthropic app and a name
///    position (after "use", "switch to", "ask"…, or before "agent", "model" or a version number).
/// 2. a respelling that is not an English word ("sonet", "sonnett"): the same cues, or the name on the screen.
/// 3. ordinary words that sound like the name ("son at", "some at", "son net"): a strong cue in the clause, and none of
///    the neighbours that make them plain English ("my son at", "son at the party", "some at home").
enum AIModelNames {
    struct Replacement {
        let range: Range<String.Index>
        let text: String
    }

    private struct Name {
        /// The written form.
        let text: String
        /// The name's own words, lowercase ("claude", "code").
        let own: [String]
        /// The own form is an English word or another thing too, so a lone lower-case match needs evidence.
        let ordinary: Bool
        /// Different spellings that are not English words.
        let respellings: [[String]]
        /// Ordinary words that sound like the name.
        let phrases: [[String]]
        /// A lone lower-case match of the own form is capitalised. Off for "codex" and "gpt": the model writes those, and
        /// an existing contract leaves "gpt models" as heard.
        var fixesCase = true
    }

    private static let names: [Name] = [
        Name(text: "Sonnet", own: ["sonnet"], ordinary: true,
             respellings: [["sonet"], ["sonnett"], ["sonnit"], ["sonett"], ["sonnat"]],
             phrases: [["son", "at"], ["some", "at"], ["son", "net"], ["sun", "net"], ["son", "it"], ["sonic", "at"]]),
        Name(text: "Opus", own: ["opus"], ordinary: true, respellings: [], phrases: []),
        Name(text: "Haiku", own: ["haiku"], ordinary: true, respellings: [], phrases: []),
        Name(text: "Claude Code", own: ["claude", "code"], ordinary: false, respellings: [], phrases: []),
        Name(text: "Gemini", own: ["gemini"], ordinary: true, respellings: [], phrases: []),
        Name(text: "GPT", own: ["gpt"], ordinary: false, respellings: [], phrases: [["g", "p", "t"]], fixesCase: false),
    ]

    /// Words that make the dictation one about AI work. Not the model names themselves ("a haiku and a sonnet"), and
    /// not weak words ("ask", "chat", "terminal", "token").
    private static let strongCues: Set<String> = [
        "prompt", "prompts", "prompting", "model", "models", "anthropic", "openai", "cursor", "api", "apis",
        "agent", "agents", "subagent", "subagents", "llm", "llms", "ai", "codex", "gemini", "copilot", "claude",
        "chatbot", "assistant", "mcp", "gpt", "chatgpt", "context", "inference",
    ]
    /// The words right before a name, in an Anthropic app, that make a model name of a lone "sonnet", "opus", "haiku".
    private static let namePrecedingWords: Set<String> = [
        "use", "using", "used", "with", "switch", "switched", "switching", "try", "trying", "tried", "run", "running",
        "start", "starting", "spawn", "spawning", "launch", "launching", "call", "calling", "via", "prefer",
        "choose", "pick", "default", "set",
    ]
    private static let switchingWords: Set<String> = [
        "switch", "switched", "switching", "move", "moved", "moving", "change", "changed", "changing", "upgrade",
        "upgraded", "downgrade", "downgraded", "set", "default", "defaults", "back", "over",
    ]
    private static let nameFollowingWords: Set<String> = [
        "agent", "agents", "subagent", "subagents", "model", "models", "session", "sessions", "instance", "api",
    ]
    private static let connectorWords: Set<String> = ["and", "or", "vs", "versus"]

    /// Before "son at": whose son it is.
    private static let possessives: Set<String> = [
        "my", "his", "her", "our", "your", "their", "whose", "grandson", "stepson", "eldest", "youngest", "oldest",
    ]
    /// After "son at" or "some at": the place or the thing that makes it plain English.
    private static let plainFollowers: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "his", "her", "their", "its", "me",
        "him", "them", "us", "it", "you", "home", "school", "work", "college", "university", "night", "lunch", "dinner",
        "breakfast", "midnight", "noon", "dawn", "dusk", "once", "least", "most", "all", "times", "any", "no", "some",
        "every", "each", "least", "large", "present", "peace", "rest", "ease", "odds", "war", "play", "sea", "last",
        "first", "best", "worst", "risk", "stake", "hand", "heart", "fault", "length",
    ]
    /// "some at" is far more common English than "son at": it needs the thing it names to follow.
    private static let someAtFollowers: Set<String> = [
        "agent", "agents", "subagent", "subagents", "model", "models", "session", "sessions", "instance",
    ]

    /// True when `word` (lowercase) is one of the model names this file spells ("sonnet", "opus", "claude", "gpt").
    static func isModelName(_ word: String) -> Bool {
        knownWords.contains(word)
    }

    private static let knownWords: Set<String> = Set(names.flatMap(\.own)).union(["claude", "codex", "chatgpt", "anthropic", "openai"])

    private struct Token {
        let lower: String
        let range: Range<String.Index>
    }

    private enum Kind { case own, respelling, phrase }

    private struct Candidate {
        let name: Name
        let kind: Kind
        let words: [String]
    }

    /// The replacements for `text`. `claimed` holds ranges the caller already changes; they are never returned.
    /// `anthropicPlace` is true when the focused app is an Anthropic one; `screen` holds the lowercase screen terms.
    static func replacements(in text: String, claimed: [Range<String.Index>], anthropicPlace: Bool,
                             screen: [String] = []) -> [Replacement] {
        let tokens = Regex.matchesCaseSensitive(text, "[A-Za-z][A-Za-z'’]*").compactMap { match -> Token? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Token(lower: text[range].lowercased(), range: range)
        }
        func isClaimed(_ index: Int) -> Bool { claimed.contains { $0.overlaps(tokens[index].range) } }
        func gap(_ left: Int, _ right: Int) -> Substring { text[tokens[left].range.upperBound..<tokens[right].range.lowerBound] }
        func spaced(_ left: Int, _ right: Int) -> Bool {
            let between = gap(left, right)
            return !between.isEmpty && between.allSatisfy(\.isWhitespace)
        }
        func breaksClause(_ left: Int, _ right: Int) -> Bool { gap(left, right).contains { ".!?;,:\n".contains($0) } }
        var found: [(index: Int, last: Int, candidate: Candidate)] = []
        var index = 0
        while index < tokens.count {
            guard let hit = match(at: index, in: tokens, spaced: spaced) else { index += 1; continue }
            let last = index + hit.words.count - 1
            if !(index...last).contains(where: isClaimed) { found.append((index, last, hit)) }
            index = last + 1
        }
        // A model name joined to an accepted one by a connector is accepted too ("Opus and sonnet").
        var accepted: [Int: Replacement] = [:]
        var changed = true
        while changed {
            changed = false
            for (position, item) in found.enumerated() where accepted[position] == nil {
                let heard = String(text[tokens[item.index].range.lowerBound..<tokens[item.last].range.upperBound])
                guard heard != item.candidate.name.text else { continue }
                let ok = isSupported(item.candidate, from: item.index, to: item.last, tokens: tokens, text: text,
                                     anthropicPlace: anthropicPlace, screen: screen, spaced: spaced, breaksClause: breaksClause)
                    || isPaired(position, in: found, accepted: accepted, tokens: tokens, gap: gap)
                guard ok else { continue }
                let range = tokens[item.index].range.lowerBound..<tokens[item.last].range.upperBound
                accepted[position] = Replacement(range: range, text: item.candidate.name.text)
                changed = true
            }
        }
        return accepted.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The candidate that starts at `index`, longest first.
    private static func match(at index: Int, in tokens: [Token], spaced: (Int, Int) -> Bool) -> Candidate? {
        var best: Candidate?
        func consider(_ name: Name, _ kind: Kind, _ words: [String]) {
            guard index + words.count <= tokens.count, words.count > (best?.words.count ?? 0) else { return }
            let fits = words.indices.allSatisfy { offset in
                tokens[index + offset].lower == words[offset] && (offset == 0 || spaced(index + offset - 1, index + offset))
            }
            if fits { best = Candidate(name: name, kind: kind, words: words) }
        }
        for name in names {
            if name.fixesCase { consider(name, .own, name.own) }
            name.respellings.forEach { consider(name, .respelling, $0) }
            name.phrases.forEach { consider(name, .phrase, $0) }
        }
        return best
    }

    /// True when a model name that is joined by a connector to another accepted model name makes this one a model name.
    private static func isPaired(_ position: Int, in found: [(index: Int, last: Int, candidate: Candidate)],
                                 accepted: [Int: Replacement], tokens: [Token], gap: (Int, Int) -> Substring) -> Bool {
        let item = found[position]
        guard item.candidate.name.ordinary, item.candidate.kind == .own else { return false }
        return accepted.keys.contains { other in
            guard found[other].candidate.name.text != item.candidate.name.text else { return false }
            let (left, right) = other < position ? (found[other], item) : (item, found[other])
            guard right.index == left.last + 1 || right.index == left.last + 2 else { return false }
            let between = gap(left.last, right.index).lowercased()
                .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "&" }).map(String.init)
            return between.count <= 1 && between.allSatisfy(connectorWords.contains)
        }
    }

    private static func isSupported(
        _ candidate: Candidate, from start: Int, to end: Int, tokens: [Token], text: String, anthropicPlace: Bool,
        screen: [String], spaced: (Int, Int) -> Bool, breaksClause: (Int, Int) -> Bool
    ) -> Bool {
        let previous = start > 0 && spaced(start - 1, start) ? tokens[start - 1] : nil
        let next = end + 1 < tokens.count && spaced(end, end + 1) ? tokens[end + 1] : nil
        let onScreen = screen.contains { $0.contains(candidate.name.text.lowercased()) }
        let strong = hasStrongCue(from: start, to: end, tokens: tokens, breaksClause: breaksClause)
        switch candidate.kind {
        case .own:
            if !candidate.name.ordinary { return true }
            if strong { return true }
            guard anthropicPlace else { return false }
            let beforePrevious = start > 1 && spaced(start - 2, start - 1) ? tokens[start - 2] : nil
            return isNamePosition(previous: previous, beforePrevious: beforePrevious, next: next,
                                  afterEnd: text[tokens[end].range.upperBound...])
        case .respelling:
            return strong || onScreen || anthropicPlace
        case .phrase:
            // Three spoken letters in a row can only be the name.
            if candidate.words == ["g", "p", "t"] { return true }
            guard strong else { return false }
            return !isPlainEnglish(candidate, start: start, end: end, tokens: tokens, previous: previous, next: next)
        }
    }

    /// A strong cue stands in the same clause, within six words of the heard words.
    private static func hasStrongCue(from start: Int, to end: Int, tokens: [Token],
                                     breaksClause: (Int, Int) -> Bool) -> Bool {
        let range = max(0, start - 6)...min(tokens.count - 1, end + 6)
        return range.contains { other in
            let word = tokens[other].lower
            let stem = word.hasSuffix("'s") || word.hasSuffix("’s") ? String(word.dropLast(2)) : word
            guard !(start...end).contains(other), strongCues.contains(stem) else { return false }
            return other < start ? !breaksClause(other, start) : !breaksClause(end, other)
        }
    }

    private static func isNamePosition(previous: Token?, beforePrevious: Token?, next: Token?, afterEnd: Substring) -> Bool {
        if let previous, namePrecedingWords.contains(previous.lower) { return true }
        // "switch to opus", "fall back to sonnet".
        if let previous, previous.lower == "to", let beforePrevious, switchingWords.contains(beforePrevious.lower) { return true }
        if let previous, previous.lower == "back", let beforePrevious, beforePrevious.lower == "fall" { return true }
        if let next, nameFollowingWords.contains(next.lower) { return true }
        let following = afterEnd.drop(while: { $0 == " " })
        return following.first?.isNumber == true
    }

    /// "my son at", "son at the party", "some at home": the phrase is a sentence, not a name.
    private static func isPlainEnglish(_ candidate: Candidate, start: Int, end: Int, tokens: [Token],
                                       previous: Token?, next: Token?) -> Bool {
        if let previous, possessives.contains(previous.lower) || previous.lower.hasSuffix("'s") || previous.lower.hasSuffix("’s") {
            return true
        }
        guard candidate.words.last == "at" else { return false }
        guard let next else { return candidate.words.first == "some" }
        if plainFollowers.contains(next.lower) { return true }
        return candidate.words.first == "some" && !someAtFollowers.contains(next.lower)
    }
}
