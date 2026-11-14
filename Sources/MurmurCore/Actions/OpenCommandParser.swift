import Foundation

/// What an "open …" command resolves to. Built by code from fixed templates
/// (`DeepLinkBuilder`) or screened (`SafeURLPolicy`): the spoken words never supply a host.
public enum OpenRequest: Sendable, Equatable {
    /// A Mac app by name ("open slack", "switch to figma").
    case app(name: String)
    /// An AI service by name ("open Claude", "open ChatGPT", heard as "open cloud"): its Mac app
    /// when installed, its site otherwise (`AIHandoffLink.Service.homeURL`).
    case aiService(AIHandoffLink.Service)
    /// A service link or a screened web address, ready to open.
    case link(DeepLinkBuilder.Link)
}

/// Deterministic parse of the open / go to / search family on the Apple path, whose action
/// envelope has no `open_app` kind (the tools-v1 catalogue's `open_app` calls resolve through
/// `resolve(call:)` to the same `OpenRequest`). Phrases handled:
///
/// - "open X", "go to X", "visit X", "launch X", "switch to X", "show X", "pull up X"
/// - "search gmail for X", "search youtube for X", "google X", "search for X" (Google)
/// - "show google calendar tomorrow", "open my calendar for friday"
/// - "directions to X", "navigate to X", "map X"
/// - "open github issues for owner/repo", "open owner slash repo on github"
/// - "open example dot com" (spoken domains through `SafeURLPolicy`)
public enum OpenCommandParser {
    static let openVerbs = ["open up", "open", "go to", "goto", "visit", "launch", "start", "switch to", "show me", "show", "pull up", "bring up"]
    static let searchVerbs = ["search", "look up", "lookup"]

    public static func parse(_ utterance: String, context: DateContext = .current()) -> OpenRequest? {
        let frame = AskRouter.frame(utterance)
        guard !frame.isEmpty else { return nil }
        if let directions = directions(frame) { return directions }
        if let search = search(frame) { return search }
        for verb in openVerbs where frame.hasPrefix(verb + " ") {
            let target = String(frame.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
            return open(target: target, utterance: utterance, context: context)
        }
        if frame.hasPrefix("google "), let query = nonEmpty(String(frame.dropFirst(7))) {
            return DeepLinkBuilder.build(service: .google, action: .search, query: query).map(OpenRequest.link)
        }
        return nil
    }

    /// The tools-v1 `open_app` call, resolved the same way. Nil when the call names nothing
    /// that can be opened safely.
    public static func resolve(call: ToolCall, utterance: String, context: DateContext = .current()) -> OpenRequest? {
        guard call.tool == "open_app" else { return nil }
        func text(_ key: String) -> String? {
            if case .string(let value)? = call.arguments[key], !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
            return nil
        }
        if let service = text("service").flatMap(DeepLinkBuilder.Service.init(rawValue:)),
           let action = text("action").flatMap(DeepLinkBuilder.Action.init(rawValue:)) {
            let link = DeepLinkBuilder.build(
                service: service, action: action, query: text("query"), date: text("date"),
                destination: text("destination"), context: context)
            if let link { return .link(link) }
        }
        guard let target = text("target") else { return nil }
        return open(target: target, utterance: utterance, context: context)
    }

    // MARK: - Pieces

    /// Leading words that name nothing: "open the calculator", "open up the app slack".
    static let targetFillers = ["the", "up", "app", "my app", "the app"]

    /// Drops the first of `prefixes` that begins `text` when followed by a space, whatever the
    /// case — the speech path says "open chrome", a tool caller writes "Open Chrome". Compares
    /// the actual characters, so a differently-capitalised prefix never drops the wrong span.
    static func dropping(_ prefixes: [String], from text: String) -> String? {
        for prefix in prefixes {
            let lead = prefix + " "
            let head = String(text.prefix(lead.count))
            guard !head.isEmpty, head.lowercased() == lead.lowercased() else { continue }
            return String(text.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func open(target: String, utterance: String, context: DateContext) -> OpenRequest? {
        guard var target = nonEmpty(target) else { return nil }
        // Fillers and polite lead-ins in front of the verb ("Uh, can you go to gmail.com") are
        // dropped the same way the speech path drops them (`AskRouter.frame`), but only when an
        // open verb follows, so an app called "Quick Look" keeps its name. A tool caller that
        // puts the whole phrase in `target` gets the same result as the bare command.
        if dropping(openVerbs, from: target) == nil {
            let framed = AskRouter.frame(target)
            if openVerbs.contains(where: { framed.hasPrefix($0 + " ") }) { target = framed }
        }
        var stripped = true
        while stripped {
            stripped = false
            // Tool callers sometimes put the whole phrase in `target` ("Open Chrome") rather
            // than just the slot. Never pass that verb through to the app lookup — and match it
            // however the model capitalised it, since the lookup itself is case-insensitive.
            if let rest = dropping(openVerbs, from: target) {
                target = rest
                stripped = true
            } else if let rest = dropping(targetFillers, from: target) {
                target = rest
                stripped = true
            }
        }
        guard !target.isEmpty else { return nil }
        // "open claude" / "open chat gpt" (heard as "open cloud"): the service's app or site.
        if let service = AIHandoffLink.Service.named(target) { return .aiService(service) }
        let words = target.split(separator: " ").map(String.init)
        // "my calendar for friday", "google calendar tomorrow"
        if let day = calendarDay(target, context: context) { return day }
        // A spoken domain: "example dot com", "example.com", "github dot com slash apple".
        if let url = spokenURL(target, utterance: utterance) { return url }
        // "github issues for owner slash repo"; a GitHub target that doesn't resolve is never
        // an app or a URL guess.
        if target.contains("github") { return github(target) }
        // A named service's home ("gmail", "google maps") is a link; anything else is an app.
        if words == ["gmail"], let link = DeepLinkBuilder.build(service: .gmail, action: .open) { return .link(link) }
        return .app(name: target.split(separator: " ").map(\.capitalized).joined(separator: " "))
    }

    static func search(_ frame: String) -> OpenRequest? {
        for verb in searchVerbs where frame.hasPrefix(verb + " ") {
            let rest = String(frame.dropFirst(verb.count + 1))
            // "search gmail for invoice dana" / "search on youtube for lo fi"
            let candidates: [(String, DeepLinkBuilder.Service)] = [
                ("gmail", .gmail), ("my email", .gmail), ("my mail", .gmail), ("youtube", .youtube),
                ("google maps", .googleMaps), ("maps", .googleMaps), ("notion", .notion), ("google", .google),
            ]
            for (name, service) in candidates {
                for prefix in [name + " for ", "on " + name + " for ", "in " + name + " for "] where rest.hasPrefix(prefix) {
                    guard let query = nonEmpty(String(rest.dropFirst(prefix.count))) else { return nil }
                    return DeepLinkBuilder.build(service: service, action: .search, query: query).map(OpenRequest.link)
                }
            }
            // "search for X" / "search X" → Google.
            let query = AskRouter.stripping(["for"], from: rest) ?? rest
            guard let clean = nonEmpty(query) else { return nil }
            return DeepLinkBuilder.build(service: .google, action: .search, query: clean).map(OpenRequest.link)
        }
        return nil
    }

    static func directions(_ frame: String) -> OpenRequest? {
        for lead in ["directions to", "get directions to", "navigate to", "navigate me to", "take me to", "map"] where frame.hasPrefix(lead + " ") {
            guard let destination = nonEmpty(String(frame.dropFirst(lead.count + 1))) else { return nil }
            return DeepLinkBuilder.build(service: .googleMaps, action: .directions, destination: destination).map(OpenRequest.link)
        }
        return nil
    }

    static func calendarDay(_ target: String, context: DateContext) -> OpenRequest? {
        let calendars = ["google calendar", "my google calendar", "my calendar", "the calendar", "calendar"]
        guard let name = calendars.first(where: { target == $0 || target.hasPrefix($0 + " ") }) else { return nil }
        var rest = String(target.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        rest = AskRouter.stripping(["for", "on"], from: rest) ?? rest
        guard !rest.isEmpty else {
            // A bare "open my calendar" is the Calendar app, not a Google link.
            return name.contains("google") ? DeepLinkBuilder.build(service: .googleCalendar, action: .day, date: "today", context: context).map(OpenRequest.link) : .app(name: "Calendar")
        }
        return DeepLinkBuilder.build(service: .googleCalendar, action: .day, date: rest, context: context).map(OpenRequest.link)
    }

    static func github(_ target: String) -> OpenRequest? {
        var text = target
        let action: DeepLinkBuilder.Action
        if let issues = text.range(of: "issues") { action = .issues; text.removeSubrange(issues) }
        else if let pulls = text.range(of: "pull requests") ?? text.range(of: "pulls") ?? text.range(of: "prs") { action = .pulls; text.removeSubrange(pulls) }
        else { action = .repo }
        guard text.contains("github") else { return nil }
        text = text.replacingOccurrences(of: "github", with: " ").replacingOccurrences(of: " slash ", with: "/")
        for filler in [" for ", " on ", " of ", " in "] { text = text.replacingOccurrences(of: filler, with: " ") }
        let words = text.split(separator: " ").map(String.init)
        guard let repo = words.first(where: { $0.contains("/") }) else { return nil }
        return DeepLinkBuilder.build(service: .github, action: action, query: repo).map(OpenRequest.link)
    }

    /// "example dot com", "github.com/foo/bar" → a screened https URL.
    static func spokenURL(_ target: String, utterance: String) -> OpenRequest? {
        // Every word must be part of the address: two plain words in a row ("github for
        // evil.com") make a phrase, not a domain.
        let tokens = target.split(separator: " ").map(String.init)
        func isJoiner(_ token: String) -> Bool { token == "dot" || token == "slash" || token.contains(".") || token.contains("/") }
        for (left, right) in zip(tokens, tokens.dropFirst()) where !isJoiner(left) && !isJoiner(right) { return nil }
        let joined = target.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " slash ", with: "/")
            .replacingOccurrences(of: " ", with: "")
        guard joined.contains("."), !joined.hasPrefix("."), !joined.hasSuffix(".") else { return nil }
        let raw = joined.hasPrefix("http") ? joined : "https://" + joined
        guard let url = SafeURLPolicy.approvedURL(raw, transcript: utterance), let host = url.host else { return nil }
        return .link(DeepLinkBuilder.Link(url: url, summary: "Open \(host)", serviceName: host, domain: host))
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
