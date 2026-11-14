import Foundation

/// A question read in code: what is asked, about whom, and when. No model: the people,
/// companies and series it can name are the ones the memory already holds.
public struct MemoryQuestion: Sendable, Equatable {
    public enum Intent: String, Sendable { case decisions, commitments, changes, prep, search }
    /// Whose commitments: the user's, the other side's, or both.
    public enum Direction: String, Sendable { case mine, theirs, both }

    public var intent: Intent
    public var direction: Direction
    public var people: Set<Int64>
    public var companies: Set<Int64>
    /// Content words left once intent, names and dates are taken out ("pricing", "questionnaire").
    public var topic: [String]
    /// The question's own words for the topic, in order, with "|" where other words came between
    /// them ("single", "sign", "on"): for headings and short forms ("sso").
    public var topicWords: [String] = []
    /// The topic split where the question says "or": "UV or sun fading" is [["uv"], ["sun", "fad"]].
    /// One group when there is no "or".
    public var topicGroups: [[String]] = []
    /// Capitalised names the memory does not know ("Zephyr").
    public var unknownNames: [String]
    var time: MemoryDates.Reference?
    /// "our first call" picks the earliest matching meeting, "the last meeting" the latest.
    var ordinal: Ordinal?
    /// The day a prep question names, read forward ("on Wednesday" is the coming one).
    var upcomingDay: DateInterval?
    /// "since the firmware chat", "since we first spoke": a meeting, not a date, to compare against.
    /// Its words are taken out of `topic`.
    var sinceMeeting: SinceMeeting?

    enum SinceMeeting: Equatable { case first, named([String]) }

    enum Ordinal: Equatable { case first, last }

    static let intentWords: [(Intent, [String])] = [
        (.prep, ["prep", "prepare", "brief me", "get ready", "before my", "before the", "ready for", "catch me up before"]),
        (.changes, ["changed", "change", "changes", "different", "what's new", "whats new", "new since", "moved", "update since", "updates since", "shifted"]),
        (.commitments, ["hanging", "got open", "open for me", "still open", "ever send", "ever sent", "get back to", "on me", "owe", "owes", "owed", "promised", "promise", "waiting on", "waiting for", "on the hook", "open items",
                        "open item", "action items", "action item", "to do", "todo", "to-dos", "todos", "outstanding", "pending",
                        "follow up", "follow-up", "committed", "still need", "still needs", "supposed to", "tasks", "deliverables", "on my plate"]),
        (.decisions, ["where did we land", "are we doing", "are we going with", "end up", "ended up", "what's the plan", "the plan for", "go with", "went with", "decide", "decided", "decision", "decisions", "agree", "agreed", "settle", "settled", "land on", "landed on", "conclude", "concluded", "choose", "chose", "pick", "picked"]),
    ]

    static let fillerStems: Set<String> = Set([
        "meeting", "call", "sync", "chat", "talk", "discuss", "discussion", "last", "latest", "recent", "previou", "since",
        "between", "two", "next", "upcoming", "about", "anyth", "everyth", "said", "mention", "brought", "remind",
        "prep", "prepar", "brief", "ready", "chang", "different", "new", "update", "owe", "promis", "wait", "open", "item",
        "action", "todo", "outstand", "pend", "follow", "commit", "suppos", "task", "deliverable", "decid", "decision",
        "agre", "settl", "land", "conclud", "choos", "chose", "pick", "week", "month", "today", "yesterday", "tomorrow",
        "morn", "ago", "past", "plate", "find", "know", "learn", "hear", "heard", "hook", "talk", "happen", "stand", "far", "status", "where", "guy", "team", "folk",
        "doing", "done", "going", "coming", "ever", "end", "ended", "hanging", "got", "plan", "folk", "folks", "anyone", "anybody", "someone", "somebody", "ask", "asked", "bring", "raise", "raised", "mention", "mentioned", "compar", "compared", "befor", "before", "prior", "against", "versu", "first", "come", "came", "time", "ever",
    ].map(MemoryText.stem))

    static func parse(_ question: String, memory: MeetingMemory, context: DateContext) -> MemoryQuestion {
        let lowered = " " + MemoryText.words(question).joined(separator: " ") + " "
        let has: (String) -> Bool = { lowered.contains(" " + MemoryText.words($0).joined(separator: " ") + " ") }
        let intent = intentWords.first { $0.1.contains(where: has) }?.0 ?? .search
        let named = memory.companies(namedIn: question)
        var people = memory.people(namedIn: question, preferring: named)
        var companies = named
        if !companies.isEmpty, !people.isEmpty {
            let atCompany = people.filter { memory.people[$0]?.companyId.map(companies.contains) == true }
            // "Marcus Webb at Brightmoor": the company picks the person; the question is about him.
            if !atCompany.isEmpty {
                people = atCompany
                companies = []
            }
        }
        let companyWords = named.compactMap { memory.companies[$0] }.flatMap { MemoryText.words($0.name) + MemoryText.words($0.domain ?? "") }
        let nameWords = Set(people.compactMap { memory.people[$0] }.flatMap { MemoryText.words($0.name) } + companyWords
            + MemoryText.words(question).filter { word in
                word.count >= 5 && companyWords.contains { MemoryText.squashed($0).hasPrefix(word) || word.hasPrefix($0) && $0.count >= 5 }
            })
        let time = MemoryDates.reference(in: question, context: context)
        var since: SinceMeeting?
        if time == nil, let range = lowered.range(of: " since ") {
            let phrase = MemoryText.contentStems(String(lowered[range.upperBound...]))
            since = phrase.contains("first") || phrase.contains("start") || phrase.contains("began") ? .first
                : phrase.isEmpty ? nil : .named(phrase)
        }
        let sinceWords: Set<String> = if case .named(let words) = since { Set(words) } else { [] }
        let topic = MemoryText.contentStems(question).filter { !sinceWords.contains($0) }.filter { stem in
            !fillerStems.contains(stem) && !nameWords.contains(stem) && !nameWords.map(MemoryText.stem).contains(stem)
                && !MemoryText.monthAndDayWords.contains(stem) && Int(stem) == nil
                && stem.range(of: #"^\d+(st|nd|rd|th|s)?$"#, options: .regularExpression) == nil
        }
        var topicWords: [String] = []
        for token in question.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            let parts = token.split(separator: "-").map(String.init)
            if parts.count > 1, topic.contains(MemoryText.stem(parts.joined())) { topicWords += parts }
            else if topic.contains(MemoryText.stem(String(token))) { topicWords.append(String(token)) }
            else if topicWords.last != "|", !topicWords.isEmpty { topicWords.append("|") }
        }
        let groups = lowered.components(separatedBy: " or ")
            .map { part in MemoryText.contentStems(part).filter(topic.contains) }.filter { !$0.isEmpty }
        return MemoryQuestion(
            intent: intent, direction: direction(lowered, names: nameWords), people: people, companies: companies,
            topic: topic, topicWords: topicWords, topicGroups: groups.count > 1 ? groups : [topic], unknownNames: unknownNames(in: question, memory: memory, known: nameWords),
            time: time, ordinal: ordinal(lowered),
            upcomingDay: upcomingDay(question, context: context), sinceMeeting: since)
    }

    static func upcomingDay(_ question: String, context: DateContext) -> DateInterval? {
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "tomorrow", "today", "tonight"]
        let words = Set(MemoryText.words(question))
        let months = MemoryText.monthAndDayWords.subtracting(["week", "month"])
        guard !words.isDisjoint(with: days) || !words.isDisjoint(with: months),
              let anchor = DateAnchor.firstDate(in: question, context: context)
                ?? DateAnchor.firstDate(in: MemoryText.words(question).joined(separator: " "), context: context) else { return nil }
        let start = context.calendar.startOfDay(for: anchor.start)
        return DateInterval(start: start, end: context.calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    static func ordinal(_ text: String) -> Ordinal? {
        let matches: (String) -> Bool = { text.range(of: $0, options: .regularExpression) != nil }
        if matches(#" (first|earliest|initial|intro) (call|meeting|chat|conversation|sync|time) "#) { return .first }
        if matches(#" (last|latest|most recent|previous) (call|meeting|chat|conversation|sync|time|one) "#) { return .last }
        return nil
    }

    static func direction(_ text: String, names: Set<String>) -> Direction {
        let name = names.isEmpty ? "(?!)" : "(" + names.map(NSRegularExpression.escapedPattern).joined(separator: "|") + ")"
        let mine = [#" from me "#, #" (waiting on|waiting for|need from|needs from) me "#, #" (do|did|have|should|must) i "#,
                    #" i (still )?(owe|promised|need|have to|committed|said)"#, #" (am i|i'm) "#, #" my "#, #" i owe "#]
        let theirs = [#" (owe|owes) me "#, #" (waiting on|waiting for|hear back from|chasing) "#, " from \(name) ",
                      " (does|did|has|is|was|will) \(name) ", " \(name) (still )?(owes|owe|promised|needs|need|said|committed|has to|is supposed)",
                      " \(name) s "]
        let matches: (String) -> Bool = { text.range(of: $0, options: .regularExpression) != nil }
        if mine.prefix(2).contains(where: matches) { return .mine }
        if theirs.contains(where: matches) { return .theirs }
        if mine.contains(where: matches) { return .mine }
        return .both
    }

    static let commonCapitalised: Set<String> = [
        "what", "who", "when", "where", "which", "how", "did", "do", "does", "is", "are", "can", "could", "should",
        "prep", "remind", "give", "tell", "show", "list", "anything", "has", "have", "any", "the", "and", "i", "we",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
        "april", "may", "june", "july", "august", "september", "october", "november", "december", "hushy", "ok", "okay",
        "so", "and", "but", "also", "brief", "catch", "summarize", "summarise", "find", "get", "help", "pull", "was", "were",
        "q1", "q2", "q3", "q4", "ceo", "cto", "cfo", "vp", "pm", "eod", "eta", "sso", "api", "nda", "sow", "po", "msa",
    ]

    /// Capitalised words that name nobody the memory knows and appear in no meeting at all.
    static func unknownNames(in question: String, memory: MeetingMemory, known: Set<String>) -> [String] {
        let tokens = question.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }).map(String.init)
        return tokens.enumerated().compactMap { index, token in
            guard token.first?.isUppercase == true, token.count > 1 else { return nil }
            let word = MemoryText.words(token).first ?? ""
            guard !commonCapitalised.contains(word), !known.contains(word), !MemoryText.stopWords.contains(word) else { return nil }
            if index == 0 { return nil }
            return memory.searchTurns([MemoryText.stem(word)], limit: 1).isEmpty && memory.meetingsAbout([MemoryText.stem(word)], share: 1).isEmpty
                ? token : nil
        }
    }
}

extension MeetingMemory {
    /// Outside companies named in `text`, longest name first ("Brightmoor Freight" before "Brightmoor").
    func companies(namedIn text: String) -> Set<Int64> {
        var words = MemoryText.words(text)
        var found = Set<Int64>()
        let outside = companies.values.filter { !$0.isOwn }
        for length in stride(from: 3, through: 1, by: -1) where words.count >= length {
            for start in 0...(words.count - length) {
                let phrase = MemoryText.squashed(words[start..<start + length].joined())
                guard !phrase.isEmpty else { continue }
                let hit = outside.first { company in
                    MemoryText.squashed(company.name) == phrase
                        || MemoryText.squashed(String(company.domain?.split(separator: ".").first ?? "")) == phrase
                }
                if let hit {
                    found.insert(hit.id)
                    words.replaceSubrange(start..<start + length, with: Array(repeating: "", count: length))
                }
            }
        }
        // "Harlow Museum" is also "Harlow" and "the museum", when no other company shares the word.
        var aliases: [String: Int64] = [:]
        var taken = Set<String>()
        for company in outside {
            for piece in MemoryText.words(company.name) where piece.count >= 4 && !MemoryText.stopWords.contains(piece) {
                if aliases[piece] != nil { taken.insert(piece) } else { aliases[piece] = company.id }
            }
        }
        for (index, word) in words.enumerated() {
            if let id = aliases[word] ?? aliases[MemoryText.stem(word)], !taken.contains(word) {
                found.insert(id)
                words[index] = ""
            }
        }
        // "Rootstock" for rootstockgardens.example, "the printer" for Kestrel Print: a word that starts a
        // company's name or domain, or that a name word starts, when only one company fits.
        for (index, word) in words.enumerated() where word.count >= 5 && !MemoryText.stopWords.contains(word) {
            let fits = outside.filter { company in
                let labels = [MemoryText.squashed(company.name), MemoryText.squashed(String(company.domain?.split(separator: ".").first ?? ""))]
                let pieces = MemoryText.words(company.name).filter { $0.count >= 5 }
                return labels.contains { !$0.isEmpty && $0.hasPrefix(word) } || pieces.contains { word.hasPrefix($0) }
            }
            if fits.count == 1, let id = fits.first?.id {
                found.insert(id)
                words[index] = ""
            }
        }
        return found
    }

    /// People other than the user named in `text` by full or first name.
    func people(namedIn text: String, preferring companies: Set<Int64>) -> Set<Int64> {
        let words = MemoryText.words(text)
        let joined = " " + words.joined(separator: " ") + " "
        var found = Set<Int64>()
        var firstNamesUsed = Set<String>()
        for person in people.values where !person.isSelf {
            let name = MemoryText.words(person.name)
            guard name.count > 1, joined.contains(" " + name.joined(separator: " ") + " ") else { continue }
            found.insert(person.id)
            firstNamesUsed.insert(name[0])
        }
        let wordSet = Set(words).subtracting(MemoryText.stopWords).subtracting(firstNamesUsed)
        for person in people.values where !person.isSelf {
            guard let first = MemoryText.words(person.name).first, wordSet.contains(first) else { continue }
            found.insert(person.id)
        }
        return found
    }
}
