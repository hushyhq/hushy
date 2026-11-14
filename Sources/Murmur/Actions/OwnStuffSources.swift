import AppKit
import EventKit
import MurmurCore

/// Hushy's own notes and dictations, through the store's FTS5 search (keyword-first).
struct StoreOwnStuffSource: OwnStuffSource {
    let name = "hushy"
    let store: Store
    /// Notes are private in release builds (`FeatureFlags.meetings`): only dictations are searched then.
    var includesNotes = FeatureFlags.meetings

    func search(_ query: OwnStuffQuery) async -> [OwnStuffItem] {
        var items: [OwnStuffItem] = []
        let terms = query.keywords.joined(separator: " ")
        let notes = includesNotes ? (try? store.searchNotes(terms, limit: 20)) ?? [] : []
        let recent = includesNotes ? (try? store.notes(limit: 30)) ?? [] : []
        for note in notes + recent where note.status == .ready {
            guard let id = note.id, !items.contains(where: { $0.id == "note-\(id)" }) else { continue }
            items.append(OwnStuffItem(
                id: "note-\(id)", kind: .note, title: note.title, body: Self.body(of: note), date: note.createdAt,
                openURL: URL(string: "hushy://note/\(id)")))
        }
        let dictations = (try? store.searchDictations(terms, limit: 20)) ?? []
        for dictation in dictations where dictation.status == .inserted || dictation.status == .notInserted {
            guard let id = dictation.id else { continue }
            let title = dictation.appName.map { "To \($0)" } ?? "Dictation"
            items.append(OwnStuffItem(id: "dictation-\(id)", kind: .dictation, title: title, body: dictation.text, date: dictation.createdAt))
        }
        return items
    }

    /// Summary and action items first (the digest is what answers most questions), then the
    /// transcript, capped so one note can't crowd the prompt.
    static func body(of note: Note) -> String {
        var parts: [String] = []
        if !note.summary.isEmpty { parts.append(note.summary) }
        if !note.actionItems.isEmpty { parts.append(note.actionItems.map { "- \($0)" }.joined(separator: "\n")) }
        parts.append(String(note.transcript.prefix(4_000)))
        return parts.joined(separator: "\n")
    }
}

/// Apple Reminders lists and calendar days via EventKit, read-only. Asks for access the first
/// time (the same TCC prompts the voice actions use); returns nothing if declined.
final class EventKitOwnStuffSource: OwnStuffSource, @unchecked Sendable {
    let name = "eventkit"
    private let store = EKEventStore()

    func search(_ query: OwnStuffQuery) async -> [OwnStuffItem] {
        var items: [OwnStuffItem] = []
        if await remindersAccess() { items += await reminderLists() }
        if await eventsAccess() { items += calendarDays(for: query) }
        return items
    }

    private func remindersAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    private func eventsAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Every list with its incomplete reminders, one per line.
    private func reminderLists() async -> [OwnStuffItem] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // EKReminder isn't Sendable: turn the fetch into plain items inside the callback.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: Self.items(from: reminders ?? []))
            }
        }
    }

    private static func items(from reminders: [EKReminder]) -> [OwnStuffItem] {
        let grouped = Dictionary(grouping: reminders, by: { $0.calendar.calendarIdentifier })
        return grouped.compactMap { id, reminders in
            guard let list = reminders.first?.calendar else { return nil }
            let lines = reminders.compactMap { reminder -> String? in
                guard let title = reminder.title, !title.isEmpty else { return nil }
                if let due = reminder.dueDateComponents?.date {
                    return "\(title) (due \(DateFormatter.localizedString(from: due, dateStyle: .medium, timeStyle: .short)))"
                }
                return title
            }
            return OwnStuffItem(id: "reminders-\(id)", kind: .reminderList, title: list.title, body: lines.joined(separator: "\n"),
                                openURL: URL(string: "x-apple-reminderkit://"))
        }
    }

    /// The days the question names (default: today through the next seven days), one item per
    /// day with its events.
    private func calendarDays(for query: OwnStuffQuery) -> [OwnStuffItem] {
        let calendar = query.context.calendar
        let window = query.dateWindow ?? DateInterval(
            start: calendar.startOfDay(for: query.context.now),
            end: calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: query.context.now)) ?? query.context.now)
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let byDay = Dictionary(grouping: events, by: { calendar.startOfDay(for: $0.startDate) })
        let dayName = DateFormatter()
        dayName.locale = query.context.locale
        dayName.timeZone = query.context.timeZone
        dayName.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        let time = DateFormatter()
        time.locale = query.context.locale
        time.timeZone = query.context.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        return byDay.map { day, events in
            let lines = events.map { event in
                event.isAllDay ? "All day: \(event.title ?? "Event")" : "\(time.string(from: event.startDate)) \(event.title ?? "Event")"
            }
            return OwnStuffItem(id: "calendar-\(Int(day.timeIntervalSince1970))", kind: .calendarDay, title: dayName.string(from: day),
                                body: lines.joined(separator: "\n"), date: day, openURL: URL(string: "ical://"))
        }
    }
}

/// Apple Notes, through the Automation permission (the same one "Save to Apple Notes" uses).
/// Only searched when the user turned it on in Settings; a declined prompt returns nothing.
/// Searches note names and bodies for the question's keywords via AppleScript, reading at
/// most a handful of matches. Nothing read is stored.
@MainActor
struct AppleNotesOwnStuffSource: OwnStuffSource {
    nonisolated let name = "apple-notes"
    static let maxNotes = 5

    nonisolated func search(_ query: OwnStuffQuery) async -> [OwnStuffItem] {
        await MainActor.run { Self.run(query) }
    }

    private static func run(_ query: OwnStuffQuery) -> [OwnStuffItem] {
        guard let keyword = query.keywords.first else { return [] }
        let script = """
            set output to ""
            tell application "Notes"
                set matches to (every note whose name contains \(quoted(keyword)) or plaintext contains \(quoted(keyword)))
                set n to 0
                repeat with aNote in matches
                    if n ≥ \(maxNotes) then exit repeat
                    set n to n + 1
                    set output to output & (name of aNote) & linefeed & (text 1 thru (my min(4000, length of (plaintext of aNote))) of (plaintext of aNote)) & linefeed & "<<hushy-note>>" & linefeed
                end repeat
            end tell
            return output
            on min(a, b)
                if a < b then return a
                return b
            end min
            """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil,
              let text = result.stringValue else { return [] }
        return text.components(separatedBy: "<<hushy-note>>\n").enumerated().compactMap { index, block in
            let lines = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = lines.first, !first.isEmpty else { return nil }
            let body = lines.count > 1 ? String(lines[1]) : ""
            return OwnStuffItem(id: "apple-note-\(index)", kind: .appleNote, title: String(first), body: body,
                                openURL: URL(string: "notes://"))
        }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
