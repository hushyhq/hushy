import AVFoundation
import MurmurCore
import os
import SwiftUI

/// Full History: a master–detail page (like Mail) backed by `HistoryPager`'s keyset
/// pagination, replacing the old Home-embedded `LazyVStack` timeline. A native `List`
/// reuses row views instead of building every heavy row up front, which is what made the
/// old timeline lag once a history grew long.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotHistoryFilter) private var snapshotHistoryFilter
    @Environment(\.snapshotHistorySelecting) private var snapshotHistorySelecting
    @Environment(\.snapshotHistoryDateRange) private var snapshotHistoryDateRange
    @Environment(\.snapshotHistoryDetailID) private var snapshotHistoryDetailID
    @Environment(\.snapshotHistoryAllDates) private var snapshotHistoryAllDates
    @Environment(\.snapshotHistorySelectionCount) private var snapshotHistorySelectionCount
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Built eagerly in `init` (via the explicit `library:` initializer below) rather than
    /// lazily in `.onAppear`/`.task`: `HistoryPager.init` loads its first page synchronously,
    /// so building it up front means rows are present in the very first rendered frame. That
    /// matters for `ImageRenderer`-based snapshot capture, which renders a view once and never
    /// waits for an appearance callback or async task to run first.
    @State private var pagerHolder: HistoryPagerHolder
    private var pager: HistoryPager { pagerHolder.pager }
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var filter: HistoryPageFilter = .all
    @State private var selectedID: Int64?
    @State private var compactShowsDetail = false
    @State private var selection: Set<Int64> = []
    @State private var isSelecting = false
    /// The last row clicked while selecting; a shift-click selects from it to the next one.
    @State private var selectionAnchor: Int64?
    /// A row the list should scroll into view (an item opened from outside History).
    @State private var revealRowID: Int64?
    /// The dictation another screen asked to open no longer exists; the detail pane says so
    /// until something else is opened.
    @State private var openedItemMissing = false
    @State private var confirmDelete = false
    @State private var showDatePicker = false
    @State private var pickedDate = Date()
    @State private var jumpTarget: Date?
    @State private var showDateFilter = false
    /// History opens on **Today** — the founder asked for it to default to the current date, and
    /// the day strip then shows exactly one selected mark (today's). "All dates" (or clearing the
    /// chip) switches to `nil`, i.e. any time. See DECISIONS.md, "History date strip".
    @State private var dateRange: HistoryDateRange? = Self.defaultDateRange
    static let defaultDateRange: HistoryDateRange? = .today
    @FocusState private var searchFocused: Bool
    /// Debounces `query` -> `debouncedQuery` by 150 ms so every keystroke doesn't trigger a
    /// fresh FTS query.
    @State private var searchDebounce: Task<Void, Never>?
    /// "Open this one" from outside History (`AppModel.openHistoryItem`; Home's card uses it).
    private let openRequest = HistoryOpenRequest.shared

    init(library: Library) {
        _pagerHolder = State(initialValue: HistoryPagerHolder(library: library, dateRange: Self.defaultDateRange))
    }

    var body: some View {
        // The list gets the space by default — the founder's call (DECISIONS.md-adjacent audit
        // item "History split default"): a detail pane at rest with nothing selected doesn't
        // need to dominate the window. `idealLeading` only sets the *default*; a width the user
        // has already dragged (persisted under `persistenceKey`) wins from then on.
        ResizableSplit(
            minLeading: 360, idealLeading: 620, maxLeading: 780, persistenceKey: "history",
            minTrailing: 320, hasSelection: !isSelecting && selectedID.flatMap(findRow) != nil,
            showSelectedDetail: compactShowsDetail && !isSelecting,
            onBack: { compactShowsDetail = false },
            onShowDetail: { compactShowsDetail = true }
        ) { listPane } trailing: { detailPane }
            .background(Theme.bgBase)
        .onAppear {
            applySnapshotState()
            openRequestedItem()
        }
        .onChange(of: openRequest.pendingID) { _, _ in openRequestedItem() }
        .onChange(of: debouncedQuery) { _, newValue in pager.reload(filter: filter, search: newValue, dateRange: dateRange) }
        .onChange(of: selectedID) { _, newValue in
            compactShowsDetail = newValue != nil
            if newValue != nil { openedItemMissing = false }
        }
        .onChange(of: filter) { _, newValue in pager.reload(filter: newValue, search: debouncedQuery, dateRange: dateRange) }
        .onChange(of: dateRange) { _, newValue in pager.reload(filter: filter, search: debouncedQuery, dateRange: newValue) }
        .onChange(of: query) { oldValue, newValue in
            // The search field promises "everything you've said": starting a search widens the
            // *default* Today filter to all dates (an explicit range the user picked stays).
            if oldValue.isEmpty, !newValue.isEmpty, dateRange == Self.defaultDateRange { dateRange = nil }
            debounceSearch(newValue)
        }
        .onChange(of: pickedDate) { _, date in jumpToDate(date) }
        .confirmationDialog(deleteConfirmation.title, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelection() }
        } message: {
            Text("This can't be undone. Saved audio for these dictations is removed too.")
        }
        .background(historyKeyboardShortcuts)
    }

    /// `--snapshots` only: the forced filter, date range, open row and selecting mode.
    private func applySnapshotState() {
        if let snapshotHistoryFilter { filter = snapshotHistoryFilter }
        if let snapshotHistoryDateRange {
            dateRange = snapshotHistoryDateRange
            pager.reload(filter: filter, search: debouncedQuery, dateRange: snapshotHistoryDateRange)
        }
        if snapshotHistoryAllDates {
            dateRange = nil
            pager.reload(filter: filter, search: debouncedQuery, dateRange: nil)
        }
        if let snapshotHistoryDetailID {
            selectedID = snapshotHistoryDetailID
            compactShowsDetail = true
        }
        if snapshotHistorySelecting {
            isSelecting = true
            selection = Set(allRows.prefix(snapshotHistorySelectionCount).map(\.id))
        }
    }

    // MARK: List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            listHeader
            Divider().overlay(Theme.hairline)
            if pager.isLoadingFirstPage {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pager.sections.isEmpty {
                EmptyState(
                    symbol: emptySymbol,
                    title: emptyTitle,
                    message: emptyMessage,
                    actionTitle: dateRange == .today ? "Show all dates" : (dateRange != nil ? "Clear filter" : nil),
                    action: dateRange != nil ? { dateRange = nil } : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HistoryListContent(
                    pager: pager,
                    selectedID: $selectedID,
                    isSelecting: isSelecting,
                    multiSelection: selection,
                    onToggleSelection: toggleSelection,
                    jumpTarget: $jumpTarget,
                    revealRowID: $revealRowID,
                    onUndoAction: { record in Task { await model.voiceActions.undo(record: record) } },
                    onRowsDeleted: reloadAfterDelete)
            }
            if isSelecting {
                Divider().overlay(Theme.hairline)
                HistorySelectionActionBar(count: selectedDictations.count, onDelete: requestDelete)
                    .padding(Theme.Space.m)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSunken.opacity(0.4))
    }

    /// Browsing: the title, search, the date scope (Today, Last 7 days, All dates as three
    /// labelled choices), the week strip and the app chips. Selecting: the title and one lime
    /// band that says so (`HistorySelectionHeader`); search and filters step aside until Done.
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                ScreenHeader(title: "History")
                Spacer()
                // Nothing to select in an empty list.
                if !isSelecting, !pager.sections.isEmpty {
                    Button("Select") { beginSelection() }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Select several dictations to delete")
                        .accessibilityLabel("Select several dictations")
                }
            }
            if isSelecting {
                HistorySelectionHeader(
                    count: selectedDictations.count, source: selectionSource,
                    selectAllTitle: HistorySelection.selectAllTitle(
                        count: HistorySelection.loadedCount(allRows), hasMore: pager.hasMore),
                    onSelectAll: selectAllLoaded, onDone: exitSelection)
                    .transition(.opacity)
            } else {
                browsingControls
            }
        }
        .padding(Theme.Space.l)
    }

    @ViewBuilder
    private var browsingControls: some View {
        SearchField(text: $query, prompt: "Search everything you've said")
            .focused($searchFocused)
        HStack(spacing: Theme.Space.s) {
            HistoryScopeBar(selection: HistoryScope.current(for: dateRange, now: model.dayClock.now)) { scope in
                dateRange = scope.dateRange
            }
            IconButton(symbol: "calendar", help: "Jump to a date") { showDatePicker.toggle() }
                .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                    DatePicker("Jump to", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding()
                }
            HistoryDateFilterButton(dateRange: $dateRange, isPresented: $showDateFilter)
        }
        HistoryDayStripView(days: dayStripEntries) { day in dateRange = .custom(start: day, end: day) }
        HStack(spacing: Theme.Space.s) {
            Button(filter == .needsAttention ? "Needs attention ✓" : "Needs attention") {
                filter = filter == .needsAttention ? .all : .needsAttention
            }
            .buttonStyle(SecondaryButtonStyle())
            .fixedSize()
            HistoryAppFilterChips(chips: appChips, selection: $filter)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Only for a range the scope bar cannot show as chosen (yesterday, one earlier
            // day, a custom range); Today, Last 7 days and All dates are already named above.
            if let dateRange, HistoryScope.showsRangeChip(for: dateRange, now: model.dayClock.now) {
                DateRangeChip(label: dateRange.label) { self.dateRange = nil }
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Theme.fade, value: dateRange)
    }

    /// "All apps" plus one chip per app (most-used first, no counts), all from
    /// whole-history aggregates (`HistoryPager.appCounts`) rather than whatever pages happen to
    /// be loaded — so the chips don't shrink or vanish when a filter narrows the list.
    private var appChips: [HistoryAppChip] {
        HistoryAppChipModel.chips(from: pager.appCounts)
    }

    /// The day strip's 7-day window, from `HistoryPager.weekActivity` (read from the table, so a
    /// day filter doesn't make the other days look empty).
    private var dayStripEntries: [DayStripEntry] {
        return HistoryDayStrip.week(
            endingOn: model.dayClock.now, entryCounts: pager.weekActivity.entries, attentionCounts: pager.weekActivity.attention,
            selectedDay: dateRange?.singleSelectedDay())
    }

    private var emptySymbol: String {
        if dateRange != nil { return "calendar" }
        return query.isEmpty ? "mic" : "magnifyingglass"
    }

    private var emptyTitle: String {
        if dateRange == .today, query.isEmpty { return "Nothing dictated yet today" }
        if dateRange != nil { return "No dictations in this range" }
        if !query.isEmpty { return "No matches" }
        if case .needsAttention = filter { return "Nothing needs attention" }
        return HistoryCopy.emptyTitle
    }

    private var emptyMessage: String {
        if dateRange == .today, query.isEmpty { return "Earlier dictations are under All dates." }
        if dateRange != nil {
            return query.isEmpty
                ? "Nothing was dictated in \(dateRange?.label ?? "this range")."
                : "Nothing matches “\(query)” in \(dateRange?.label ?? "this range")."
        }
        if !query.isEmpty { return "Nothing you've dictated matches “\(query)”." }
        if case .needsAttention = filter { return "Every dictation was typed in cleanly. Recovered items show up here." }
        return HistoryCopy.emptyMessage(triggerGlyph: model.settings.triggerKey.glyph)
    }

    // MARK: Detail pane

    /// List → detail: the pane itself never re-lays out (no layout shift); only its content
    /// changes, arriving 8 pt from the trailing edge with a fade and leaving faster than it came
    /// (DESIGN-LANGUAGE.md §2.3, "enter from where it came; leave faster than you arrive").
    private var detailPane: some View {
        ZStack {
            detailContent
                .transition(detailTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(isSnapshot ? nil : Theme.Motion.spatial(Theme.Motion.snappy, reduceMotion: reduceMotion), value: selectedID)
    }

    private var detailTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 8)),
            removal: .opacity.animation(Theme.Motion.fade))
    }

    @ViewBuilder
    private var detailContent: some View {
        if isSelecting {
            // Never one dictation while selecting: the pane says how many are chosen instead.
            HistorySelectionSummary(count: selectedDictations.count)
        } else if let id = selectedID, let row = findRow(id) {
            if row.isStack {
                StackedFailureDetailPane(items: row.items)
                    .id(id)
            } else {
                HistoryDetailPane(dictation: row.primary, query: debouncedQuery)
                    .id(id)
            }
        } else if openedItemMissing {
            Label(HistoryCopy.openedItemMissing, systemImage: "questionmark.circle")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            Label("Pick a dictation to see its transcript, audio and stats", systemImage: "text.bubble")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var allRows: [HistoryRowModel] { pager.sections.flatMap(\.rows) }

    private func findRow(_ id: Int64) -> HistoryRowModel? {
        allRows.first { $0.id == id }
    }

    /// What the confirmation asks about and what it will remove: one value, so they agree.
    private var deleteConfirmation: HistoryDeleteFlow.Confirmation {
        HistoryDeleteFlow.confirmation(rows: allRows, selected: selection)
    }

    /// The dictations behind the checked rows; a checked stack of failures counts each recording.
    private var selectedDictations: [Dictation] { deleteConfirmation.dictations }

    // MARK: Actions

    private func beginSelection() {
        withAnimation(reduceMotion ? nil : Theme.fade) {
            isSelecting = true
            selection = []
            selectionAnchor = nil
        }
    }

    private func exitSelection() {
        withAnimation(reduceMotion ? nil : Theme.fade) {
            isSelecting = false
            selection = []
            selectionAnchor = nil
        }
    }

    /// A row clicked while selecting: add it or take it out; with Shift, everything from the
    /// last row clicked to this one.
    private func toggleSelection(_ id: Int64) {
        selection = HistorySelection.isShiftClick
            ? HistorySelection.extending(selection, from: selectionAnchor, to: id, order: allRows.map(\.id))
            : HistorySelection.toggling(id, in: selection)
        selectionAnchor = id
    }

    /// ⌘A while selecting. A text field with the keyboard (the Assistant's message field is on
    /// screen beside History) keeps its own Select All: the key is passed on to it.
    private func handleCommandA() {
        let textFieldHasFocus = NSApp.keyWindow?.firstResponder is NSText
        switch HistorySelection.commandA(isSelecting: isSelecting, textFieldHasFocus: textFieldHasFocus) {
        case .selectAll: selectAllLoaded()
        case .leaveToTextField: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case .ignore: break
        }
    }

    private func selectAllLoaded() {
        selection = HistorySelection.selectingAll(allRows)
    }

    /// What the rows are being chosen from, for the selecting band: the search and filters
    /// that are hidden while selecting still decide what is listed.
    private var selectionSource: String {
        var appName: String?
        if case .app(let bundleID) = filter {
            appName = appChips.first { $0.bundleID == bundleID && !$0.isAllApps }?.name ?? "one app"
        }
        return HistorySelection.source(
            dateLabel: dateRange?.label ?? HistoryScope.allDates.title, search: debouncedQuery,
            needsAttentionOnly: filter == .needsAttention, appName: appName)
    }

    private func deleteSelection() {
        let toDelete = deleteConfirmation.dictations
        withAnimation(Theme.spatial(reduceMotion: reduceMotion)) {
            model.library.deleteDictations(toDelete)
            if let selectedID, selection.contains(selectedID) { self.selectedID = nil }
            isSelecting = false
            selection = []
            selectionAnchor = nil
            reloadAfterDelete()
        }
    }

    /// Reads the list again after a delete. Only the first page is observed live
    /// (`HistoryPager.observeTopOfList`), and a search is not observed at all, so a row deleted
    /// further down, or from search results, would otherwise stay on screen until the next
    /// reload, where it could be selected again and counted in a "Delete N" that removes fewer.
    private func reloadAfterDelete() {
        pager.reload(filter: filter, search: debouncedQuery, dateRange: dateRange)
        if let selectedID, findRow(selectedID) == nil { self.selectedID = nil }
    }

    /// Opens the dictation another screen asked for. Its day comes from the store, by id, so an
    /// old one opens as well as today's; the row is then found in that day, loading further
    /// pages if the day is long. On the way it leaves selecting and any search or filter that
    /// could hide the row. One that no longer exists changes nothing in the list: the detail
    /// pane says so.
    private func openRequestedItem() {
        guard let id = openRequest.take() else { return }
        let stored: Dictation?
        do {
            stored = try model.store.dictation(id: id)
        } catch {
            Self.log.error("history open by id failed: \(error.localizedDescription)")
            stored = nil
        }
        guard case .show(let range) = HistoryOpenTarget.plan(for: stored, now: model.dayClock.now, calendar: .current) else {
            showOpenedItemMissing()
            return
        }
        isSelecting = false
        selection = []
        selectionAnchor = nil
        query = ""
        debouncedQuery = ""
        filter = .all
        dateRange = range
        pager.reload(filter: .all, search: nil, dateRange: range)
        guard let rowID = HistoryOpenTarget.locate(id, in: pager) else {
            showOpenedItemMissing()
            return
        }
        openedItemMissing = false
        selectedID = rowID
        revealRowID = rowID
    }

    private func showOpenedItemMissing() {
        selectedID = nil
        openedItemMissing = true
    }

    private static let log = Logger(subsystem: "app.hushy", category: "history")

    private func debounceSearch(_ text: String) {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debouncedQuery = text
        }
    }

    private func jumpToDate(_ date: Date) {
        jumpTarget = Calendar.current.startOfDay(for: date)
        showDatePicker = false
    }

    /// Hidden buttons carry the page's keyboard shortcuts without an explicit menu: ⌘F
    /// focuses search, ⌫ deletes the current selection (with confirmation), ⌘C copies the
    /// open dictation's text, Esc clears the search or stops selecting, and ⌘A, while selecting,
    /// does what the band's select-all button does. Up/down/space live on the List itself (native selection
    /// handles arrow keys; Space is intercepted in `HistoryListContent`).
    private var historyKeyboardShortcuts: some View {
        Group {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { requestDelete() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { copySelected() }.keyboardShortcut("c", modifiers: .command)
            Button("") { clearOrExitOnEscape() }.keyboardShortcut(.escape, modifiers: [])
            // Only while selecting, so browsing leaves Command-A to the system entirely.
            if isSelecting {
                Button("") { handleCommandA() }.keyboardShortcut("a", modifiers: .command)
            }
        }
        .hidden()
    }

    /// The Delete button (selecting) and the Delete key both come here, and neither deletes:
    /// they put the rows to the confirmation, and only its Delete button removes them.
    private func requestDelete() {
        guard let rows = HistoryDeleteFlow.rowsToConfirm(isSelecting: isSelecting, selection: selection, openRowID: selectedID)
        else { return }
        selection = rows
        confirmDelete = true
    }

    private func copySelected() {
        guard !isSelecting, let selectedID, let row = findRow(selectedID), !row.isStack else { return }
        TextInserter.copy(row.primary.text)
    }

    private func clearOrExitOnEscape() {
        if searchFocused, !query.isEmpty {
            query = ""
        } else if isSelecting {
            exitSelection()
        }
    }
}

/// History's sentences that a test reads.
enum HistoryCopy {
    /// Where the detail would be, when another screen asked to open a dictation that has since
    /// been deleted or removed by the retention setting.
    static let openedItemMissing = "That dictation is no longer in History."

    /// Before anything has been dictated at all: what this page lists, and how to start with the
    /// person's own dictation key. Home's Today card says it for one day (`HomeFeedCopy`); this
    /// one is the whole list. It does not say "kept": the retention setting can remove old ones.
    static let emptyTitle = "Your dictations are listed here"
    static func emptyMessage(triggerGlyph: String) -> String {
        "Nothing yet. Hold \(triggerGlyph) in any app and talk, and your first dictation shows up here, searchable and stored on this Mac."
    }
}

extension EnvironmentValues {
    /// Snapshot-only: shows `HistoryView` with no date filter ("All dates"). The older
    /// `snapshotHistoryDateRange` cannot say this: its nil means "leave the default".
    @Entry var snapshotHistoryAllDates = false
    /// Snapshot-only: how many rows `snapshotHistorySelecting` checks (the first N).
    @Entry var snapshotHistorySelectionCount = 3
}
