import Foundation

/// One thing of the user's own that an answer can be grounded in: a Hushy note, a dictation, a
/// Reminders list, a day of the calendar, an Apple Note. Everything the answer says must come
/// from one of these, and the card names it ("From your note 'Groceries', Sep 26").
public struct OwnStuffItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case note, dictation, reminderList, calendarDay, appleNote
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// The searchable text: the transcript, the list's items one per line, the day's events.
    public var body: String
    public var date: Date?
    /// A deep link to the source, when one exists (Hushy notes: `hushy://note/<id>`; Apple
    /// Notes / Reminders / Calendar: the app).
    public var openURL: URL?

    public init(id: String, kind: Kind, title: String, body: String, date: Date? = nil, openURL: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.date = date
        self.openURL = openURL
    }

    /// "your note 'Groceries'", "your Reminders list 'Groceries'", "your calendar for Tuesday".
    public func sourceLabel(context: DateContext = .current()) -> String {
        let quoted = "'\(title)'"
        switch kind {
        case .note: return "your note \(quoted)"
        case .dictation: return "your dictation \(quoted)"
        case .reminderList: return "your Reminders list \(quoted)"
        case .calendarDay: return "your calendar for \(title)"
        case .appleNote: return "your Apple Note \(quoted)"
        }
    }

    /// "Sep 26" for the source line.
    public func dateLabel(context: DateContext = .current()) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}

/// What to look for: the question, its keywords, and the day window it names, if any.
public struct OwnStuffQuery: Sendable, Equatable {
    public let question: String
    public let keywords: [String]
    public let dateWindow: DateInterval?
    public let context: DateContext

    public init(question: String, context: DateContext) {
        self.question = question
        self.context = context
        self.keywords = OwnStuffRetriever.keywords(in: question)
        self.dateWindow = OwnStuffRetriever.dateWindow(in: question, context: context)
    }
}

/// A place to look. Each source is local (Hushy's store, EventKit, Apple Notes via Automation)
/// and returns candidates; `OwnStuffRetriever.rank` picks the few that matter.
public protocol OwnStuffSource: Sendable {
    var name: String { get }
    func search(_ query: OwnStuffQuery) async -> [OwnStuffItem]
}

/// Keyword-first retrieval (grep before embeddings): the question's content words are matched
/// against titles and bodies, titles count triple, recency breaks ties. Embeddings can slot in
/// later behind the same `rank` if keyword recall proves short; the eval will say.
public enum OwnStuffRetriever {
    public static let maxResults = 5

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by", "is", "are",
        "was", "were", "be", "been", "do", "did", "does", "have", "has", "had", "i", "my", "me", "we", "our", "us",
        "you", "your", "it", "its", "this", "that", "these", "those", "what", "what's", "whats", "when", "where",
        "which", "who", "how", "many", "much", "any", "there", "need", "needs", "want", "get", "got", "show", "find",
        "tell", "look", "up", "check", "please", "hushy", "again", "still", "yet", "also", "so", "just",
        "like", "some", "thing", "things", "stuff", "everything", "anything", "should", "would", "could", "can",
        "will", "am", "if", "then", "than", "as", "not", "no", "yes", "into", "out", "over", "under", "off",
    ]

    /// Content words of the question, de-duplicated, in order, with a crude singular form.
    public static func keywords(in question: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        // "to do" is one word for retrieval ("todo" list), not two stop words.
        let normalized = AskRouter.normalize(question).replacingOccurrences(of: "to do", with: "todo")
        for raw in normalized.split(separator: " ") {
            let word = singular(String(raw))
            guard word.count > 1, !stopWords.contains(word), !stopWords.contains(String(raw)), seen.insert(word).inserted else { continue }
            result.append(word)
        }
        return result
    }

    /// "groceries" → "grocerie" and "grocery" → "grocery" don't meet; strip a trailing "ies"/"s"
    /// to a shared stem instead ("groceri").
    static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "i" }
        if word.hasSuffix("y"), word.count > 3 { return String(word.dropLast()) + "i" }
        if word.hasSuffix("ss") { return word }
        if word.hasSuffix("s"), word.count > 3 { return String(word.dropLast()) }
        return word
    }

    /// The day window a question names ("tomorrow", "this weekend", "on friday"), if any.
    public static func dateWindow(in question: String, context: DateContext) -> DateInterval? {
        let lowered = question.lowercased()
        let calendar = context.calendar
        if lowered.contains("this weekend") || lowered.contains("the weekend") || lowered.contains("on the weekend") {
            return weekend(from: context.now, calendar: calendar)
        }
        if lowered.contains("this week") { return week(of: context.now, calendar: calendar) }
        if lowered.contains("next week") {
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: context.now) else { return nil }
            return week(of: next, calendar: calendar)
        }
        guard let anchor = DateAnchor.firstDate(in: question, context: context) else { return nil }
        let start = calendar.startOfDay(for: anchor.start)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func weekend(from now: Date, calendar: Calendar) -> DateInterval? {
        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday … 7 = Saturday
        let daysToSaturday = weekday == 1 ? -1 : (7 - weekday)
        let today = calendar.startOfDay(for: now)
        guard let saturday = calendar.date(byAdding: .day, value: daysToSaturday, to: today),
              let monday = calendar.date(byAdding: .day, value: 2, to: saturday) else { return nil }
        return DateInterval(start: saturday, end: monday)
    }

    static func week(of date: Date, calendar: Calendar) -> DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: date)
    }

    /// Scores and orders candidates; drops anything with no keyword hit unless the question
    /// named a day and the item is a calendar day or a note from that day.
    public static func rank(_ items: [OwnStuffItem], for query: OwnStuffQuery, limit: Int = maxResults) -> [OwnStuffItem] {
        let scored = items.map { item -> (OwnStuffItem, Int) in (item, score(item, query: query)) }
        return scored.filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return (lhs.0.date ?? .distantPast) > (rhs.0.date ?? .distantPast)
            }
            .prefix(limit).map(\.0)
    }

    static func score(_ item: OwnStuffItem, query: OwnStuffQuery) -> Int {
        let title = AskRouter.normalize(item.title).replacingOccurrences(of: "to do", with: "todo")
        let body = AskRouter.normalize(item.body).replacingOccurrences(of: "to do", with: "todo")
        var score = 0
        for keyword in query.keywords {
            if title.contains(keyword) { score += 3 }
            if body.contains(keyword) { score += 1 }
        }
        if let window = query.dateWindow, let date = item.date, window.contains(date) {
            score += item.kind == .calendarDay ? 4 : 1
        }
        return score
    }
}
