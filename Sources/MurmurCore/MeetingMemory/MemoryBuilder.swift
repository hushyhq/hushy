import Foundation
import GRDB

/// Builds the memory rows from meeting records. Conflicts are settled here, once, at write time:
/// who a speaker is, which company a meeting is with, which later meeting closed an item, which
/// later decision replaced an earlier one. Questions then read settled rows.
struct MemoryBuilder {
    let records: [MeetingRecord]
    /// The user's names: "Sam Lee", and the words a summary uses for them ("You", "Me").
    let selfNames: [String]
    let settles: Bool

    private var companies: [Company] = []
    private var people: [Person] = []
    private var meetingPeople: [Int64: [(person: Int, role: String)]] = [:]
    private var meetingCompanies: [Int64: [(company: Int, via: String)]] = [:]
    private var turnPeople: [Int64: [Int: Int]] = [:]
    /// Per meeting, a speaker's first name → the full name and company they introduced themselves
    /// with ("Marcus Hale from Brightmoor Freight").
    private var introductions: [Int64: [String: (name: String, company: Int?)]] = [:]
    /// How rare each word is across these meetings, so closing an item weighs "printer minimum"
    /// above "check" and "lower".
    private var weights = StemWeights(documents: [])

    struct Company { var domain: String?; var name: String; var isOwn: Bool }
    struct Person { var key: String; var name: String; var company: Int?; var isSelf: Bool }

    init(records: [MeetingRecord], selfNames: [String], settles: Bool = true) {
        self.records = records.sorted { $0.start < $1.start }
        self.selfNames = selfNames
        self.settles = settles
    }

    static let selfWords: Set<String> = ["you", "me", "i", "myself"]

    var selfFirstNames: Set<String> {
        Set(selfNames.map(MemoryText.firstName).filter { !$0.isEmpty }).union(Self.selfWords)
    }

    func isSelf(_ name: String) -> Bool {
        let words = MemoryText.words(name)
        guard let first = words.first else { return false }
        if words.count == 1 { return selfFirstNames.contains(first) }
        return selfNames.contains { MemoryText.words($0) == words }
    }

    mutating func write(_ db: Database) throws {
        try MemorySchema.create(db)
        weights = StemWeights(documents: records.flatMap { record in
            record.turns.map { MemoryText.contentStems($0.text) } + record.decisions.map(MemoryText.contentStems)
                + record.actionItems.map { MemoryText.contentStems($0.task) }
        })
        collectCompanies()
        collectNamedCompanies()
        collectAttendees()
        for record in records { resolveSpeakers(record) }
        for record in records { resolveMentions(record) }
        try insertEntities(db)
        for record in records { try insertMeeting(record, db) }
        guard settles else { return }
        let links = linkedMeetings()
        try settleItems(db, links: links)
        try settleDecisions(db, links: links)
    }

    // MARK: Companies and people

    private mutating func collectCompanies() {
        let ownDomains = Set(records.flatMap { $0.attendees.filter(\.isSelf).compactMap(\.companyDomain) })
        let domains = Set(records.flatMap { $0.attendees.compactMap(\.companyDomain) })
        var vocabulary = Set<String>()
        for record in records {
            let texts: [String] = [record.title] + record.turns.map(\.text) + record.decisions + record.keyPoints
            for text in texts { vocabulary.formUnion(MemoryText.words(text).filter { $0.count >= 3 }) }
        }
        for domain in domains.sorted() {
            var name = Self.displayName(domain: domain, titles: records.map(\.title))
            if !name.contains(" "), let pieces = Self.segment(MemoryText.squashed(name), vocabulary: vocabulary), pieces.count > 1 {
                name = pieces.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
            companies.append(Company(domain: domain, name: name, isOwn: ownDomains.contains(domain)))
        }
    }

    /// Companies a meeting names without a calendar: "Marcus Hale from Brightmoor Freight" in a turn,
    /// or a capitalised name in the title ("Northvale intro call") that is also written capitalised
    /// mid-sentence somewhere, so "Pricing huddle" names no company. People's names are not companies.
    private mutating func collectNamedCompanies() {
        let personWords = Set(records.flatMap { record in
            record.attendees.flatMap { MemoryText.words($0.name) } + record.turns.compactMap(\.speaker).flatMap(MemoryText.words)
        }).union(selfFirstNames)
        let midSentence = Set(records.flatMap { $0.turns.flatMap { Self.capitalisedRuns(in: $0.text, skipFirst: true) } }
            .map(MemoryText.squashed))
        func add(_ name: String) -> Int? {
            let squashed = MemoryText.squashed(name)
            guard !squashed.isEmpty, !MemoryText.words(name).allSatisfy(personWords.contains) else { return nil }
            if let existing = companies.firstIndex(where: {
                MemoryText.squashed($0.name) == squashed || MemoryText.squashed(String($0.domain?.split(separator: ".").first ?? "")) == squashed
            }) { return existing }
            companies.append(Company(domain: nil, name: name, isOwn: false))
            return companies.count - 1
        }
        for record in records {
            for (ordinal, turn) in record.turns.enumerated() {
                guard let speaker = turn.speaker, let intro = Self.introduction(in: turn.text, speaker: speaker) else { continue }
                let company = intro.company.flatMap(add)
                introductions[record.noteId, default: [:]][MemoryText.firstName(speaker)] = (intro.name, company)
                _ = ordinal
            }
            for run in Self.capitalisedRuns(in: record.title, skipFirst: false) where midSentence.contains(MemoryText.squashed(run)) {
                _ = add(run)
            }
        }
    }

    /// "Marcus Hale from Brightmoor Freight", "It's Priya from Northvale", said by that person.
    static func introduction(in text: String, speaker: String) -> (name: String, company: String?)? {
        let pattern = #"\b([A-Z][a-z]+(?: [A-Z][a-z]+)?)(?:,)? (?:from|at|over at|here from|with) ([A-Z][A-Za-z0-9&]*(?: [A-Z][A-Za-z0-9&]*){0,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text), let companyRange = Range(match.range(at: 2), in: text) else { continue }
            let name = String(text[nameRange])
            guard MemoryText.firstName(name) == MemoryText.firstName(speaker) else { continue }
            return (name, String(text[companyRange]))
        }
        return nil
    }

    /// Runs of capitalised words ("Brightmoor Freight"), optionally skipping each sentence's first word.
    static func capitalisedRuns(in text: String, skipFirst: Bool) -> [String] {
        var runs: [String] = []
        for sentence in text.split(whereSeparator: { ".!?;:".contains($0) }) {
            let tokens = sentence.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "/" || $0 == "(" || $0 == ")" }).map(String.init)
            var current: [String] = []
            for (index, token) in tokens.enumerated() {
                let word = token.trimmingCharacters(in: .punctuationCharacters)
                let capitalised = word.first?.isUppercase == true && word.count > 1 && !(skipFirst && index == 0)
                    && !MemoryText.stopWords.contains(word.lowercased()) && word.rangeOfCharacter(from: .decimalDigits) == nil
                if capitalised { current.append(word) } else if !current.isEmpty { runs.append(current.joined(separator: " ")); current = [] }
            }
            if !current.isEmpty { runs.append(current.joined(separator: " ")) }
        }
        return runs
    }

    /// "harlowmuseum" → ["harlow", "museum"] when both words are said or written somewhere: the
    /// fewest pieces, each a word of the meetings.
    static func segment(_ label: String, vocabulary: Set<String>) -> [String]? {
        let characters = Array(label)
        guard characters.count >= 6 else { return nil }
        var best: [Int: [String]] = [0: []]
        for end in 1...characters.count {
            for start in 0..<end where end - start >= 3 {
                guard let prefix = best[start] else { continue }
                let piece = String(characters[start..<end])
                guard vocabulary.contains(piece) else { continue }
                if best[end] == nil || best[end]!.count > prefix.count + 1 { best[end] = prefix + [piece] }
            }
        }
        return best[characters.count]
    }

    /// "brightmoor-freight.com" → "Brightmoor Freight"; a title that spells the label out
    /// ("Brightmoorfreight" written "Brightmoor Freight") gives its spelling.
    static func displayName(domain: String, titles: [String]) -> String {
        let label = String(domain.split(separator: ".").first ?? Substring(domain))
        let target = MemoryText.squashed(label)
        for title in titles {
            let words = title.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "," }).map(String.init)
            for length in stride(from: min(3, words.count), through: 1, by: -1) {
                for start in 0...(words.count - length) {
                    let phrase = words[start..<start + length].joined(separator: " ")
                    if MemoryText.squashed(phrase) == target { return phrase.trimmingCharacters(in: .punctuationCharacters) }
                }
            }
        }
        return label.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func companyIndex(domain: String?) -> Int? {
        guard let domain else { return nil }
        return companies.firstIndex { $0.domain == domain }
    }

    private mutating func collectAttendees() {
        for record in records {
            for attendee in record.attendees {
                let company = companyIndex(domain: attendee.companyDomain)
                if let company, !companies[company].isOwn {
                    meetingCompanies[record.noteId, default: []].append((company, "attendee"))
                }
                guard !attendee.name.isEmpty else { continue }
                let person = attendee.isSelf || isSelf(attendee.name) ? selfPerson() : person(named: attendee.name, company: company)
                meetingPeople[record.noteId, default: []].append((person, "attendee"))
            }
            for company in mentionedCompanies(in: [record.title]) {
                meetingCompanies[record.noteId, default: []].append((company, "title"))
            }
        }
    }

    private mutating func selfPerson() -> Int {
        if let index = people.firstIndex(where: \.isSelf) { return index }
        people.append(Person(key: "self", name: selfNames.first ?? "You", company: nil, isSelf: true))
        return people.count - 1
    }

    private mutating func person(named name: String, company: Int?) -> Int {
        let key = MemoryText.words(name).joined(separator: " ")
        if let index = people.firstIndex(where: { $0.key == key }) {
            if people[index].company == nil { people[index].company = company }
            return index
        }
        people.append(Person(key: key, name: name, company: company, isSelf: false))
        return people.count - 1
    }

    /// Known companies named in `texts`, longest name first, so "Brightmoor Freight" is not also
    /// "Brightmoor".
    func mentionedCompanies(in texts: [String]) -> [Int] {
        var found: [Int] = []
        for text in texts {
            var words = MemoryText.words(text)
            for length in stride(from: 3, through: 1, by: -1) where words.count >= length {
                var start = 0
                while start + length <= words.count {
                    let phrase = MemoryText.squashed(words[start..<start + length].joined())
                    if !phrase.isEmpty, let company = companies.indices.first(where: {
                        !companies[$0].isOwn && (MemoryText.squashed(companies[$0].name) == phrase
                            || MemoryText.squashed(String(companies[$0].domain?.split(separator: ".").first ?? "")) == phrase)
                    }) {
                        if !found.contains(company) { found.append(company) }
                        words.replaceSubrange(start..<start + length, with: Array(repeating: "", count: length))
                    }
                    start += 1
                }
            }
        }
        return found
    }

    /// The person a first or full name refers to in this meeting: the user, an attendee, someone
    /// at a company the meeting is with, or the one person anywhere with that first name.
    func resolve(_ name: String, in noteId: Int64) -> Int? {
        if isSelf(name) { return people.firstIndex(where: \.isSelf) }
        var words = MemoryText.words(name)
        guard let first = words.first else { return nil }
        if words.count == 1, let intro = introductions[noteId]?[first] { words = MemoryText.words(intro.name) }
        let matches: (Int) -> Bool = { index in
            let key = self.people[index].key.split(separator: " ").map(String.init)
            return words.count > 1 ? key == words : key.first == first
        }
        let here = Set((meetingPeople[noteId] ?? []).map(\.person)).filter(matches)
        if here.count == 1 { return here.first }
        let companiesHere = Set((meetingCompanies[noteId] ?? []).map(\.company))
        let colleagues = people.indices.filter { matches($0) && people[$0].company.map(companiesHere.contains) == true }
        if colleagues.count == 1 { return colleagues[0] }
        // Someone at another outside company is not this meeting's Marcus.
        let anywhere = people.indices.filter { index in
            guard matches(index) else { return false }
            guard let company = people[index].company, !companies[company].isOwn else { return true }
            return companiesHere.isEmpty || companiesHere.contains(company)
        }
        return anywhere.count == 1 ? anywhere[0] : nil
    }

    private mutating func resolveSpeakers(_ record: MeetingRecord) {
        for company in mentionedCompanies(in: record.turns.map(\.text)) {
            meetingCompanies[record.noteId, default: []].append((company, "mentioned"))
        }
        for (ordinal, turn) in record.turns.enumerated() {
            guard let speaker = turn.speaker, !speaker.isEmpty else { continue }
            let intro = introductions[record.noteId]?[MemoryText.firstName(speaker)]
            let outside = Set((meetingCompanies[record.noteId] ?? []).map(\.company)).filter { !companies[$0].isOwn }
            let company = intro?.company ?? (outside.count == 1 ? outside.first : nil)
            let index = resolve(speaker, in: record.noteId) ?? person(named: intro?.name ?? speaker, company: company)
            turnPeople[record.noteId, default: [:]][ordinal] = index
            meetingPeople[record.noteId, default: []].append((index, "speaker"))
        }
    }

    /// Names said in the meeting that are known people. Only capitalised words count, so "will"
    /// and "mark" are not Will and Mark.
    private mutating func resolveMentions(_ record: MeetingRecord) {
        let firstNames = Set(people.filter { !$0.isSelf }.compactMap { $0.key.split(separator: " ").first.map(String.init) })
        var seen = Set((meetingPeople[record.noteId] ?? []).map(\.person))
        for turn in record.turns + record.decisions.map({ MeetingRecord.Turn(text: $0) })
            + record.actionItems.map({ MeetingRecord.Turn(text: $0.owner + " " + $0.task) }) {
            let capitalised = turn.text.split(whereSeparator: { !$0.isLetter && $0 != "'" })
                .filter { $0.first?.isUppercase == true }.map { MemoryText.words(String($0)).first ?? "" }
            for word in capitalised where firstNames.contains(word) {
                guard let index = resolve(word, in: record.noteId), seen.insert(index).inserted else { continue }
                meetingPeople[record.noteId, default: []].append((index, "mentioned"))
            }
        }
    }

    // MARK: Rows

    private func insertEntities(_ db: Database) throws {
        for (index, company) in companies.enumerated() {
            try db.execute(sql: "INSERT INTO company (id, domain, name, is_own) VALUES (?, ?, ?, ?)",
                           arguments: [index + 1, company.domain, company.name, company.isOwn])
        }
        for (index, person) in people.enumerated() {
            try db.execute(sql: "INSERT INTO person (id, key, name, company_id, is_self) VALUES (?, ?, ?, ?, ?)",
                           arguments: [index + 1, person.key, person.name, person.company.map { $0 + 1 }, person.isSelf])
        }
    }

    private func insertMeeting(_ record: MeetingRecord, _ db: Database) throws {
        let id = record.noteId
        let external = (meetingCompanies[id] ?? []).contains { !companies[$0.company].isOwn }
        let outsiders = (meetingPeople[id] ?? []).contains { entry in
            let person = people[entry.person]
            return !person.isSelf && person.company.map { companies[$0].isOwn } != true && entry.role == "attendee"
        }
        try db.execute(
            sql: #"INSERT INTO meeting (note_id, title, start, "end", series_key, is_internal) VALUES (?, ?, ?, ?, ?, ?)"#,
            arguments: [id, record.title, record.start.timeIntervalSince1970, record.end.timeIntervalSince1970,
                        record.seriesKey, !external && !outsiders && !record.attendees.isEmpty])
        for entry in meetingPeople[id] ?? [] {
            try db.execute(sql: "INSERT OR IGNORE INTO meeting_person VALUES (?, ?, ?)", arguments: [id, entry.person + 1, entry.role])
        }
        for entry in meetingCompanies[id] ?? [] {
            try db.execute(sql: "INSERT OR IGNORE INTO meeting_company VALUES (?, ?, ?)", arguments: [id, entry.company + 1, entry.via])
        }
        for (ordinal, turn) in record.turns.enumerated() {
            try db.execute(sql: "INSERT INTO turn VALUES (?, ?, ?, ?, ?, ?)", arguments: [
                id, ordinal, turn.speaker, turnPeople[id]?[ordinal].map { $0 + 1 }, turn.startSeconds, turn.text])
            try db.execute(sql: "INSERT INTO turn_fts (stems, note_id, ordinal) VALUES (?, ?, ?)",
                           arguments: [MemoryText.contentStems(turn.text).joined(separator: " "), id, ordinal])
        }
        let summaryText = ([record.title] + record.keyPoints + record.decisions + record.actionItems.map(\.task)).joined(separator: " ")
        try db.execute(sql: "INSERT INTO meeting_fts (stems, note_id) VALUES (?, ?)",
                       arguments: [MemoryText.contentStems(summaryText).joined(separator: " "), id])
        for (ordinal, decision) in record.decisions.enumerated() {
            try db.execute(sql: "INSERT INTO decision (note_id, ordinal, text, quote_turn) VALUES (?, ?, ?, ?)",
                           arguments: [id, ordinal, decision, Self.quoteTurn(for: decision, in: record.turns)])
        }
        for (ordinal, item) in record.actionItems.enumerated() {
            let owner = item.owner.isEmpty ? nil : resolve(item.owner, in: id)
            try db.execute(sql: """
                INSERT INTO action_item (note_id, ordinal, owner_text, owner_person_id, task, due, status, quote_turn)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, ordinal, item.owner, owner.map { $0 + 1 }, item.task, item.due,
                                 item.isDone ? "done" : "open", Self.quoteTurn(for: item.task, in: record.turns, speaker: item.owner)])
        }
    }

    /// The turn that best supports `text`: the most of its content words, ties to the owner's own
    /// turn, then the earliest. Nil when no turn shares at least a third of them.
    static func quoteTurn(for text: String, in turns: [MeetingRecord.Turn], speaker: String? = nil) -> Int? {
        let stems = MemoryText.contentStems(text)
        guard !stems.isEmpty else { return nil }
        var best: (ordinal: Int, score: Double)?
        for (ordinal, turn) in turns.enumerated() {
            var score = MemoryText.coverage(of: stems, in: Set(MemoryText.contentStems(turn.text)))
            guard score > 0 else { continue }
            if let speaker, !speaker.isEmpty, let said = turn.speaker,
               MemoryText.firstName(said) == MemoryText.firstName(speaker) { score += 0.05 }
            if best == nil || score > best!.score { best = (ordinal, score) }
        }
        guard let best, best.score >= 0.34 else { return nil }
        return best.ordinal
    }

    // MARK: Settling across meetings

    /// For each meeting, the later meetings it is linked to: the same series, an outside company,
    /// or a person other than the user (attendee or speaker).
    private func linkedMeetings() -> [Int64: [Int64]] {
        var keys: [Int64: Set<String>] = [:]
        for record in records {
            var set = Set<String>()
            if let series = record.seriesKey { set.insert("s:" + series) }
            for entry in meetingCompanies[record.noteId] ?? [] where !companies[entry.company].isOwn { set.insert("c:\(entry.company)") }
            for entry in meetingPeople[record.noteId] ?? [] where entry.role != "mentioned" && !people[entry.person].isSelf {
                set.insert("p:\(entry.person)")
            }
            keys[record.noteId] = set
        }
        var links: [Int64: [Int64]] = [:]
        for (index, record) in records.enumerated() {
            let mine = keys[record.noteId] ?? []
            links[record.noteId] = records[(index + 1)...].filter { !mine.isDisjoint(with: keys[$0.noteId] ?? []) }.map(\.noteId)
        }
        return links
    }

    /// Later meetings where an item may be closed: the linked ones, and any later one that names
    /// its owner ("Owen's press proof came yesterday" in a meeting Owen was not in).
    private func laterMeetings(naming owner: Int?, after noteId: Int64, linked: [Int64]) -> [Int64] {
        guard let owner, !people[owner].isSelf, let index = records.firstIndex(where: { $0.noteId == noteId }) else { return linked }
        let naming = records[(index + 1)...].map(\.noteId).filter { id in
            !linked.contains(id) && (meetingPeople[id] ?? []).contains { $0.person == owner }
        }
        return records.map(\.noteId).filter { linked.contains($0) || naming.contains($0) }
    }

    static let doneCues = [
        "sent", "send it over", "finished", "completed", "shipped", "signed", "submitted", "delivered", "uploaded",
        "shared it", "shared the", "emailed", "booked", "closed out", "wrapped up", "handled", "posted", "published",
        "merged", "filed", "is done", "'s done", "are done", "all done", "took care", "went out", "landed", "approved",
        "already", "got it to", "got that to", "got them to", "it's in", "is in your inbox", "came through", "dealt with",
        "that's covered", "is covered", "all set", "sorted", "taken care", "check your inbox", "in the shared drive",
        "received", "got the", "got your", "we have it", "came in", "in your inbox", "shared folder", "in figma", "is up",
        "is live", "is ready", "are ready", "here's the", "here is the", "attached", "came down", "went out", "countersigned",
        "done and dusted", "we're good on", "good to go", "thanks for the", "arrived", "came", "got it",
    ]
    static let cancelCues = [
        "no longer need", "don't need", "do not need", "not needed", "scrap", "scratch", "drop the", "dropping the",
        "cancel", "forget the", "off the table", "won't need", "skip the", "kill the", "not doing the", "shelve",
    ]

    enum Closure { case done, cancelled }

    /// Done or dropped, by what `text` says about `task`: a cue ("sent", "already", "no longer
    /// need"), or the task's own verb in the past ("Confirm the timeline" → "confirmed",
    /// "Share the sheet" → "thanks for sharing").
    static func closure(in text: String, task: String = "") -> Closure? {
        let sentences = text.split(whereSeparator: { ".!?;".contains($0) }).map(String.init)
        if sentences.count > 1 {
            let found = sentences.compactMap { closure(inSentence: $0, task: task) }
            return found.contains(.cancelled) ? .cancelled : found.first
        }
        return closure(inSentence: text, task: task)
    }

    static let futureMarkers = ["'ll", " will ", " going to ", " gonna ", " once ", " after ", " when ", " if ", " need to ",
                                " needs to ", " have to ", " has to ", " should ", " could you ", " can you ", " please "]

    static func closure(inSentence text: String, task: String) -> Closure? {
        let spaced = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let words = MemoryText.words(text)
        let lowered = " " + words.joined(separator: " ") + " "
        let has: (String) -> Bool = { lowered.contains(" " + MemoryText.words($0).joined(separator: " ") + " ") }
        if cancelCues.contains(where: has) { return .cancelled }
        // "I'll send it once the contract is approved" closes nothing.
        if futureMarkers.contains(where: spaced.contains), !has("already") { return nil }
        if doneCues.contains(where: has) { return .done }
        guard let verb = MemoryText.words(task).first, verb.count > 2 else { return nil }
        let pasts = pastForms(of: verb)
        if words.contains(where: pasts.contains) { return .done }
        let gerund = verb.hasSuffix("e") ? String(verb.dropLast()) + "ing" : verb + "ing"
        return lowered.contains(" thanks for \(gerund) ") || lowered.contains(" thank you for \(gerund) ") ? .done : nil
    }

    static func pastForms(of verb: String) -> Set<String> {
        var forms: Set<String> = verb.hasSuffix("e") ? [verb + "d"] : [verb + "ed"]
        if verb.hasSuffix("y"), verb.count > 3 { forms.insert(String(verb.dropLast()) + "ied") }
        for (past, base) in MemoryText.irregular where base == verb { forms.insert(past) }
        return forms
    }

    /// An open item counts as closed by a later turn that carries most of its words and says it is
    /// done or dropped; a later summary item that restates it is the same item.
    private func settleItems(_ db: Database, links: [Int64: [Int64]]) throws {
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.noteId, $0) })
        let items = try Row.fetchAll(db, sql: "SELECT id, note_id, task, owner_person_id, status, quote_turn FROM action_item ORDER BY id")
        var merged = Set<Int64>()
        for item in items {
            let id: Int64 = item["id"]
            guard !merged.contains(id) else { continue }
            let noteId: Int64 = item["note_id"]
            let task: String = item["task"]
            let stems = MemoryText.contentStems(task)
            let needed = min(2, stems.count)
            guard needed > 0 else { continue }
            var status: String = item["status"]
            let quoteTurn: Int? = item["quote_turn"]
            // Dropped later in the same meeting ("Actually, scrap the totes"), or closed in a later one.
            let owner: Int64? = item["owner_person_id"]
            let later = laterMeetings(naming: owner.map { Int($0) - 1 }, after: noteId, linked: links[noteId] ?? [])
            let places = (quoteTurn.map { [(noteId, $0 + 1)] } ?? []) + later.map { ($0, 0) }
            for (index, place) in places.enumerated() {
                guard status == "open", let record = byId[place.0] else { break }
                if let (ordinal, closure) = Self.closingTurn(task: task, stems: stems, needed: needed, in: record.turns, from: place.1, weights: weights) {
                    status = closure == .done ? "done" : "cancelled"
                    try db.execute(sql: "UPDATE action_item SET status = ?, closed_note_id = ?, closed_turn = ? WHERE id = ?",
                                   arguments: [status, place.0, ordinal, id])
                }
                if index == 0, quoteTurn != nil { continue }
                let later = place.0
                let restated = try Row.fetchAll(db, sql: "SELECT id, task, status, owner_person_id FROM action_item WHERE note_id = ?", arguments: [later])
                for row in restated {
                    let other: Int64? = row["owner_person_id"]
                    guard other == owner, weights.coverage(of: stems, in: Set(MemoryText.contentStems(row["task"]))) >= 0.6 else { continue }
                    let rowId: Int64 = row["id"]
                    merged.insert(rowId)
                    try db.execute(sql: "UPDATE action_item SET duplicate_of = ? WHERE id = ?", arguments: [id, rowId])
                    if (row["status"] as String) == "done", status == "open" {
                        status = "done"
                        try db.execute(sql: "UPDATE action_item SET status = 'done', closed_note_id = ? WHERE id = ?", arguments: [later, id])
                    }
                }
            }
        }
    }

    /// The first turn from `start` on that says the task is done or dropped: it carries most of the
    /// task's words (the question just before it counts: "Did you send that checklist?" / "Yes, I
    /// sent it"), or its main noun ("the glossary, that's in your inbox").
    static func closingTurn(task: String, stems: [String], needed: Int, in turns: [MeetingRecord.Turn], from start: Int,
                            weights: StemWeights? = nil) -> (Int, Closure)? {
        guard start < turns.count else { return nil }
        let head = headNoun(task)
        for ordinal in start..<turns.count {
            let text = turns[ordinal].text
            let previous = ordinal > 0 ? turns[ordinal - 1].text : ""
            let turnStems = Set(MemoryText.contentStems(previous + " " + text))
            let shared = stems.filter(turnStems.contains).count
            let byWords = (shared >= needed && MemoryText.coverage(of: stems, in: turnStems) >= 0.5)
                || (weights.map { shared >= 1 && $0.coverage(of: stems, in: turnStems) >= 0.5 } ?? false)
            let byHead = head.map { Set(MemoryText.contentStems(text)).contains($0) } ?? false
            guard byWords || byHead, let closure = closure(in: text, task: task) else { continue }
            return (ordinal, closure)
        }
        return nil
    }

    /// The task's object: the last content word before "for", "to", "so" and the like
    /// ("Send the API docs for the balance endpoint" → "doc").
    static func headNoun(_ task: String) -> String? {
        let words = MemoryText.words(task)
        let cut = words.dropFirst().firstIndex { ["for", "to", "so", "with", "by", "from", "on", "in", "about", "that", "which", "and", "if", "whether", "before", "after"].contains($0) } ?? words.endIndex
        let object = words[words.index(after: words.startIndex)..<cut].filter { !MemoryText.stopWords.contains($0) }
        guard object.count >= 1, let last = object.last, last.count >= 4 else { return nil }
        return MemoryText.stem(last)
    }

    /// A later decision in a linked meeting about the same subject (most of the same words once
    /// numbers and dates are set aside) replaces the earlier one.
    private func settleDecisions(_ db: Database, links: [Int64: [Int64]]) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, note_id, text FROM decision ORDER BY id")
        let decisions = rows.map { (id: $0["id"] as Int64, note: $0["note_id"] as Int64, text: $0["text"] as String) }
        for decision in decisions {
            let subject = MemoryText.subjectStems(decision.text)
            let later = Set(links[decision.note] ?? [])
            let replacement = decisions.first { other in
                guard later.contains(other.note), MemoryText.words(other.text) != MemoryText.words(decision.text) else { return false }
                let otherSubject = MemoryText.subjectStems(other.text)
                // The same kind of value (a price for a price, a date for a date), about mostly the same words.
                let kind = MemoryText.valueKind(decision.text), otherKind = MemoryText.valueKind(other.text)
                if let kind, let otherKind, kind != otherKind { return false }
                let shared = subject.intersection(otherSubject).count
                let smaller = max(1, min(subject.count, otherSubject.count))
                if shared >= 2 { return Double(shared) / Double(smaller) >= 0.6 }
                return shared == 1 && smaller == 1 && kind != nil && kind == otherKind
            }
            if let replacement {
                try db.execute(sql: "UPDATE decision SET superseded_by = ? WHERE id = ?", arguments: [replacement.id, decision.id])
            }
        }
    }
}
