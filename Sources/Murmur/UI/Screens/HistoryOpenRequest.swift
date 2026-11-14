import Foundation
import MurmurCore
import Observation

/// A request, made outside History, to open one dictation there. Callers (Home's "Open in
/// History" today; it is also the entry point for the dictation pill) go through
/// `AppModel.openHistoryItem(_:)`. History takes the request when it is on screen, after the
/// app lock if there is one, and only within `lifetime`; it then shows that dictation's day
/// and opens it in the detail pane. Held outside `AppModel` because History is not always alive
/// to be told directly: the request waits here until the page appears, or is dropped.
@MainActor
@Observable
final class HistoryOpenRequest {
    static let shared = HistoryOpenRequest()

    /// How long a request waits to be served. Long enough to unlock with Touch ID or a
    /// password; short enough that unlocking much later does not open something asked for then.
    static let lifetime: TimeInterval = 60

    /// The dictation waiting to be opened, newest request wins.
    private(set) var pendingID: Int64?
    @ObservationIgnored private var requestedAt = Date.distantPast

    func request(_ dictationID: Int64, now: Date = Date()) {
        pendingID = dictationID
        requestedAt = now
    }

    /// Hands the pending id over once, so coming back to History later does not reopen it. A
    /// request older than `lifetime` is dropped instead of served.
    func take(now: Date = Date()) -> Int64? {
        defer { pendingID = nil }
        guard now.timeIntervalSince(requestedAt) <= Self.lifetime else { return nil }
        return pendingID
    }

    /// The main window changed section. Leaving History drops a request that was never served
    /// (the app was locked, and the person went elsewhere instead of unlocking).
    func sectionChanged(isHistory: Bool) {
        if !isHistory { pendingID = nil }
    }
}

/// What can hand History its rows a page at a time: the pager, or a test's stand-in.
@MainActor
protocol HistoryRowLoading: AnyObject {
    var sections: [HistoryDaySection] { get }
    var hasMore: Bool { get }
    /// Loads the page after the last loaded row, through the list's own paging.
    func loadNextPage()
}

extension HistoryPager: HistoryRowLoading {
    func loadNextPage() {
        guard let lastID = sections.last?.rows.last?.items.last?.id else { return }
        loadNextPageIfNeeded(currentID: lastID)
    }
}

/// Where a requested dictation is in History. Pure (`HistoryNavigationTests`).
enum HistoryOpenTarget {
    enum Plan: Equatable {
        /// The dictation no longer exists (deleted, or removed by the retention setting).
        case missing
        /// Show this date range, then find the row in it.
        case show(HistoryDateRange)
    }

    /// What to do with a request, given what the store returned for its id.
    static func plan(for dictation: Dictation?, now: Date, calendar: Calendar) -> Plan {
        guard let dictation else { return .missing }
        return .show(dateRange(for: dictation.createdAt, now: now, calendar: calendar))
    }

    /// The date filter that shows the dictation: Today (History's default) when it was said
    /// today, that one day otherwise.
    static func dateRange(for createdAt: Date, now: Date, calendar: Calendar) -> HistoryDateRange {
        if calendar.isDate(createdAt, inSameDayAs: now) { return .today }
        let day = calendar.startOfDay(for: createdAt)
        return .custom(start: day, end: day)
    }

    /// The list row that holds the dictation: its own, or the stack of failures it was folded into.
    static func rowID(for dictationID: Int64, in sections: [HistoryDaySection]) -> Int64? {
        sections.flatMap(\.rows).first { row in row.items.contains { $0.id == dictationID } }?.id
    }

    /// A day rarely needs more than its first page; this bounds the search on one that does.
    static let maxPagesToSearch = 50

    /// Finds the dictation's row, loading further pages of the shown range until it turns up.
    /// Stops when the pages run out, when a page adds nothing, or after `maxPages`.
    @MainActor
    static func locate(_ dictationID: Int64, in rows: any HistoryRowLoading, maxPages: Int = maxPagesToSearch) -> Int64? {
        var pagesLoaded = 0
        while true {
            if let found = rowID(for: dictationID, in: rows.sections) { return found }
            guard rows.hasMore, pagesLoaded < maxPages else { return nil }
            let before = rows.sections.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.items.count } }
            rows.loadNextPage()
            pagesLoaded += 1
            let after = rows.sections.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.items.count } }
            guard after > before else { return nil }
        }
    }
}

extension AppModel {
    /// Opens one dictation in History by its identifier, from anywhere in the app: switches the
    /// main window to History, brings it forward, and History shows that dictation's day with it
    /// open in the detail pane. The single entry point for "show me this one".
    func openHistoryItem(_ dictationID: Int64) {
        HistoryOpenRequest.shared.request(dictationID)
        section = .history
        openMainWindow()
    }
}
