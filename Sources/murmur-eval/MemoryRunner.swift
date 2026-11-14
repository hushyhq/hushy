import Foundation
import MurmurCore

/// Questions across meetings (`Evals/meeting-memory/README.md`):
///
///   murmur-eval memory --dataset Evals/meeting-memory/dev.json [--answerer memory|legacy]
///       [--no-calendar] [--no-settle] [--phrase --backend mlx --mlx-model DIR] [--backend apple|none]
///       [--tz America/Los_Angeles] [--show N] [--report out.json] [--dump]
///
/// `memory` answers in code from the rows (`MeetingMemory`); `legacy` is main's single-note
/// answerer (`OwnStuffAnswerer`: keyword retrieval, the local model citing one note). Both run on a
/// temporary store seeded from the set. A case is complete when every fact is in some answer line
/// (citing the fact's meeting when it names one), no forbidden phrase is in any line, and a decline
/// is given exactly when the case expects one.
enum MemoryRunner {
    struct Answer {
        var lines: [(text: String, meeting: String?, hasQuote: Bool, supported: Bool)]
        var declined: Bool
        var invented: Int = 0
    }

    static func run(_ args: Arguments) async throws {
        let path = args.string("dataset") ?? "Evals/meeting-memory/dev.json"
        let url = URL(fileURLWithPath: path)
        try SealedEvalGuard.assertTuningSafe(url, purpose: "meeting memory eval")
        let set = try MeetingMemoryFixture.load(url)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-memory-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try Store(url: home.appendingPathComponent("hushy.sqlite"))
        let ids = try set.seed(into: store)
        let timeZone = TimeZone(identifier: args.string("tz") ?? "America/Los_Angeles") ?? .current
        let answerer = args.string("answerer") ?? "memory"
        let options = MeetingMemory.Options(calendarLinks: !args.flag("no-calendar"), settle: !args.flag("no-settle"))
        let buildStarted = Date()
        let memory = try MeetingMemory.build(from: store, selfNames: [set.me.name], options: options,
                                             url: args.string("db").map { URL(fileURLWithPath: $0) })
        FileHandle.standardError.write(Data(String(format: "memory built from %d meetings in %.2f s\n", memory.meetings.count, Date().timeIntervalSince(buildStarted)).utf8))
        let phraser = args.flag("phrase") ? MemoryPhraser(model: try args.languageModel()) : nil
        let legacy = answerer == "legacy" ? OwnStuffAnswerer(sources: [LegacyNotesSource(store: store)], model: try args.languageModel()) : nil

        var rows: [Row] = []
        var latencies: [Double] = []
        for item in set.cases {
            let context = DateContext(now: MeetingMemoryFixtureDates.date(item.now), timeZone: timeZone, locale: Locale(identifier: "en_US"))
            let started = Date()
            let answer: Answer
            if let legacy {
                answer = legacyAnswer(await legacy.answer(item.question, context: context), ids: ids)
            } else {
                var result = memory.ask(item.question, context: context, upcoming: set.upcomingEvents)
                var invented = 0
                if let phraser {
                    let phrased = await phraser.phrase(result, question: item.question, context: context)
                    invented = phrased.invented
                    result = phrased.answer
                }
                answer = memoryAnswer(result, ids: ids, context: context, invented: invented)
                if args.flag("dump") {
                    print("## \(item.id) [\(item.kind)] \(item.question)\n\(result.plainText(context: context))\n")
                }
            }
            latencies.append(Date().timeIntervalSince(started))
            rows.append(score(item, answer))
        }
        print(report(set: set, rows: rows, answerer: answerer + (args.flag("no-calendar") ? " no-calendar" : "")
            + (args.flag("no-settle") ? " no-settle" : "") + (phraser != nil ? " phrased" : ""), latencies: latencies, show: args.int("show") ?? 15))
        print(recordCoverage(set))
        if let out = args.string("report") {
            let json: [String: Any] = ["name": set.name, "cases": rows.map { ["id": $0.id, "passed": $0.complete, "kind": $0.kind,
                                                                                "facts": $0.found, "of": $0.total, "forbidden": $0.forbidden] }]
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
    }

    // MARK: Answers as lines

    static func memoryAnswer(_ answer: MemoryAnswer, ids: [Int64: String], context: DateContext, invented: Int) -> Answer {
        let lines = answer.lines.map { line -> (String, String?, Bool, Bool) in
            let date = longDate(line.meeting.start, context: context)
            let supported = line.quote.map { quote in
                !Set(MemoryTextProbe.stems(quote.text)).isDisjoint(with: MemoryTextProbe.stems(line.text))
            } ?? false
            return ("\(line.text) · \(line.meeting.title) · \(date)", ids[line.meeting.noteId], line.quote != nil, supported)
        }
        return Answer(lines: lines.map { (text: $0.0, meeting: $0.1, hasQuote: $0.2, supported: $0.3) }, declined: answer.isDecline, invented: invented)
    }

    static func legacyAnswer(_ result: Result<AskAnswer, AskFailure>, ids: [Int64: String]) -> Answer {
        switch result {
        case .failure: return Answer(lines: [], declined: true)
        case .success(let answer):
            let noteId = Int64(answer.source.id.replacingOccurrences(of: "note-", with: ""))
            let meeting = noteId.flatMap { ids[$0] }
            let texts = [answer.text] + answer.items
            return Answer(lines: texts.map { (text: $0 + " · " + answer.source.title, meeting: meeting, hasQuote: false, supported: false) },
                          declined: false)
        }
    }

    static func longDate(_ date: Date, context: DateContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.dateFormat = "MMM d MMMM yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Scoring

    struct Row {
        var id: String
        var kind: String
        var complete: Bool
        var found: Int
        var total: Int
        var forbidden: Int
        var declineRight: Bool
        var lines: Int
        var quoted: Int
        var supported: Int
        var invented: Int
        var note: String
    }

    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "fifteen": "15", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90", "hundred": "100",
    ]

    /// Words of `text`, lowercased, punctuation and "$" dropped, with digit forms of number words added.
    static func wordSet(_ text: String) -> Set<String> {
        var words = Set(MemoryTextProbe.words(text))
        for word in words { if let digit = numberWords[word] { words.insert(digit) } }
        for (word, digit) in numberWords where words.contains(digit) { words.insert(word) }
        return words
    }

    static func matches(_ phrase: String, _ line: Set<String>) -> Bool {
        let needed = Set(MemoryTextProbe.words(phrase)).map { numberWords[$0] ?? $0 }
        return !needed.isEmpty && needed.allSatisfy(line.contains)
    }

    static func score(_ item: MeetingMemoryFixture.Case, _ answer: Answer) -> Row {
        let lines = answer.lines.map { (words: wordSet($0.text), meeting: $0.meeting) }
        var missed: [String] = []
        var found = 0
        for fact in item.facts {
            let hit = lines.contains { line in
                (fact.meeting == nil || fact.meeting == line.meeting) && fact.any.contains { matches($0, line.words) }
            }
            if hit { found += 1 } else { missed.append(fact.any.first ?? "?") }
        }
        let forbiddenHits = item.forbidden.filter { phrase in lines.contains { matches(phrase, $0.words) } }
        let declineRight = item.decline ? answer.declined : !answer.declined
        let complete = found == item.facts.count && forbiddenHits.isEmpty && declineRight
        var notes: [String] = []
        if !declineRight { notes.append(item.decline ? "answered, wanted a decline" : "declined") }
        if !missed.isEmpty { notes.append("missed \(missed)") }
        if !forbiddenHits.isEmpty { notes.append("forbidden \(forbiddenHits)") }
        return Row(id: item.id, kind: item.kind, complete: complete, found: found, total: item.facts.count,
                   forbidden: forbiddenHits.count, declineRight: declineRight, lines: answer.lines.count,
                   quoted: answer.lines.filter(\.hasQuote).count, supported: answer.lines.filter(\.supported).count,
                   invented: answer.invented, note: notes.joined(separator: "; "))
    }

    static func report(set: MeetingMemoryFixture, rows: [Row], answerer: String, latencies: [Double], show: Int) -> String {
        func pct(_ part: Int, _ whole: Int) -> String { whole == 0 ? "–" : String(format: "%.0f%%", Double(part) / Double(whole) * 100) }
        var out = ["### Meeting memory · \(set.name) · \(answerer) · \(rows.count) cases", "",
                   "| kind | complete | facts found | forbidden lines | wrong decline/answer | n |", "|---|---|---|---|---|---|"]
        let kinds = Dictionary(grouping: rows, by: \.kind).sorted { $0.key < $1.key }
        for (kind, group) in kinds + [("**all**", rows)] {
            let found = group.reduce(0) { $0 + $1.found }, total = group.reduce(0) { $0 + $1.total }
            out.append("| \(kind) | \(group.filter(\.complete).count)/\(group.count) | \(found)/\(total) (\(pct(found, total))) | "
                + "\(group.reduce(0) { $0 + $1.forbidden }) | \(group.filter { !$0.declineRight }.count) | \(group.count) |")
        }
        let lines = rows.reduce(0) { $0 + $1.lines }
        let sorted = latencies.sorted()
        out.append("")
        out.append("Lines: \(lines); with a quote anchor \(pct(rows.reduce(0) { $0 + $1.quoted }, lines)); quote shares a word with the line "
            + "\(pct(rows.reduce(0) { $0 + $1.supported }, lines)); invented by phrasing \(rows.reduce(0) { $0 + $1.invented }). "
            + "Latency p50 \(String(format: "%.2f", sorted.isEmpty ? 0 : sorted[sorted.count / 2])) s, max \(String(format: "%.2f", sorted.last ?? 0)) s.")
        let misses = rows.filter { !$0.complete }
        if !misses.isEmpty {
            out.append("")
            out.append("Incomplete (\(misses.count)):")
            for row in misses.prefix(show) { out.append("- \(row.id) [\(row.kind)]: \(row.note)") }
        }
        return out.joined(separator: "\n")
    }

    /// Of the facts that name a meeting, how many are in that meeting's stored rows (summary
    /// decisions and items) rather than only in what was said: the ceiling for row-only answers.
    static func recordCoverage(_ set: MeetingMemoryFixture) -> String {
        let byId = Dictionary(uniqueKeysWithValues: set.meetings.map { ($0.id, $0) })
        var inRows = 0, inTurns = 0, total = 0
        for item in set.cases { for fact in item.facts {
            guard let id = fact.meeting, let meeting = byId[id] else { continue }
            total += 1
            let rows = meeting.summary.decisions + meeting.summary.actionItems.map { "\($0.owner) \($0.task) \($0.due)" } + [meeting.title]
            if rows.contains(where: { row in fact.any.contains { matches($0, wordSet(row)) } }) { inRows += 1 }
            else if meeting.turns.contains(where: { turn in fact.any.contains { matches($0, wordSet(turn.text)) } }) { inTurns += 1 }
        } }
        return "Record coverage: of \(total) meeting-cited facts, \(inRows) are in stored rows, \(inTurns) only in turns, \(total - inRows - inTurns) in neither (dates, metadata)."
    }
}

enum MeetingMemoryFixtureDates {
    static func date(_ text: String) -> Date { ProposalFields.parseISO8601(text) ?? Date() }
}

/// The word rules the scorer shares with memory, kept here so the eval does not reach into internals.
enum MemoryTextProbe {
    /// Punctuation is ignored, so a thousands separator is too: "$6,000" is "6000".
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"(?<=\d),(?=\d{3}\b)"#, with: "", options: .regularExpression)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }
            .filter { !$0.isEmpty }
    }

    static let stop: Set<String> = ["the", "a", "an", "to", "of", "and", "for", "on", "in", "by", "is", "it", "we", "i", "you", "that", "this", "with"]

    static func stems(_ text: String) -> Set<String> {
        Set(words(text).filter { !stop.contains($0) }.map { $0.count > 4 ? String($0.prefix(4)) : $0 })
    }
}

/// Main's notes source for the single-note answerer, as `StoreOwnStuffSource` in the app builds it.
struct LegacyNotesSource: OwnStuffSource {
    let name = "hushy"
    let store: Store

    func search(_ query: OwnStuffQuery) async -> [OwnStuffItem] {
        let terms = query.keywords.joined(separator: " ")
        let notes = ((try? store.searchNotes(terms, limit: 20)) ?? []) + ((try? store.notes(limit: 30)) ?? [])
        var items: [OwnStuffItem] = []
        for note in notes where note.status == .ready {
            guard let id = note.id, !items.contains(where: { $0.id == "note-\(id)" }) else { continue }
            var parts: [String] = []
            if !note.summary.isEmpty { parts.append(note.summary) }
            if !note.actionItems.isEmpty { parts.append(note.actionItems.map { "- \($0)" }.joined(separator: "\n")) }
            parts.append(String(note.transcript.prefix(4_000)))
            items.append(OwnStuffItem(id: "note-\(id)", kind: .note, title: note.title, body: parts.joined(separator: "\n"), date: note.createdAt))
        }
        return items
    }
}
