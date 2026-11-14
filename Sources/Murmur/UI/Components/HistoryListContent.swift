import AppKit
import MurmurCore
import SwiftUI

/// The native `List` (NSTableView-backed) behind History's left pane: one `Section` per day
/// with a sticky header, rows grouped into consecutive same-app "runs" (one icon per run, see
/// `HistoryDaySection.runs`/`HistoryGrouping`). Browsing binds List's own single selection to
/// `selectedID` for master-detail. Selecting many (`isSelecting`) reads differently on purpose:
/// every dictation row is a button with a check mark that adds it to or takes it out of
/// `multiSelection` (`HistorySelection`), so a click there can never open a dictation and a
/// click while browsing can never select one; the arrow keys move a cursor and Space checks the
/// row under it. A `HistoryScrubber` rides the trailing edge, synced to the same `pager`.
struct HistoryListContent: View {
    let pager: HistoryPager
    @Binding var selectedID: Int64?
    let isSelecting: Bool
    /// The checked rows while selecting, owned by `HistoryView`.
    let multiSelection: Set<Int64>
    /// A row clicked while selecting.
    let onToggleSelection: (Int64) -> Void
    @Binding var jumpTarget: Date?
    /// A row to scroll into view (an item opened from outside History); cleared once done.
    @Binding var revealRowID: Int64?
    /// Called when a voice action's "Undo" link is tapped. Voice actions themselves are already
    /// interleaved chronologically into `pager.sections[].timelineRuns` (see `HistoryTimelineRow`
    /// and `HistoryPager.rebuildSections`), so this view never merges them in itself.
    var onUndoAction: ((ActionRecord) -> Void)?
    /// Called after a row's context menu deleted it, so the owner can read the list again.
    var onRowsDeleted: (() -> Void)?
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var topVisibleID: Int64?
    @State private var scrubberHover: ScrubberHover?
    /// While selecting: the row the arrow keys are on (the list's native highlight). Space
    /// checks or unchecks it, so selecting many works without a mouse.
    @State private var cursorID: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                list.frame(maxWidth: .infinity)
                if !isSnapshot {
                    HistoryScrubber(pager: pager, visibleID: topVisibleID, onSelect: { id, day in
                        // Scrubbing tracks the pointer, so the list follows it directly; only
                        // a discrete jump would earn a spring, and even that is off under
                        // Reduce Motion.
                        withAnimation(nil) {
                            if let day { proxy.scrollTo(day, anchor: .top) }
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }, hover: $scrubberHover)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let scrubberHover {
                    ScrubberBubble(hover: scrubberHover)
                        .alignmentGuide(.top) { $0[VerticalAlignment.center] - scrubberHover.y }
                        .padding(.trailing, HistoryScrubber.trackWidth + Theme.Space.s)
                        .transition(.opacity)
                }
            }
            // Fade the bubble in/out only; while it's showing, it follows the pointer 1:1
            // (animating its position would make it lag behind the cursor).
            .animation(Theme.fade, value: scrubberHover != nil)
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : Theme.settle) { proxy.scrollTo(target, anchor: .top) }
                jumpTarget = nil
            }
            .onChange(of: revealRowID) { _, rowID in
                guard let rowID else { return }
                withAnimation(reduceMotion ? nil : Theme.settle) { proxy.scrollTo(rowID, anchor: .center) }
                revealRowID = nil
            }
            .onKeyPress(.space) { handleSpace() }
        }
    }

    /// `List` is NSTableView-backed; `ImageRenderer` can't draw it (same category as `TextField`
    /// and `HSplitView` — see `SnapshotTextField`/`ResizableSplit`), so snapshot mode falls back
    /// to a plain, flat stack of the same row content. Browsing and selecting share one `List`
    /// (two would be rebuilt on Select and Done, losing the scroll position); only what its
    /// native highlight means changes: the open dictation while browsing, a keyboard cursor
    /// while selecting.
    @ViewBuilder
    private var list: some View {
        if isSnapshot {
            SnapshotHistoryList(pager: pager, selectedID: selectedID, isSelecting: isSelecting, multiSelection: multiSelection)
        } else {
            List(selection: isSelecting ? $cursorID : $selectedID) { rows }
                .listStyle(.plain)
                .onChange(of: isSelecting) { _, _ in cursorID = nil }
        }
    }

    /// Space plays the open dictation's audio while browsing; while selecting it checks or
    /// unchecks the row the arrow keys are on.
    private func handleSpace() -> KeyPress.Result {
        if isSelecting {
            guard let cursorID else { return .ignored }
            onToggleSelection(cursorID)
            return .handled
        }
        guard let selectedID,
              let row = pager.sections.flatMap(\.rows).first(where: { $0.id == selectedID }),
              !row.isStack, let path = row.primary.audioPath
        else { return .ignored }
        AudioPlayer.shared.toggle(path)
        return .handled
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(pager.sections) { section in
            Section {
                ForEach(section.timelineRuns) { run in
                    HistoryRunView(
                        run: run, pager: pager, topVisibleID: $topVisibleID, onUndoAction: onUndoAction,
                        onRowsDeleted: onRowsDeleted, selection: isSelecting ? multiSelection : nil, onToggleSelection: onToggleSelection)
                }
            } header: {
                HistoryDayHeader(day: section.day)
            }
            .id(section.day)
        }
    }
}

/// One run: the shared `TimelineGroupHeader` on its own row (never fused with the first entry —
/// matching Home exactly), then every entry (dictation or, interleaved chronologically, a voice
/// action — see `HistoryTimelineRow`) as its own row with a branch tick off the run's continuous
/// spine. Dictation rows keep their own `List` tag, context menu and needs-attention marker;
/// action rows reuse `TimelineEntryRow`'s action rendering (icon, "Added … · detail", Undo link)
/// so History and Home read identically. The spine is drawn once, as a background behind the
/// whole run, from just under the header icon to the last entry's tick.
private struct HistoryRunView: View {
    let run: HistoryRun<HistoryTimelineRow>
    let pager: HistoryPager
    @Binding var topVisibleID: Int64?
    let onUndoAction: ((ActionRecord) -> Void)?
    let onRowsDeleted: (() -> Void)?
    /// The checked rows while History is selecting; nil while browsing.
    let selection: Set<Int64>?
    let onToggleSelection: (Int64) -> Void

    var body: some View {
        headerRow
        ForEach(Array(run.items.enumerated()), id: \.element.id) { index, item in
            let isLast = index == run.items.count - 1
            entryRow(item, isFirst: index == 0, isLast: isLast)
        }
    }

    private var headerRow: some View {
        TimelineGroupHeader(appBundleID: run.appBundleID, appName: run.items.first?.appName, count: run.items.count)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .padding(.top, Theme.Space.xs)
    }

    /// Every entry draws its own slice of the tree (`TimelineBranch` via `TimelineRowScaffold`),
    /// reaching the very top of its row frame so consecutive `List` rows join into one
    /// continuous spine; the run's last entry ends it with a rounded elbow.
    @ViewBuilder
    private func entryRow(_ item: HistoryTimelineRow, isFirst: Bool, isLast: Bool) -> some View {
        switch item {
        case .dictation(let row):
            HistoryRow(row: row, isLast: isLast, checked: selection?.contains(row.id), onToggle: { onToggleSelection(row.id) })
                .tag(row.id)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .onAppear {
                    if isFirst { topVisibleID = row.id }
                    pager.loadNextPageIfNeeded(currentID: row.id)
                }
                .contextMenu { HistoryRowContextMenu(row: row, onDeleted: onRowsDeleted) }
        case .action(let record):
            // A voice action is not a dictation: while selecting it stays in place, dimmed,
            // with nothing to check and no Undo to hit by mistake.
            let isSelecting = selection != nil
            TimelineEntryRow(
                entry: .action(record), isLast: isLast, showsBranch: !isSelecting,
                onUndo: isSelecting ? nil : { onUndoAction?(record) })
                .opacity(isSelecting ? 0.45 : 1)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        }
    }
}

/// Snapshot-only stand-in for the real `List`: the same day sections and runs, laid out in a
/// plain `VStack` `ImageRenderer` can draw, with the selected row's background drawn manually
/// since there's no live `List` selection ring to render it. No `ScrollView` wrapper — like
/// `ScreenLayout`, `ImageRenderer` can't draw scroll view contents, so this lays out flat at
/// full height instead (fine here since fixture data is only a handful of rows).
private struct SnapshotHistoryList: View {
    let pager: HistoryPager
    let selectedID: Int64?
    let isSelecting: Bool
    let multiSelection: Set<Int64>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pager.sections) { section in
                Section {
                    ForEach(section.timelineRuns) { run in
                        runRows(run)
                    }
                } header: {
                    HistoryDayHeader(day: section.day)
                        .padding(.horizontal, Theme.Space.s)
                }
            }
        }
    }

    @ViewBuilder
    private func runRows(_ run: HistoryRun<HistoryTimelineRow>) -> some View {
        TimelineGroupHeader(appBundleID: run.appBundleID, appName: run.items.first?.appName, count: run.items.count)
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.xs)
        ForEach(Array(run.items.enumerated()), id: \.element.id) { index, item in
            let isLast = index == run.items.count - 1
            switch item {
            case .dictation(let row):
                HistoryRow(
                    row: row, isLast: isLast, isSelected: !isSelecting && selectedID == row.id,
                    checked: isSelecting ? multiSelection.contains(row.id) : nil)
                    .padding(.horizontal, Theme.Space.s)
            case .action(let record):
                TimelineEntryRow(entry: .action(record), isLast: isLast, showsBranch: !isSelecting)
                    .opacity(isSelecting ? 0.45 : 1)
                    .padding(.horizontal, Theme.Space.s)
            }
        }
    }
}

/// Sticky per-day header: just the day label. The old "7 · 17 words" tally was a decorative
/// total (and "7" counted stacked failures and actions inconsistently with the visible rows),
/// so it's gone — see DECISIONS.md, "Sidebar badges: only actionable counts".
private struct HistoryDayHeader: View {
    let day: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.Font.eyebrow).tracking(0.8).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.vertical, Theme.Space.xs)
        .padding(.horizontal, 2)
        .background(Theme.bgBase.opacity(0.96))
    }

    private var label: String {
        HistoryScrubberModel.dayLabel(for: day).uppercased()
    }
}

/// Copy / retry / delete, matching the detail pane's own actions — kept working per-row even
/// though rows in a run no longer each show their own app icon.
private struct HistoryRowContextMenu: View {
    @Environment(AppModel.self) private var model
    let row: HistoryRowModel
    var onDeleted: (() -> Void)?

    var body: some View {
        if row.isStack {
            Button("Delete all \(row.items.count)", role: .destructive) {
                withAnimation(Theme.settle) {
                    model.library.deleteDictations(row.items)
                    onDeleted?()
                }
            }
        } else {
            let item = row.primary
            if !item.text.isEmpty {
                Button("Copy") { TextInserter.copy(item.text) }
            }
            if item.status == .cancelled, DictationRecovery.action(for: item) == .copy {
                Button("Recover") { model.library.recover(item) }
            }
            if DictationRecovery.action(for: item) == .retryTranscription {
                Button("Retry transcription") { model.retryDictationTranscription(item) }
            }
            Button("Delete", role: .destructive) {
                withAnimation(Theme.settle) {
                    model.library.deleteDictation(item)
                    onDeleted?()
                }
            }
        }
    }
}

/// One History row, laid out by the same `TimelineRowScaffold` as Home's `TimelineEntryRow` —
/// same gutter, branch, font, time column and fixed status column — so the two screens are
/// pixel-identical. The run's header (icon + app name) is always its own row above, drawn by
/// `HistoryRunView.headerRow`. Honest chips (`TimelineChips`) sit under the text; the status column
/// holds a colored dot, or a count badge for a stacked run of failures. Deliberately lighter than
/// the detail pane — no waveform, diff or per-row actions.
private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let row: HistoryRowModel
    let isLast: Bool
    /// Snapshot-only: the live `List` draws its own selection, but the flat snapshot fallback has
    /// to tint the selected row itself.
    var isSelected = false
    /// While History is selecting many: whether this row is checked. Nil while browsing.
    var checked: Bool?
    var onToggle: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        if let checked {
            // The whole row is the control: a click checks or unchecks it and never opens it.
            // An unchecked row has a clear ground, and a plain button takes a click only where
            // something is drawn: the shape makes the empty parts of the row count too.
            Button(action: { onToggle?() }) { scaffold.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .accessibilityLabel(spokenLabel)
                .accessibilityValue(checked ? "Selected" : "Not selected")
                .accessibilityHint("Adds or removes this dictation from the selection")
        } else {
            scaffold.onHover { isHovered = $0 }
        }
    }

    /// What VoiceOver says for the row while selecting: its words, where and when, and whether
    /// it needs attention (the dot it shows).
    private var spokenLabel: String {
        var parts = [row.firstLine]
        if let app = row.appName { parts.append(app) }
        parts.append(row.timeLabel)
        if row.primary.needsAttention { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }

    private var highlight: TimelineRowHighlight {
        if isSelected || checked == true { return .selected }
        return isHovered ? .hover : .none
    }

    /// The shared row layout. While selecting, the check mark takes the timeline branch's place
    /// (centred on the spine, level with the first line), so the two modes never look alike.
    private var scaffold: some View {
        TimelineRowScaffold(isLast: isLast, highlight: highlight, showsBranch: checked == nil) {
            text
        } status: {
            statusBadge
        }
        .overlay(alignment: .topLeading) {
            if let checked {
                HistorySelectionMark(isOn: checked)
                    .offset(
                        x: TimelineMetrics.spineX - HistorySelectionMark.size / 2,
                        y: TimelineMetrics.branchY - HistorySelectionMark.size / 2)
            }
        }
        .contentShape(Rectangle())
    }

    private var text: some View {
        let item = row.primary
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.firstLine)
                    .font(TimelineMetrics.titleFont)
                    .foregroundStyle(row.isStack || item.status == .cancelled || (item.status == .failed && item.text.isEmpty)
                                     ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.timeLabel)
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            let marker = learnedMarker
            if hasTags || marker != nil {
                HStack(spacing: 4) {
                    if let language = item.language, let tag = LanguageTag.label(for: language) {
                        LanguageTag(text: tag)
                    }
                    if let marker { LearnedRowMarker(marker: marker) }
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.bgSunken))
                    }
                }
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if row.isStack {
            Text("\(row.items.count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.error)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Theme.error.opacity(0.12)))
                .fixedSize()
                .padding(.leading, Theme.Space.xs)
        } else if row.primary.needsAttention {
            statusDot(for: row.primary)
        }
    }

    /// A quiet "Add Priya?" when this dictation produced a ready learned-term suggestion
    /// (its detail pane holds the card). Never on stacks of failures.
    private var learnedMarker: LearnedReview.RowMarker? {
        guard !row.isStack, let id = row.primary.id else { return nil }
        return model.learned.rowMarker(forDictation: id, items: model.library.learnedItems)
    }

    private var hasTags: Bool {
        !chips.isEmpty || (row.primary.language.flatMap { LanguageTag.label(for: $0) } != nil)
    }

    /// Honest chip summaries derived from the same `TimelineChips` logic the shared Home/History
    /// timeline uses — no guessed before/after word pairs.
    private var chips: [String] {
        guard !row.isStack else { return [] }
        return TimelineChips.chips(rawText: row.primary.rawText, cleanedText: row.primary.text)
    }

    @ViewBuilder
    private func statusDot(for item: Dictation) -> some View {
        switch item.status {
        case .notInserted: TimelineStatusDot(color: Theme.warning)
        case .cancelled: TimelineStatusDot(color: Theme.textTertiary)
        case .failed: TimelineStatusDot(color: Theme.error)
        case .inserted: EmptyView()
        }
    }
}

/// A small rounded-square app avatar: the real app icon when one can be found, otherwise a
/// colored initial — matching the mockup's colored-badge list style either way.
struct AppBadge: View {
    let bundleID: String?
    var appName: String?

    private var initial: String {
        String((appName?.first).map(String.init) ?? "?").uppercased()
    }

    private var tint: Color {
        let key = bundleID ?? appName ?? ""
        guard !key.isEmpty else { return Theme.textTertiary }
        return Color(hue: Self.hue(for: key), saturation: 0.55, brightness: 0.62)
    }

    /// The same app gets the same hue on every launch without a lookup table. FNV-1a over the
    /// UTF-8 bytes, because `String.hashValue` is seeded per process and reshuffled the colours.
    static func hue(for key: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash % 360) / 360
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.18))
            if let icon = AppIcon.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Text(initial).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
