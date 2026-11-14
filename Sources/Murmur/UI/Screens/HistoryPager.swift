import Foundation
import GRDB
import MurmurCore
import Observation
import os

/// Which dictations History shows. `.app` filters to one bundle id (nil means "no app
/// recorded", not "any app" — see `AppFilterMenu`).
enum HistoryPageFilter: Equatable {
    case all
    case needsAttention
    case app(String?)

    fileprivate var storeFilter: Store.DictationPageFilter {
        switch self {
        case .all: .all
        case .needsAttention: .needsAttention
        case .app(let bundleID): .app(bundleID)
        }
    }
}

/// History's date filter: a preset relative window, an explicit custom range, or no filter at
/// all. Days are local-calendar days — resolved via `Calendar` (not fixed 24-hour offsets) so
/// the bounds land on real midnight-to-midnight boundaries across a DST transition.
enum HistoryDateRange: Equatable {
    case today
    case yesterday
    case last7Days
    case last30Days
    /// Inclusive on both ends, in local-calendar-day terms: `start`'s whole day through
    /// `end`'s whole day. Both are normalized to start-of-day when the bounds are computed.
    case custom(start: Date, end: Date)

    /// A short label for the chip and the popover's preset list.
    var label: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .custom(let start, let end): Self.rangeLabel(start: start, end: end)
        }
    }

    private static func rangeLabel(start: Date, end: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(.dateTime.month(.abbreviated).day())
        }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let startStyle: Date.FormatStyle = sameYear
            ? .dateTime.month(.abbreviated).day()
            : .dateTime.month(.abbreviated).day().year()
        return "\(start.formatted(startStyle)) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    /// The one day-strip column this range selects, or `nil` for a multi-day range (and for
    /// "Any time"), so exactly one column — never two — can read as selected. `.today`/
    /// `.yesterday` map to their day; a single-day `.custom` (what tapping a column produces) to
    /// its day. Keyed by `calendar.startOfDay`, the same keying `HistoryDayStrip` matches on.
    func singleSelectedDay(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: today)
        case .last7Days, .last30Days: return nil
        case .custom(let start, let end):
            return calendar.isDate(start, inSameDayAs: end) ? calendar.startOfDay(for: start) : nil
        }
    }

    /// Resolves this range into a `[start, end)` bound suitable for a SQL `createdAt >= start
    /// AND createdAt < end` predicate — `end` is the start of the day *after* the last included
    /// day, so a whole-day range never has to reason about 23:59:59.999 edge cases. Computed
    /// against `now`/`calendar` (both overridable for tests) rather than fixed offsets, so
    /// "Today" always means the current local calendar day even across a DST transition.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> Store.DictationDateRange {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return Store.DictationDateRange(start: startOfToday, end: end)
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return Store.DictationDateRange(start: start, end: startOfToday)
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return Store.DictationDateRange(start: start, end: end)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return Store.DictationDateRange(start: start, end: end)
        case .custom(let start, let end):
            // Normalize both edges to their local start-of-day, then make `end` exclusive by
            // advancing to the start of the day *after* it, so a same-day custom range (start
            // == end) still covers that whole day rather than zero seconds of it.
            let startDay = calendar.startOfDay(for: start)
            let endDayStart = calendar.startOfDay(for: end)
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: endDayStart) ?? endDayStart
            return Store.DictationDateRange(start: startDay, end: exclusiveEnd)
        }
    }
}

/// Precomputed, memoized display strings for one row, so `HistoryListContent`'s rows do no
/// formatting work in `body` — everything here is computed once when the page loads rather
/// than on every scroll-driven render. Equatable so SwiftUI can skip re-diffing a row whose
/// underlying data hasn't changed. Either a single dictation, or a run of consecutive,
/// otherwise-identical failures collapsed into one stack (same rule as the old timeline: same
/// status/app, empty text, within two minutes of each other).
struct HistoryRowModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case single(Dictation)
        case stack([Dictation])
    }

    let id: Int64
    let kind: Kind
    let timeLabel: String
    let firstLine: String

    var items: [Dictation] {
        switch kind {
        case .single(let item): [item]
        case .stack(let items): items
        }
    }

    var primary: Dictation { items[0] }
    var isStack: Bool { items.count > 1 }

    init(_ kind: Kind) {
        self.kind = kind
        let items: [Dictation] = {
            switch kind {
            case .single(let item): [item]
            case .stack(let items): items
            }
        }()
        self.id = items.first?.id ?? 0
        self.timeLabel = (items.first?.createdAt ?? .distantPast).formatted(date: .omitted, time: .shortened)
        if items.count > 1 {
            self.firstLine = "\(items.count) recordings · transcription failed"
        } else {
            let text = Self.displayText(for: items[0])
            self.firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
        }
    }

    static func == (lhs: HistoryRowModel, rhs: HistoryRowModel) -> Bool {
        lhs.id == rhs.id && lhs.items == rhs.items
    }

    var appBundleID: String? { primary.appBundleID }
    var appName: String? { primary.appName }
    var createdAt: Date { primary.createdAt }

    private static func displayText(for item: Dictation) -> String {
        if item.status == .cancelled { return item.rawText.isEmpty ? "Cancelled recording" : item.rawText }
        if item.status == .failed && item.text.isEmpty {
            if !item.rawText.isEmpty { return "Couldn't prepare text. Original transcript: \(item.rawText)" }
            return item.audioPath == nil ? "Transcription failed. No audio was retained." : "Transcription failed. Play the saved audio to recover what you said."
        }
        if item.status == .inserted && item.text.isEmpty { return "Pressed Return (no text to type)" }
        return item.text
    }

    /// Collapses consecutive failures that share status, app and (empty) text and land within
    /// two minutes of each other into a single stacked row, so a burst of identical failures
    /// (e.g. a flaky mic) reads as one row instead of a wall of duplicates. `items` must
    /// already be in the same order the day section will display them (newest first).
    static func stacked(from items: [Dictation]) -> [HistoryRowModel] {
        var rows: [HistoryRowModel] = []
        var run: [Dictation] = []

        func flush() {
            guard !run.isEmpty else { return }
            rows.append(HistoryRowModel(run.count > 1 ? .stack(run) : .single(run[0])))
            run = []
        }

        for item in items {
            if let last = run.last, canStack(last, item) {
                run.append(item)
            } else {
                flush()
                run = [item]
            }
        }
        flush()
        return rows
    }

    private static let stackWindow: TimeInterval = 120

    private static func canStack(_ a: Dictation, _ b: Dictation) -> Bool {
        a.status == .failed && b.status == .failed
            && a.text.isEmpty && b.text.isEmpty
            && a.appBundleID == b.appBundleID
            && abs(a.createdAt.timeIntervalSince(b.createdAt)) <= stackWindow
    }
}

/// Bridges `HistoryRowModel` into MurmurCore's `HistoryGrouping`/`HistoryScrubberModel` so both
/// the run-header redesign and the scrubber reuse the same pure algorithms instead of
/// duplicating the break rule or bucketing thresholds here.
extension HistoryRowModel: HistoryGroupable, HistoryScrubbable {
    var groupID: Int64 { id }
    var groupCreatedAt: Date { createdAt }
    var groupAppBundleID: String? { appBundleID }

    var scrubberID: Int64 { id }
    var scrubberCreatedAt: Date { createdAt }
    var scrubberTimeLabel: String { timeLabel }
    var scrubberFirstLine: String { firstLine }
    var scrubberAppBundleID: String? { appBundleID }
}

/// One entry in History's day section: either a dictation row (possibly a stacked-failure run)
/// or a confirmed voice action. Unifying these into one `HistoryGroupable` type lets `runs` be
/// computed by a single `HistoryGrouping.runs` pass over *all* of a day's entries in timestamp
/// order, so an action interleaves chronologically into the same app-runs Home computes via
/// `Timeline.merge`/`Timeline.groups` — never appended as a separate trailing run (see
/// `.claude/DECISIONS.md`).
enum HistoryTimelineRow: Identifiable, Equatable {
    case dictation(HistoryRowModel)
    case action(ActionRecord)

    var id: Int64 {
        switch self {
        case .dictation(let row): row.id
        case .action(let record): (record.id ?? 0) << 32 | 1 // disjoint from dictation row ids
        }
    }

    var createdAt: Date {
        switch self {
        case .dictation(let row): row.createdAt
        case .action(let record): record.createdAt
        }
    }

    /// Actions have no source app of their own — grouped under the same "Hushy" fallback Home
    /// uses (see `TimelineEntry.appBundleID`/`appName`), rather than joining a nearby dictation
    /// run under that run's app by coincidence.
    var appBundleID: String? {
        switch self {
        case .dictation(let row): row.appBundleID
        case .action: nil
        }
    }

    var appName: String? {
        switch self {
        case .dictation(let row): row.appName
        case .action: "Hushy"
        }
    }
}

extension HistoryTimelineRow: HistoryGroupable {
    var groupID: Int64 { id }
    var groupCreatedAt: Date { createdAt }
    var groupAppBundleID: String? { appBundleID }
}

/// One day's worth of rows, pre-grouped and pre-stacked so `HistoryListContent` never redoes
/// that work on every render. `runs` groups `rows` (already stacked) into consecutive same-app
/// bursts for the "one icon per run" list redesign — computed once per section rebuild, not per
/// render, same as `rows` itself. `timelineRuns` folds in that day's voice actions, sorted
/// chronologically alongside the dictation rows, before grouping — see `HistoryTimelineRow`.
struct HistoryDaySection: Identifiable, Equatable {
    let day: Date
    var rows: [HistoryRowModel]
    var runs: [HistoryRun<HistoryRowModel>]
    var timelineRuns: [HistoryRun<HistoryTimelineRow>]

    var id: Date { day }

    init(day: Date, rows: [HistoryRowModel], actions: [ActionRecord] = []) {
        self.day = day
        self.rows = rows
        self.runs = HistoryGrouping.runs(from: rows)
        let merged = (rows.map(HistoryTimelineRow.dictation) + actions.map(HistoryTimelineRow.action))
            .sorted { $0.createdAt > $1.createdAt }
        self.timelineRuns = HistoryGrouping.runs(from: merged)
    }
}

/// Drives History's `List` with keyset pagination: holds one window of pages in memory,
/// fetches the next page when the last row scrolls into view, and mirrors new dictations at
/// the top live via `ValueObservation` limited to page one (so a live insert never triggers a
/// full-history refetch). Row and day-section view-models are computed here, off the view
/// body, and memoized until the underlying rows change.
@MainActor
@Observable
final class HistoryPager {
    private(set) var sections: [HistoryDaySection] = []
    private(set) var isLoadingFirstPage = true
    private(set) var hasMore = true
    private(set) var totalLoaded = 0
    /// The scrubber's tick list, rebuilt alongside `sections` from the same flattened,
    /// newest-first row list — see `HistoryScrubberModel.ticks(for:)` for the bucketing rule.
    private(set) var scrubberTicks: [HistoryTick] = []
    /// `HistoryTick.id` (== row id) -> `createdAt`, for `HistoryScrubberModel.activeTickID`'s
    /// visible-row lookup. Kept alongside `scrubberTicks` rather than recomputed per scroll
    /// event.
    private(set) var rowDatesByID: [Int64: Date] = [:]
    /// Every app with dictations across the whole history (not just loaded pages), for the
    /// header's app chips — see `Store.appDictationCounts`. Refreshed on reload and whenever the
    /// live first page changes (i.e. a dictation was added or removed).
    private(set) var appCounts: [Store.AppDictationCount] = []
    /// The header week strip's per-day counts, read from the table (not loaded pages) so the
    /// strip is right under any filter — see `Store.dictationDayActivity`.
    private(set) var weekActivity: (entries: [Date: Int], attention: [Date: Int]) = ([:], [:])

    /// How many first-page loads have run in this process. A load is a handful of synchronous
    /// database reads, so a test watches this to prove a view does not build a pager it discards.
    private(set) static var firstPageLoadCount = 0

    private let library: Library
    private let pageSize: Int
    private var filter: HistoryPageFilter = .all
    private var searchQuery: String?
    private var dateRange: HistoryDateRange?
    private var items: [Dictation] = []
    private var cursor: Store.DictationCursor?
    private var isFetchingNextPage = false
    @ObservationIgnored private var liveObservation: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "history-pager")

    /// Loads the first page synchronously during init — `Store.dictationPage` is a fast local
    /// SQLite read, not worth a `.task`-driven async round trip, and doing it here means the
    /// view never has an empty-first-frame flash (and snapshot rendering, which captures a
    /// view synchronously with no chance for `.task` to run first, sees real rows immediately).
    init(library: Library, pageSize: Int = 100, dateRange: HistoryDateRange? = nil) {
        self.library = library
        self.pageSize = pageSize
        self.dateRange = dateRange
        loadFirstPage()
    }

    deinit {
        liveObservation?.cancel()
    }

    /// Applies a new filter, search term or date range and reloads from the first page. Search
    /// bypasses keyset pagination (FTS is already bounded by `limit`) and disables the live
    /// top-of-list observation, since search results aren't "the newest N" in the same sense.
    /// A date range still combines (AND) with search and the status/app filter either way.
    func reload(filter: HistoryPageFilter, search: String?, dateRange: HistoryDateRange? = nil) {
        self.filter = filter
        let trimmed = search?.trimmingCharacters(in: .whitespaces)
        self.searchQuery = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.dateRange = dateRange
        loadFirstPage()
    }

    func loadFirstPage() {
        Self.firstPageLoadCount += 1
        liveObservation?.cancel()
        refreshHeaderAggregates()
        isLoadingFirstPage = true
        cursor = nil
        items = []
        let storeDateRange = dateRange?.bounds()

        if let searchQuery {
            let results = (try? library.store.searchDictations(searchQuery, dateRange: storeDateRange, limit: 200)) ?? []
            // The store returns the 200 best matches (best first); History is a day timeline, so show those
            // 200 newest-first. Ranking decides which rows make the cut; the timeline keeps its order.
            items = results.filter(matchesFilter).sorted { ($0.createdAt, $0.id ?? 0) > ($1.createdAt, $1.id ?? 0) }
            hasMore = false
            rebuildSections()
            isLoadingFirstPage = false
            return
        }

        let page = library.dictationPage(after: nil, filter: filter.storeFilter, dateRange: storeDateRange, pageSize: pageSize)
        items = page.items
        hasMore = page.hasMore
        cursor = Self.cursor(after: page.items)
        rebuildSections()
        isLoadingFirstPage = false
        observeTopOfList()
    }

    /// Called when the last loaded row appears in the List, so the next page loads just
    /// before the user reaches the bottom rather than after.
    func loadNextPageIfNeeded(currentID: Int64) {
        guard searchQuery == nil, hasMore, !isFetchingNextPage, items.last?.id == currentID else { return }
        isFetchingNextPage = true
        let storeDateRange = dateRange?.bounds()
        let page = library.dictationPage(after: cursor, filter: filter.storeFilter, dateRange: storeDateRange, pageSize: pageSize)
        let loaded = Set(items.compactMap(\.id))
        items.append(contentsOf: page.items.filter { !loaded.contains($0.id ?? -1) })
        hasMore = page.hasMore
        cursor = Self.cursor(after: items)
        rebuildSections()
        isFetchingNextPage = false
    }

    /// Keeps only the first page live: a `ValueObservation` on just the newest `pageSize`
    /// rows (matching the current filter) is cheap even at tens of thousands of dictations,
    /// and covers the only case that matters for "live" — a brand-new dictation appearing
    /// while History is open. Pages fetched further down stay static until reloaded. With a
    /// date range, it stays live only if the range reaches "now" (Today, Last 7 days); a range
    /// entirely in the past can't gain new rows, so observing it would be wasted work.
    private func observeTopOfList() {
        let bounds = dateRange?.bounds()
        if let bounds, bounds.end <= Date() { return }
        let writer = library.store.writer
        let storeFilter = filter.storeFilter
        let size = pageSize
        liveObservation = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Store.dictationPage(db, after: nil, filter: storeFilter, dateRange: bounds, pageSize: size)
            }
            do {
                for try await page in observation.values(in: writer) {
                    guard let self, !Task.isCancelled else { return }
                    self.applyLiveFirstPage(page.items, hasMoreAfterFirstPage: page.hasMore)
                }
            } catch {
                self?.log.error("history live observation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Merges a freshly observed first page with whatever additional pages are already
    /// loaded below it, so scrolled-in rows aren't discarded just because row 1 changed.
    /// Rows from the old window (newer than the new page's last row) come from the new page
    /// alone, so a deleted row stays gone and an inserted one pushes nothing out. The paging
    /// cursor always sits on the last loaded row, wherever the live window ends.
    private func applyLiveFirstPage(_ firstPage: [Dictation], hasMoreAfterFirstPage: Bool) {
        let loadedBelow = Self.rows(items, olderThanLast: firstPage, hasMoreAfterFirstPage: hasMoreAfterFirstPage)
        items = firstPage + loadedBelow
        if loadedBelow.isEmpty { hasMore = hasMoreAfterFirstPage }
        cursor = Self.cursor(after: items)
        rebuildSections()
        refreshHeaderAggregates()
    }

    /// Re-reads the whole-history aggregates behind the header (app chips, week strip). Both
    /// are single cheap queries; a failure just leaves the previous values in place.
    private func refreshHeaderAggregates(now: Date = Date(), calendar: Calendar = .current) {
        do {
            appCounts = try library.store.appDictationCounts()
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
            weekActivity = try library.store.dictationDayActivity(start: start, end: end, calendar: calendar)
        } catch {
            log.error("history header aggregates failed: \(error.localizedDescription)")
        }
    }

    private func matchesFilter(_ item: Dictation) -> Bool {
        switch filter {
        case .all: true
        case .needsAttention: item.needsAttention
        case .app(let bundleID): item.appBundleID == bundleID
        }
    }

    private func rebuildSections() {
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [Dictation]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.createdAt)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(item)
        }
        // Voice actions interleave into the same day groups as dictations (see
        // `HistoryTimelineRow`) only for the unfiltered, non-search view — a status/app filter
        // that's already narrowing dictations shouldn't also silently inject unrelated actions —
        // and only into days that already have a loaded dictation section, so an action never
        // creates a day section of its own out of a page that hasn't loaded that far yet.
        var actionsByDay: [Date: [ActionRecord]] = [:]
        if filter == .all, searchQuery == nil {
            let loadedDays = Set(order)
            for action in library.actionRecords {
                let day = calendar.startOfDay(for: action.createdAt)
                guard loadedDays.contains(day) else { continue }
                if let dateRange {
                    let bounds = dateRange.bounds()
                    guard action.createdAt >= bounds.start, action.createdAt < bounds.end else { continue }
                }
                actionsByDay[day, default: []].append(action)
            }
        }
        // Stacking runs within a day, in the same newest-first order `items` is already in.
        sections = order.map { day in
            HistoryDaySection(day: day, rows: HistoryRowModel.stacked(from: grouped[day] ?? []), actions: actionsByDay[day] ?? [])
        }
        totalLoaded = items.count

        let allRows = sections.flatMap(\.rows)
        scrubberTicks = HistoryScrubberModel.ticks(for: allRows)
        rowDatesByID = Dictionary(allRows.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
    }

    private static func rows(_ loaded: [Dictation], olderThanLast firstPage: [Dictation], hasMoreAfterFirstPage: Bool) -> [Dictation] {
        guard hasMoreAfterFirstPage, let boundary = firstPage.last else { return [] }
        return loaded.filter { ($0.createdAt, $0.id ?? 0) < (boundary.createdAt, boundary.id ?? 0) }
    }

    private static func cursor(after page: [Dictation]) -> Store.DictationCursor? {
        guard let last = page.last, let id = last.id else { return nil }
        return Store.DictationCursor(createdAt: last.createdAt, id: id)
    }
}

/// Builds History's pager the first time the view reads it, then keeps it. SwiftUI makes a new
/// `HistoryView` value whenever its parent re-evaluates (every frame of a window resize), and a
/// pager's first page is a handful of synchronous database reads.
@MainActor
final class HistoryPagerHolder {
    private let library: Library
    private let dateRange: HistoryDateRange?
    private(set) lazy var pager = HistoryPager(library: library, dateRange: dateRange)

    init(library: Library, dateRange: HistoryDateRange?) {
        self.library = library
        self.dateRange = dateRange
    }
}
