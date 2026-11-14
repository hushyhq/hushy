import Foundation
import GRDB

/// Answers composed in code from settled rows. Every line is one row with its meeting and quote;
/// nothing is merged by a model.
extension MeetingMemory {
    /// Answers a spoken or typed question. `upcoming`: the calendar's next events, for "prep me".
    public func ask(_ question: String, context: DateContext, upcoming: [CalendarEvent] = []) -> MemoryAnswer {
        var parsed = MemoryQuestion.parse(question, memory: self, context: context)
        if parsed.people.isEmpty, parsed.companies.isEmpty, let name = parsed.unknownNames.first, parsed.intent != .prep {
            return .decline(.none, "I have no meetings with or about \(name).")
        }
        parsed.intent = settledIntent(parsed, question: question, upcoming: upcoming, context: context)
        switch parsed.intent {
        case .decisions: return decisions(parsed, context: context)
        case .commitments: return commitments(parsed, context: context)
        case .changes: return changes(parsed, context: context)
        case .prep: return prep(parsed, upcoming: upcoming, context: context)
        case .search: return search(parsed, context: context)
        }
    }

    /// The intent read from the rows when the words leave it open: a question that points ahead
    /// ("before Monday's review with Brightwater") at an event on the calendar is prep; a question
    /// that names someone whose open items carry its words ("what's Viktor still got to send me")
    /// is about commitments.
    func settledIntent(_ question: MemoryQuestion, question text: String, upcoming: [CalendarEvent], context: DateContext) -> MemoryQuestion.Intent {
        guard question.intent == .search || question.intent == .decisions else { return question.intent }
        let words = Set(MemoryText.words(text))
        let ahead = question.upcomingDay != nil || !words.isDisjoint(with: ["before", "tomorrow", "next", "upcoming", "ahead"])
        if ahead, question.intent == .search, !matchingEvents(question, upcoming: upcoming, context: context).isEmpty {
            return .prep
        }
        let named = !question.people.isEmpty || !question.companies.isEmpty
        guard question.intent == .search, named, !question.topic.isEmpty else { return question.intent }
        let targets = targets(question)
        let selfId = selfPerson?.id
        let scoped = scope(question, useTopic: false).ids ?? []
        let theirs = openItems(before: context.now).filter { item in
            guard let owner = item.ownerId else { return false }
            return targets.contains(owner) || (owner == selfId && scoped.contains(item.noteId))
        }
        let carries = theirs.contains { weights.coverage(of: question.topicGroups, in: Set(MemoryText.contentStems($0.task))) >= 0.5 }
        return carries ? .commitments : .search
    }

    // MARK: Scope

    /// The meetings the question is about, or nil when it names nobody and no meeting. Topic words
    /// that appear in meeting titles name meetings ("the pricing huddle", "the last weekly sync");
    /// the rest (`leftover`) narrow what is said in them.
    func scope(_ question: MemoryQuestion, useTopic: Bool) -> (ids: Set<Int64>?, leftover: [String]) {
        var ids = Set<Int64>()
        let named = !question.people.isEmpty || !question.companies.isEmpty
        for meeting in meetings.values {
            if !question.people.isDisjoint(with: meeting.people.keys) { ids.insert(meeting.id) }
            if !question.companies.isDisjoint(with: meeting.companies) { ids.insert(meeting.id) }
            let companyPeople = meeting.people.keys.compactMap { people[$0]?.companyId }
            if !question.companies.isDisjoint(with: companyPeople) { ids.insert(meeting.id) }
        }
        let titleStems = meetings.mapValues { Set(MemoryText.contentStems($0.title)) }
        let allTitleStems = titleStems.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let titleTopic = question.topic.filter(allTitleStems.contains)
        let leftover = question.topic.filter { !titleTopic.contains($0) }
        if !titleTopic.isEmpty {
            let titled = Set(titleStems.filter { titleTopic.allSatisfy($0.value.contains) }.keys)
            let chosen = named ? titled.intersection(ids) : titled
            if !chosen.isEmpty { return (chosen, leftover) }
        }
        if named { return (ids, question.topic) }
        guard useTopic, !question.topic.isEmpty else { return (nil, question.topic) }
        let about = meetingsAbout(question.topic)
        return (about.isEmpty ? nil : about, question.topic)
    }

    /// The question's meetings in time order, cut to its window or to its first or last one.
    func chosenMeetings(_ question: MemoryQuestion, _ ids: Set<Int64>, now: Date) -> [MemoryMeeting] {
        let sorted = sortedMeetings(ids, before: now).filter { inTime($0, question.time) }
        switch question.ordinal {
        case .first: return sorted.first.map { [$0] } ?? []
        case .last: return sorted.last.map { [$0] } ?? []
        case nil: return sorted
        }
    }

    func inTime(_ meeting: MemoryMeeting, _ time: MemoryDates.Reference?) -> Bool {
        switch time {
        case .window(let window): window.contains(meeting.start)
        case .since(let date): meeting.start >= date
        case nil: true
        }
    }

    func describe(_ question: MemoryQuestion) -> String {
        let names = question.companies.compactMap { companies[$0]?.name } + question.people.compactMap { people[$0]?.name }
        if !names.isEmpty { return "with " + names.sorted().joined(separator: " and ") }
        let words = question.topicWords.filter { $0 != "|" }
        return words.isEmpty ? "" : "about \(words.joined(separator: " "))"
    }

    func sortedMeetings(_ ids: Set<Int64>, before now: Date) -> [MemoryMeeting] {
        ids.compactMap { meetings[$0] }.filter { $0.start <= now }.sorted { $0.start < $1.start }
    }

    // MARK: Decisions

    func decisionLine(_ decision: MemoryDecision, context: DateContext, showCurrentOnly: Bool) -> MemoryLine {
        var text = decision.text
        if let next = decision.supersededBy.flatMap(decision(id:)), !showCurrentOnly {
            text += " (changed later, \(MemoryDates.label(ref(current(of: next).noteId).start, context: context)))"
        } else if let earlier = predecessors(of: decision).last {
            text += " (replaces what was decided \(MemoryDates.label(ref(earlier.noteId).start, context: context)))"
        }
        return MemoryLine(kind: .decision, text: text, meeting: ref(decision.noteId),
                          quote: quote(noteId: decision.noteId, ordinal: decision.quoteTurn), rowKey: "decision:\(decision.id)")
    }

    func decision(id: Int64) -> MemoryDecision? { decisions.first { $0.id == id } }

    func current(of decision: MemoryDecision) -> MemoryDecision {
        var latest = decision
        var seen: Set<Int64> = [decision.id]
        while let next = latest.supersededBy.flatMap(self.decision(id:)), seen.insert(next.id).inserted { latest = next }
        return latest
    }

    /// The decisions this one replaced, oldest first.
    func predecessors(of decision: MemoryDecision) -> [MemoryDecision] {
        var chain: [MemoryDecision] = []
        var target = decision.id
        while let earlier = decisions.first(where: { $0.supersededBy == target }), !chain.contains(where: { $0.id == earlier.id }) {
            chain.insert(earlier, at: 0)
            target = earlier.id
        }
        return chain
    }

    /// The words of `old` that `new` does not have, stop words dropped: "45" from "price is 45"
    /// against "price drops to 40".
    static func differingWords(_ old: String, from new: String) -> String {
        let newWords = Set(MemoryText.words(new))
        return MemoryText.words(old).filter { !newWords.contains($0) && !MemoryText.stopWords.contains($0) }
            .prefix(8).joined(separator: " ")
    }

    func decisions(_ question: MemoryQuestion, context: DateContext) -> MemoryAnswer {
        let (ids, leftover) = scope(question, useTopic: false)
        let scoped = sortedMeetings(ids ?? Set(meetings.keys), before: context.now)
        let what = describe(question)
        if scoped.isEmpty { return .decline(.decisions, "I have no meetings \(what).") }
        let chosen = chosenMeetings(question, Set(scoped.map(\.id)), now: context.now)
        if chosen.isEmpty {
            let last = scoped.last.map { " The last one was \($0.title) on \(MemoryDates.label($0.start, context: context))." } ?? ""
            return .decline(.decisions, "No meetings \(what) in that time.\(last)")
        }
        let topical = leftover
        let currentOnly = question.time == nil && question.ordinal == nil
        var lines: [MemoryLine] = []
        var nothing: [MemoryMeetingRef] = []
        for meeting in chosen {
            var rows = decisions.filter { $0.noteId == meeting.id }
            if !topical.isEmpty {
                let about = rows.filter { MemoryText.coverage(of: topical, in: Set(MemoryText.contentStems($0.text))) >= 0.5 }
                if !about.isEmpty || !question.people.isEmpty || !question.companies.isEmpty { rows = about.isEmpty ? rows : about }
            }
            if currentOnly { rows = rows.filter { $0.supersededBy == nil } }
            if rows.isEmpty { nothing.append(ref(meeting.id)) }
            lines += rows.map { decisionLine($0, context: context, showCurrentOnly: currentOnly) }
        }
        if !topical.isEmpty, lines.allSatisfy({ !MemoryText.contentStems($0.text).contains(where: topical.contains) }) {
            // Nothing stored on the subject: what was said about it in those meetings, quoted.
            var narrowed = question
            narrowed.topic = topical
            let said = search(narrowed, in: Set(chosen.map(\.id)), context: context)
            if !said.isDecline { return said }
        }
        if lines.isEmpty { return .decline(.decisions, "No decisions were recorded in the meetings \(what) in that time.") }
        return MemoryAnswer(kind: .decisions, heading: "Decisions \(what)".trimmingCharacters(in: .whitespaces),
                            sections: [MemorySection(title: "Decided", lines: lines)], meetingsWithNothing: nothing, isDecline: false)
    }

    // MARK: Commitments

    func ownerName(_ item: MemoryItem) -> String {
        if let id = item.ownerId, let person = people[id] { return person.isSelf ? "You" : person.name }
        return item.ownerText.isEmpty ? "Unassigned" : item.ownerText
    }

    func itemLine(_ item: MemoryItem, withOwner: Bool) -> MemoryLine {
        var text = item.task
        if !item.due.isEmpty, !text.localizedCaseInsensitiveContains(item.due) { text += " — \(item.due)" }
        if withOwner { text = "\(ownerName(item)): \(text)" }
        return MemoryLine(kind: .item, text: text, meeting: ref(item.noteId),
                          quote: quote(noteId: item.noteId, ordinal: item.quoteTurn), rowKey: "item:\(item.id)")
    }

    /// The people a question's companies stand for, plus the people it names.
    func targets(_ question: MemoryQuestion) -> Set<Int64> {
        question.people.union(people.values.filter { person in
            !person.isSelf && person.companyId.map(question.companies.contains) == true
        }.map(\.id))
    }

    func openItems(before now: Date) -> [MemoryItem] {
        items.filter { item in
            item.status == .open && item.duplicateOf == nil && (meetings[item.noteId]?.start ?? .distantFuture) <= now
        }
    }

    func mentions(_ item: MemoryItem, anyOf targets: Set<Int64>) -> Bool {
        let words = Set(MemoryText.words(item.task))
        return targets.contains { id in MemoryText.words(people[id]?.name ?? "").first.map(words.contains) == true }
    }

    func commitments(_ question: MemoryQuestion, context: DateContext) -> MemoryAnswer {
        let targets = targets(question)
        let named = !question.people.isEmpty || !question.companies.isEmpty
        let scoped = scope(question, useTopic: false).ids ?? Set(meetings.keys)
        let selfId = selfPerson?.id
        let open = openItems(before: context.now).filter { item in
            meetings[item.noteId].map { inTime($0, question.time) } ?? false
        }
        let mine = open.filter { item in
            guard item.ownerId == selfId, selfId != nil else { return false }
            return !named || scoped.contains(item.noteId) || mentions(item, anyOf: targets)
        }
        let theirs = open.filter { item in
            if let owner = item.ownerId, owner == selfId { return false }
            if !named { return item.ownerId != nil || !item.ownerText.isEmpty }
            if let owner = item.ownerId, targets.contains(owner) { return true }
            if item.ownerId == nil, !item.ownerText.isEmpty, scoped.contains(item.noteId) {
                let first = MemoryText.firstName(item.ownerText)
                return targets.contains { MemoryText.firstName(people[$0]?.name ?? "") == first }
            }
            if !question.companies.isEmpty, item.ownerId != nil, scoped.contains(item.noteId) {
                return people[item.ownerId!].map { !$0.isSelf && ($0.companyId == nil || question.companies.contains($0.companyId!)) } ?? false
            }
            return false
        }
        let byDate: (MemoryItem, MemoryItem) -> Bool = { (self.meetings[$0.noteId]?.start ?? .distantPast) < (self.meetings[$1.noteId]?.start ?? .distantPast) }
        var sections: [MemorySection] = []
        let what = describe(question)
        if question.direction != .theirs {
            sections.append(MemorySection(title: named ? "You owe \(what.replacingOccurrences(of: "with ", with: ""))" : "You owe",
                                          lines: mine.sorted(by: byDate).map { itemLine($0, withOwner: false) }))
        }
        if question.direction != .mine {
            sections.append(MemorySection(title: named ? "Owed to you \(what)" : "Owed to you",
                                          lines: theirs.sorted(by: byDate).map { itemLine($0, withOwner: true) }))
        }
        if question.direction == .both, named {
            let unowned = open.filter { $0.ownerId == nil && $0.ownerText.isEmpty && scoped.contains($0.noteId) }
            sections.append(MemorySection(title: "Open, nobody took it", lines: unowned.sorted(by: byDate).map { itemLine($0, withOwner: false) }))
        }
        if sections.allSatisfy(\.lines.isEmpty) {
            if named, scoped.isEmpty, targets.isEmpty { return .decline(.commitments, "I have no meetings \(what).") }
            return .decline(.commitments, "Nothing open \(what).".replacingOccurrences(of: "  ", with: " "))
        }
        return MemoryAnswer(kind: .commitments, heading: "Open commitments \(what)".trimmingCharacters(in: .whitespaces),
                            sections: sections.filter { !$0.lines.isEmpty }, meetingsWithNothing: [], isDecline: false)
    }

    // MARK: Changes

    func changes(_ question: MemoryQuestion, context: DateContext) -> MemoryAnswer {
        var question = question
        guard let (group, leftover) = changeScope(question, context: context) else {
            return .decline(.changes, "Which meetings? Name a person, a company or the meeting.")
        }
        question.topic = leftover
        question.topicGroups = question.topicGroups.map { $0.filter(leftover.contains) }.filter { !$0.isEmpty }
        let after: [MemoryMeeting]
        switch (question.time, question.sinceMeeting) {
        case (.since(let date), _): after = group.filter { $0.start >= date }
        case (.window(let window), _): after = group.filter { window.contains($0.start) }
        case (nil, .first): after = Array(group.dropFirst())
        case (nil, .named(let words)):
            let base = group.last { MemoryText.coverage(of: words, in: Set(MemoryText.contentStems($0.title))) >= 0.5 }
                ?? sortedMeetings(meetingsAbout(words, share: 0.5), before: context.now).last
            after = base.map { base in group.filter { $0.start > base.start } } ?? Array(group.suffix(1))
        case (nil, nil): after = !leftover.isEmpty && question.ordinal == nil ? Array(group.dropFirst()) : Array(group.suffix(1))
        }
        guard let first = after.first else { return .decline(.changes, "No meetings \(describe(question)) in that time.") }
        let before = group.filter { $0.start < first.start }
        let afterIds = Set(after.map(\.id))
        let beforeIds = Set(before.map(\.id))
        var changed = decisionChanges(after: afterIds, before: beforeIds, context: context)
        var added = decisions.filter { decision in
            afterIds.contains(decision.noteId) && !(decision.supersededBy.map { afterIds.contains(self.decision(id: $0)?.noteId ?? -1) } ?? false)
                && !changed.contains { $0.rowKey == "decision:\(decision.id)" }
        }.map { decisionLine($0, context: context, showCurrentOnly: true) }
        var closed = items.filter { $0.closedNoteId.map(afterIds.contains) == true }.map { item -> MemoryLine in
            let state = item.status == .cancelled ? "dropped" : "done"
            return MemoryLine(kind: .closed, text: "\(ownerName(item)): \(item.task) — \(state)", meeting: ref(item.closedNoteId!),
                              quote: quote(noteId: item.closedNoteId!, ordinal: item.closedTurn), rowKey: "item:\(item.id)")
        }
        var opened = items.filter { afterIds.contains($0.noteId) && $0.duplicateOf == nil && $0.closedNoteId.map(afterIds.contains) != true }
            .map { itemLine($0, withOwner: true) }
        if !leftover.isEmpty {
            // "Did the body text size change?": only what is about it, and when no stored decision
            // is, what was said about it then against what is said now.
            let about: (MemoryLine) -> Bool = { self.weights.coverage(of: question.topicGroups, in: Set(MemoryText.contentStems($0.text))) >= 0.5 }
            let narrowed = (changed.filter(about), added.filter(about), closed.filter(about), opened.filter(about))
            let said = narrowed.0.isEmpty ? saidChanges(question, after: afterIds, before: beforeIds, context: context) : narrowed.0
            if !said.isEmpty || !narrowed.1.isEmpty || !narrowed.2.isEmpty || !narrowed.3.isEmpty {
                (changed, added, closed, opened) = (said, narrowed.1, narrowed.2, narrowed.3)
            }
        }
        let quoted = Set(changed.compactMap { $0.quote.map { "\($0.noteId):\($0.ordinal)" } })
        changed += saidChangeStatements(after: afterIds, before: beforeIds, topic: leftover.isEmpty ? nil : question.topicGroups)
            .filter { !quoted.contains("\($0.meeting.noteId):\($0.quote?.ordinal ?? -1)") }
        let sections = [
            MemorySection(title: "Changed", lines: changed), MemorySection(title: "New decisions", lines: added),
            MemorySection(title: "Closed", lines: closed), MemorySection(title: "New action items", lines: opened),
        ].filter { !$0.lines.isEmpty }
        let since = before.last.map { " since \($0.title) on \(MemoryDates.label($0.start, context: context))" } ?? " (no earlier meeting to compare)"
        let heading = after.count == 1
            ? "What changed at \(first.title) on \(MemoryDates.label(first.start, context: context))\(since)"
            : "What changed in \(after.count) meetings \(describe(question))\(since)"
        if sections.isEmpty { return .decline(.changes, heading + ": nothing new was recorded.") }
        return MemoryAnswer(kind: .changes, heading: heading, sections: sections, meetingsWithNothing: [], isDecline: false)
    }

    /// The meetings a change question compares, in time order, and the topic words left once the
    /// ones naming those meetings are taken out.
    func changeScope(_ question: MemoryQuestion, context: DateContext) -> ([MemoryMeeting], [String])? {
        let (ids, leftover) = scope(question, useTopic: true)
        if let ids { return (sortedMeetings(ids, before: context.now), leftover) }
        guard !question.topic.isEmpty else { return nil }
        // Nothing names the meetings: the ones where the topic was decided or said.
        let said = Set(retrieve(question, in: Set(meetings.keys), context: context, limit: 30).map(\.meeting.noteId))
        return said.isEmpty ? nil : (sortedMeetings(said, before: context.now), question.topic)
    }

    /// A newer decision against the one it replaced, or against the earlier decision on the same
    /// subject (its rare words, weighted) that says something different. One line names both values,
    /// at the newer meeting; a second line cites the earlier meeting.
    func decisionChanges(after: Set<Int64>, before: Set<Int64>, context: DateContext) -> [MemoryLine] {
        var lines: [MemoryLine] = []
        var used = Set<Int64>()
        let compared = before.union(after)
        for decision in decisions where after.contains(decision.noteId) {
            if let next = decision.supersededBy.flatMap(self.decision(id:)), after.contains(next.noteId) { continue }
            let start = meetings[decision.noteId]?.start ?? .distantPast
            let earlier = decisions.filter { compared.contains($0.noteId) && (meetings[$0.noteId]?.start ?? .distantFuture) < start }
            let subject = Array(MemoryText.subjectStems(decision.text))
            let old = predecessors(of: decision).last { compared.contains($0.noteId) } ?? earlier.filter { candidate in
                guard !used.contains(candidate.id), !Self.differingWords(candidate.text, from: decision.text).isEmpty else { return false }
                let theirs = Array(MemoryText.subjectStems(candidate.text))
                return min(weights.coverage(of: subject, in: Set(theirs)), weights.coverage(of: theirs, in: Set(subject))) >= 0.5
            }.last
            guard let old else { continue }
            used.insert(old.id)
            lines += changePair(new: (decision.text, decision.noteId, decision.quoteTurn, "decision:\(decision.id)"),
                                old: (old.text, old.noteId, old.quoteTurn, "decision:\(old.id)"), context: context)
        }
        return lines
    }

    /// What was said on the topic in the newest meeting against the earliest earlier meeting that
    /// said something different about it, both quoted.
    func saidChanges(_ question: MemoryQuestion, after: Set<Int64>, before: Set<Int64>, context: DateContext) -> [MemoryLine] {
        let hits = retrieve(question, in: after.union(before), context: context, limit: 30).filter { $0.kind != .item }
        guard let new = hits.last(where: { after.contains($0.meeting.noteId) }),
              let old = hits.first(where: { before.contains($0.meeting.noteId) && !Self.differingWords($0.text, from: new.text).isEmpty })
        else { return [] }
        return changePair(new: (new.text, new.meeting.noteId, new.quote?.ordinal, new.rowKey),
                          old: (old.text, old.meeting.noteId, old.quote?.ordinal, old.rowKey), context: context)
    }

    static let changeMarkers = [#"\binstead( of)?\b"#, #", not \w"#, #"\bno longer\b"#, #"\bswitch(ing|ed)?\b"#,
                                #"\b(moved|moves|pushed|pushes|slipped|bumped|changed|changes) (to|back|out)\b"#, #"\bnow (is|at|on|for|\$?\d)"#,
                                #"\b(is|are|it's) now\b"#, #"\bup from\b"#, #"\bdown from\b"#]

    /// What was said in the newer meetings that states a change ("Android first for the handoff,
    /// not iOS", "November twenty-fourth instead of the twentieth") about something the earlier
    /// meetings also covered: both values are in the turn, which is quoted. At most four.
    func saidChangeStatements(after: Set<Int64>, before: Set<Int64>, topic: [[String]]?) -> [MemoryLine] {
        guard !before.isEmpty else { return [] }
        let rows = (try? database.read { db in
            try Row.fetchAll(db, sql: "SELECT note_id, ordinal, speaker, start_seconds, text FROM turn ORDER BY note_id, ordinal")
        }) ?? []
        var lines: [MemoryLine] = []
        for row in rows {
            let noteId: Int64 = row["note_id"]
            guard after.contains(noteId) else { continue }
            let text: String = row["text"]
            let lowered = text.lowercased()
            guard Self.changeMarkers.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) else { continue }
            let stems = MemoryText.contentStems(text)
            if let topic, weights.coverage(of: topic, in: Set(stems)) < 0.5 { continue }
            let rare = stems.filter { !MemoryText.changeVerbs.contains($0) }.sorted { weights.weight($0) > weights.weight($1) }.prefix(3)
            guard rare.contains(where: { !searchTurns([$0], in: before, limit: 1).isEmpty }) else { continue }
            let quote = MemoryQuote(noteId: noteId, ordinal: row["ordinal"], speaker: row["speaker"], startSeconds: row["start_seconds"], text: text)
            var line = quoteLine(quote)
            line = MemoryLine(kind: .changed, text: "Said: " + line.text, meeting: line.meeting, quote: quote, rowKey: line.rowKey)
            lines.append(line)
            if lines.count == 4 { break }
        }
        return lines
    }

    func changePair(new: (text: String, noteId: Int64, turn: Int?, key: String), old: (text: String, noteId: Int64, turn: Int?, key: String),
                    context: DateContext) -> [MemoryLine] {
        let date = MemoryDates.label(ref(old.noteId).start, context: context)
        return [
            MemoryLine(kind: .changed, text: "Now: \(new.text) (was: \(old.text), \(date))", meeting: ref(new.noteId),
                       quote: quote(noteId: new.noteId, ordinal: new.turn), rowKey: new.key),
            MemoryLine(kind: .changed, text: "Before: \(old.text)", meeting: ref(old.noteId),
                       quote: quote(noteId: old.noteId, ordinal: old.turn), rowKey: old.key),
        ]
    }

    // MARK: Prep

    func prep(_ question: MemoryQuestion, upcoming: [CalendarEvent], context: DateContext) -> MemoryAnswer {
        let named = !question.people.isEmpty || !question.companies.isEmpty
        let inWindow = futureEvents(question, upcoming: upcoming, context: context)
        guard let event = matchingEvents(question, upcoming: upcoming, context: context).first
                ?? (named || !question.unknownNames.isEmpty ? nil : inWindow.first) else {
            return .decline(.prep, "I don't see an upcoming meeting \(describe(question)) on your calendar.")
        }
        return prepBrief(for: event, context: context)
    }

    func futureEvents(_ question: MemoryQuestion, upcoming: [CalendarEvent], context: DateContext) -> [CalendarEvent] {
        upcoming.filter { $0.start > context.now }.sorted { $0.start < $1.start }
            .filter { event in question.upcomingDay?.contains(event.start) ?? true }
    }

    /// Upcoming events with the question's people or companies, or whose title carries its topic.
    func matchingEvents(_ question: MemoryQuestion, upcoming: [CalendarEvent], context: DateContext) -> [CalendarEvent] {
        futureEvents(question, upcoming: upcoming, context: context).filter { event in
            let (peopleThere, companiesThere) = attendance(of: event)
            if !question.people.isDisjoint(with: peopleThere) || !question.companies.isDisjoint(with: companiesThere) { return true }
            let title = Set(MemoryText.contentStems(event.title))
            return !question.topic.isEmpty && MemoryText.coverage(of: question.topic, in: title) >= 0.5
        }
    }

    /// The memory's people and companies on an event's invite.
    func attendance(of event: CalendarEvent) -> (people: Set<Int64>, companies: Set<Int64>) {
        var found = Set<Int64>()
        var companyIds = Set<Int64>()
        for attendee in event.attendees where !attendee.isCurrentUser {
            let words = MemoryText.words(attendee.name)
            let exact = people.values.filter { !$0.isSelf && MemoryText.words($0.name) == words }
            let byFirst = people.values.filter { !$0.isSelf && MemoryText.words($0.name).first == words.first }
            if let person = exact.first ?? (byFirst.count == 1 ? byFirst.first : nil) { found.insert(person.id) }
            if let domain = CompanyDomain.of(email: attendee.email),
               let company = companies.values.first(where: { $0.domain == domain && !$0.isOwn }) {
                companyIds.insert(company.id)
            }
        }
        companyIds.formUnion(companies(namedIn: event.title))
        return (found, companyIds)
    }

    /// The brief before `event`: when they last met and what was decided, what each side still
    /// owes, and what changed or closed at the last meeting.
    public func prepBrief(for event: CalendarEvent, context: DateContext) -> MemoryAnswer {
        let (eventPeople, eventCompanies) = attendance(of: event)
        let series = event.iCalUID ?? event.eventIdentifier
        let related = meetings.values.filter { meeting in
            meeting.start <= context.now && (meeting.seriesKey == series
                || meeting.people.contains { eventPeople.contains($0.key) && $0.value != ["mentioned"] }
                || !meeting.companies.isDisjoint(with: eventCompanies))
        }.sorted { $0.start < $1.start }
        let when = MemoryDates.label(event.start, context: context)
        guard let last = related.last else {
            return .decline(.prep, "\(event.title) on \(when): no earlier meetings with them in your notes.")
        }
        let question = MemoryQuestion(intent: .prep, direction: .both, people: eventPeople, companies: eventCompanies, topic: [], unknownNames: [])
        let relatedIds = Set(related.map(\.id))
        let lastMet = MemoryLine(kind: .meeting, text: "Last met \(MemoryDates.label(last.start, context: context)): \(last.title)",
                                 meeting: ref(last.id), quote: nil, rowKey: "meeting:\(last.id)")
        let recent = Set(related.suffix(3).map(\.id))
        let decided = decisions.filter { recent.contains($0.noteId) && $0.supersededBy == nil }
            .map { decisionLine($0, context: context, showCurrentOnly: true) }
        let open = openItems(before: context.now)
        let selfId = selfPerson?.id
        let targets = targets(question)
        let mine = open.filter { $0.ownerId == selfId && (relatedIds.contains($0.noteId) || mentions($0, anyOf: targets)) }
        let theirs = open.filter { item in
            guard let owner = item.ownerId, owner != selfId else { return false }
            return targets.contains(owner)
        }
        let closedLast = items.filter { $0.closedNoteId == last.id }.map { item in
            MemoryLine(kind: .closed, text: "\(ownerName(item)): \(item.task) — \(item.status == .cancelled ? "dropped" : "done")",
                       meeting: ref(last.id), quote: quote(noteId: last.id, ordinal: item.closedTurn), rowKey: "item:\(item.id)")
        }
        let sections = [
            MemorySection(title: "Last time", lines: [lastMet]),
            MemorySection(title: "Decided recently", lines: decided),
            MemorySection(title: "You owe them", lines: mine.map { itemLine($0, withOwner: false) }),
            MemorySection(title: "They owe you", lines: theirs.map { itemLine($0, withOwner: true) }),
            MemorySection(title: "Closed last time", lines: closedLast),
        ].filter { !$0.lines.isEmpty }
        return MemoryAnswer(kind: .prep, heading: "Prep for \(event.title), \(when)", sections: sections, meetingsWithNothing: [], isDecline: false)
    }

    // MARK: Search

    /// "single sign-on" → "sso", "data processing addendum" → "dpa": the short form people also say.
    func acronyms(of words: [String]) -> [String] {
        var result: [String] = []
        for run in words.split(separator: "|").map(Array.init) where run.count >= 2 {
            for length in 2...min(4, run.count) {
                for start in 0...(run.count - length) {
                    let acronym = String(run[start..<start + length].compactMap(\.first))
                    if acronym.count >= 3 { result.append(acronym) }
                }
            }
        }
        return result
    }

    func search(_ question: MemoryQuestion, in noteIds: Set<Int64>? = nil, context: DateContext) -> MemoryAnswer {
        let stems = question.topic
        guard !stems.isEmpty else { return .decline(.search, "What should I look for in your meetings?") }
        let scoped = (noteIds ?? scope(question, useTopic: false).ids ?? Set(meetings.keys)).filter { id in
            meetings[id].map { inTime($0, question.time) && $0.start <= context.now } ?? false
        }
        let lines = retrieve(question, in: scoped, context: context)
        guard !lines.isEmpty else { return .decline(.search, "Nothing about \(stems.joined(separator: " ")) in your meetings.") }
        return MemoryAnswer(kind: .search, heading: "What was said \(describe(question))", sections: [MemorySection(title: "Said", lines: lines)],
                            meetingsWithNothing: [], isDecline: false)
    }

    /// What the meetings in `scope` hold on the question's topic: decisions, items and the turns
    /// that carry most of its weight (rare words count more), each turn with the reply after it.
    /// Ranked by weight, at most three per meeting, shown in time order.
    func retrieve(_ question: MemoryQuestion, in scope: Set<Int64>, context: DateContext, minimum: Double = 0.5, limit: Int = 10) -> [MemoryLine] {
        let groups = question.topicGroups.isEmpty ? [question.topic] : question.topicGroups
        let acronyms = Set(acronyms(of: question.topicWords))
        var scored: [(line: MemoryLine, score: Double)] = []
        func score(_ text: String) -> Double {
            if !acronyms.isDisjoint(with: MemoryText.words(text)) { return 1 }
            return weights.coverage(of: groups, in: Set(MemoryText.contentStems(text)))
        }
        for decision in decisions where scope.contains(decision.noteId) {
            let value = score(decision.text)
            if value >= minimum { scored.append((decisionLine(decision, context: context, showCurrentOnly: false), value + 0.01)) }
        }
        for item in items where scope.contains(item.noteId) && item.duplicateOf == nil {
            let value = score(item.task)
            if value >= minimum { scored.append((itemLine(item, withOwner: true), value)) }
        }
        for quote in searchTurns(question.topic + Array(acronyms), in: scope, limit: 80) {
            let value = score(quote.text)
            guard value >= minimum else { continue }
            scored.append((quoteLine(quote), value))
            if let reply = self.quote(noteId: quote.noteId, ordinal: quote.ordinal + 1), reply.speaker != quote.speaker {
                scored.append((quoteLine(reply), value - 0.02))
            }
        }
        var perMeeting: [Int64: Int] = [:]
        var seen = Set<String>()
        var kept: [MemoryLine] = []
        for entry in scored.sorted(by: { $0.score > $1.score }) {
            guard seen.insert(entry.line.rowKey).inserted, perMeeting[entry.line.meeting.noteId, default: 0] < 3 else { continue }
            // A row's own quote is the same moment; do not show it twice.
            if let quote = entry.line.quote { seen.insert("turn:\(quote.noteId):\(quote.ordinal)") }
            perMeeting[entry.line.meeting.noteId, default: 0] += 1
            kept.append(entry.line)
            if kept.count == limit { break }
        }
        return kept.sorted { ($0.meeting.start, $0.quote?.ordinal ?? -1) < ($1.meeting.start, $1.quote?.ordinal ?? -1) }
    }

    func quoteLine(_ quote: MemoryQuote) -> MemoryLine {
        MemoryLine(kind: .quote, text: (quote.speaker.map { "\($0): " } ?? "") + quote.text, meeting: ref(quote.noteId), quote: quote,
                   rowKey: "turn:\(quote.noteId):\(quote.ordinal)")
    }
}
