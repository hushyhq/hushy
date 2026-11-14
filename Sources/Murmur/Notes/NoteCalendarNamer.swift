import Foundation
import MurmurCore
import os

/// Names a note that is just starting after the calendar meeting it overlaps, and links the two.
/// The lookup runs off the recording's path: `begin` returns at once, a slow or failing calendar
/// leaves the note exactly as it is today, and nothing here ever asks for calendar access.
@MainActor
final class NoteCalendarNamer {
    private let reader: any CalendarReading
    private let store: Store
    private let isEnabled: @MainActor () -> Bool
    private let timeout: TimeInterval
    private let log = Logger(subsystem: "app.hushy", category: "notes")

    init(
        reader: any CalendarReading, store: Store, isEnabled: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = NoteCalendarLinker.lookupTimeout
    ) {
        self.reader = reader
        self.store = store
        self.isEnabled = isEnabled
        self.timeout = timeout
    }

    /// - Parameters:
    ///   - defaultTitle: the title the note was created with. It is replaced only while the stored
    ///     title still equals this, so a title the user typed meanwhile is never overwritten.
    ///   - onTitled: called with the new title, on the main actor, in the same turn as the store
    ///     write, so the recorder can update its in-memory copy before any autosave runs.
    @discardableResult
    func begin(
        noteID: Int64, startedAt: Date, defaultTitle: String, onTitled: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never> {
        Task { [reader, timeout] in
            guard isEnabled() else { return }
            guard let match = await NoteCalendarLinker.match(startedAt: startedAt, reader: reader, timeout: timeout) else { return }
            apply(match, noteID: noteID, defaultTitle: defaultTitle, onTitled: onTitled)
        }
    }

    private func apply(
        _ match: NoteCalendarMatch, noteID: Int64, defaultTitle: String, onTitled: @MainActor (String) -> Void
    ) {
        do {
            if try store.applyCalendarMatch(match, toNote: noteID, replacingTitle: defaultTitle) {
                onTitled(match.title)
            }
        } catch {
            // The error text can carry SQL arguments, which would be the meeting's title.
            log.error("linking a note to its calendar meeting failed")
        }
    }
}
