import Foundation

/// The Meetings screens' answers from the cross-meeting rows (`MeetingMemory`): people and
/// companies met, timelines, what is owed both ways, prep and "Ask your meetings". One value is one
/// snapshot of the notes; build a new one when they change. Items closed in a later meeting and
/// decisions replaced later are already settled in the rows, so every screen agrees on them.
public struct EngineMeetingMemory: MeetingMemorySource {
    let engine: MeetingMemory
    let store: Store
    let digest: any MeetingDigestSource
    let context: DateContext
    let upcoming: [CalendarEvent]

    /// `myNames`: the person's own names from Settings; the invite's "this is me" adds to them.
    public static func build(
        store: Store, myNames: [String], digest: any MeetingDigestSource = StoredSummaryDigest(),
        upcoming: [CalendarEvent] = [], context: DateContext = .current()
    ) throws -> EngineMeetingMemory {
        EngineMeetingMemory(
            engine: try MeetingMemory.build(from: store, selfNames: myNames), store: store, digest: digest,
            context: context, upcoming: upcoming)
    }

    // MARK: Rows the screens list

    public func people(limit: Int, myNames: [String]) throws -> [MeetingPerson] {
        let open = engine.openItems(before: context.now)
        return engine.people.values.filter { !$0.isSelf }.compactMap { person -> MeetingPerson? in
            let met = engine.meetings.values.filter { attended($0, person.id) }
            guard let last = met.map(\.start).max() else { return nil }
            let ids = Set(met.map(\.id))
            let owed = open.filter { ids.contains($0.noteId) && ($0.ownerId == person.id || isMine($0, myNames)) }.count
            return MeetingPerson(name: person.name, meetingCount: met.count, lastMet: last, openItems: owed)
        }
        .sorted { ($0.lastMet, $0.meetingCount, $1.name) > ($1.lastMet, $1.meetingCount, $0.name) }
        .prefix(limit).map { $0 }
    }

    public func companies(limit: Int) throws -> [MeetingCompany] {
        engine.companies.values.filter { !$0.isOwn }.compactMap { company -> MeetingCompany? in
            let met = engine.meetings.values.filter { $0.companies.contains(company.id) }
            guard let last = met.map(\.start).max() else { return nil }
            let people = engine.people.values.filter { $0.companyId == company.id && !$0.isSelf }.map(\.name).sorted()
            return MeetingCompany(name: company.name, people: people, meetingCount: met.count, lastMet: last)
        }
        .sorted { ($0.lastMet, $1.name) > ($1.lastMet, $0.name) }
        .prefix(limit).map { $0 }
    }

    public func timeline(for subject: MeetingSubject, myNames: [String]) throws -> [MeetingTimelineEntry] {
        let wanted = subject.name.lowercased()
        let meetings: [MemoryMeeting]
        switch subject {
        case .person:
            let ids = Set(engine.people.values.filter { person in
                let name = person.name.lowercased()
                return !person.isSelf && (name == wanted || name.split(separator: " ").first.map(String.init) == wanted)
            }.map(\.id))
            meetings = engine.meetings.values.filter { meeting in ids.contains { attended(meeting, $0) } }
        case .company:
            let ids = Set(engine.companies.values.filter { $0.name.lowercased() == wanted || $0.domain == wanted }.map(\.id))
            meetings = engine.meetings.values.filter { !$0.companies.isDisjoint(with: ids) }
        }
        return meetings.sorted { $0.start > $1.start }.map { entry($0, myNames: myNames) }
    }

    public func commitments(myNames: [String]) throws -> MeetingCommitments {
        let open = engine.openItems(before: context.now).sorted { start($0) > start($1) }.map { ref($0, myNames: myNames) }
        return MeetingCommitments(
            iOwe: open.filter(\.isMine),
            owedToMe: open.filter { !$0.isMine && !$0.detail.owner.isEmpty },
            unowned: open.filter { !$0.isMine && $0.detail.owner.isEmpty })
    }

    // MARK: Prep and questions

    public func prep(for event: CalendarEvent, myNames: [String]) throws -> MeetingPrep {
        let attendees = event.attendees.filter { !$0.isCurrentUser }.map(\.name)
            .filter { !$0.isEmpty && !NoteCalendarMatch.looksLikeEmailAddress($0) }
        let brief = engine.prepBrief(for: event, context: context)
        guard !brief.isDecline else {
            return MeetingPrep(eventTitle: event.title, start: event.start, attendees: attendees, lastTime: [], stillOpen: [], talkingPoints: [])
        }
        let recentIds = brief.sections.filter { ["Last time", "Decided recently"].contains($0.title) }
            .flatMap(\.lines).map(\.meeting.noteId)
        let lastTime = Set(recentIds).compactMap { engine.meetings[$0] }.sorted { $0.start > $1.start }.prefix(2)
        let stillOpen = brief.lines.compactMap(item(for:)).map { ref($0, myNames: myNames) }
        let points = stillOpen.sorted { $0.isMine && !$1.isMine }.map { item in
            item.isMine ? "Update on: \(item.detail.task)"
                : "Check with \(item.detail.owner.isEmpty ? "the group" : item.detail.owner): \(item.detail.task)"
        } + (try openQuestions(in: lastTime.map(\.id))).map { "Still open: \($0)" }
        return MeetingPrep(
            eventTitle: event.title, start: event.start, attendees: attendees,
            lastTime: lastTime.map { entry($0, myNames: myNames) }, stillOpen: stillOpen, talkingPoints: Array(points.prefix(5)))
    }

    /// `myNames` is fixed when the snapshot is built; the engine already knows who "I" am.
    public func ask(_ question: String, myNames: [String]) throws -> MeetingAnswer {
        let answer = engine.ask(question, context: context, upcoming: upcoming)
        let lines = answer.lines.map(Self.line) + answer.meetingsWithNothing.map { meeting in
            MeetingAnswer.Line(noteId: meeting.noteId, noteTitle: meeting.title, noteDate: meeting.start, kind: .meeting,
                               text: "Nothing on this in this meeting.")
        }
        guard !answer.isDecline, !lines.isEmpty else {
            return MeetingAnswer(question: question, lines: [], emptyReason: answer.heading)
        }
        return MeetingAnswer(question: question, heading: answer.heading, lines: lines, emptyReason: nil)
    }

    /// One engine line as the screen shows it, keeping its meeting and the moment that backs it.
    static func line(_ line: MemoryLine) -> MeetingAnswer.Line {
        let kind: MeetingAnswer.Kind = switch line.kind {
        case .decision: .decision
        case .item: .item
        case .closed: .closed
        case .changed: .changed
        case .quote: .quote
        case .meeting: .meeting
        }
        let isQuote = line.kind == .quote
        return MeetingAnswer.Line(
            noteId: line.meeting.noteId, noteTitle: line.meeting.title, noteDate: line.meeting.start, kind: kind,
            text: isQuote ? line.quote?.text ?? line.text : line.text, speaker: line.quote?.speaker,
            atSeconds: line.quote?.startSeconds, quote: isQuote ? nil : line.quote?.text)
    }

    // MARK: Helpers

    func attended(_ meeting: MemoryMeeting, _ personId: Int64) -> Bool {
        meeting.people[personId].map { $0 != ["mentioned"] } ?? false
    }

    func isMine(_ item: MemoryItem, _ myNames: [String]) -> Bool {
        if let owner = item.ownerId, engine.people[owner]?.isSelf == true { return true }
        return detail(item).isOwned(by: myNames)
    }

    func detail(_ item: MemoryItem) -> ActionItemDetail {
        ActionItemDetail(owner: item.ownerText, task: item.task, due: item.due)
    }

    func start(_ item: MemoryItem) -> Date { engine.meetings[item.noteId]?.start ?? .distantPast }

    func ref(_ item: MemoryItem, myNames: [String]) -> MeetingItemRef {
        let meeting = engine.meetings[item.noteId]
        return MeetingItemRef(
            noteId: item.noteId, noteTitle: meeting?.title ?? "", noteDate: meeting?.start ?? .distantPast,
            itemIndex: item.ordinal, detail: detail(item), isMine: isMine(item, myNames))
    }

    /// The open item a prep line came from ("item:12"); closed items are not still open.
    func item(for line: MemoryLine) -> MemoryItem? {
        guard line.kind == .item, line.rowKey.hasPrefix("item:"), let id = Int64(line.rowKey.dropFirst(5)) else { return nil }
        return engine.items.first { $0.id == id && $0.status == .open }
    }

    func entry(_ meeting: MemoryMeeting, myNames: [String]) -> MeetingTimelineEntry {
        let decisions = engine.decisions.filter { $0.noteId == meeting.id }.map { decision in
            decision.supersededBy == nil ? decision.text : "\(decision.text) (changed later)"
        }
        let open = engine.openItems(before: context.now).filter { $0.noteId == meeting.id }.map { ref($0, myNames: myNames) }
        let people = meeting.people.keys.filter { attended(meeting, $0) }.compactMap { engine.people[$0] }
            .filter { !$0.isSelf }.map(\.name).sorted()
        return MeetingTimelineEntry(
            noteId: meeting.id, title: meeting.title, date: meeting.start,
            durationSeconds: meeting.end.timeIntervalSince(meeting.start), decisions: decisions, openItems: open, people: people)
    }

    /// The person's typed "?" lines first, then the summary's open questions, without restatements.
    func openQuestions(in noteIds: [Int64]) throws -> [String] {
        let asked = try noteIds.flatMap { id -> [String] in
            let typed = try store.jots(noteId: id).filter(\.isQuestion).map(\.shownText)
            return typed + (try store.note(id: id).map { digest.rows(for: $0).openQuestions } ?? [])
        }
        return MeetingWords.withoutRepeats(asked)
    }
}
