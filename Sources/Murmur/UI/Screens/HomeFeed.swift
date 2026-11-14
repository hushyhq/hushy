import MurmurCore
import SwiftUI

/// Home's "Today" feed: today's dictations, notes and voice actions as the shared timeline
/// (`TimelineGroupView`/`TimelineEntryRow`), grouped by app exactly as History groups them.
/// Past `HomeTimeline.dictationCap` dictations the rest sit behind "Show N more"; below the card
/// one row stands for the most recent earlier day (`EarlierDaySection`). Clicking a dictation
/// opens it in `HomeView`'s Quick Look panel (the same `HistoryDetailPane` History uses);
/// clicking the open row again closes it. Notes rows open Notes; voice action rows aren't
/// selectable and keep their Undo link.
struct TodayFeed: View {
    @Environment(AppModel.self) private var model
    let selection: HomeTimelineSelection
    let expansion: HomeExpansion
    let calendar: Calendar
    /// Groups the user folded away this session (see `collapseKey`).
    @State private var collapsed: Set<String> = []
    /// The highlighted dictation (its Quick Look is open, or was last), owned by `HomeView`.
    let selectedDictationID: Int64?
    let onSelectDictation: (Int64) -> Void
    /// Hands the next expansion state to `HomeView`, which owns it.
    let onExpansionChange: (HomeExpansion) -> Void
    /// Today's words and time saved, beside the "Today" label once there are any.
    var numbers: HomeTodayNumbers?
    /// The app lock is on: no rows, no numbers, one line saying so.
    var isLocked = false

    private var selectedEntryID: String? {
        selectedDictationID.map(TimelineEntry.id(forDictation:))
    }

    private var todayIsEmpty: Bool { selection.today.all.isEmpty }

    var body: some View {
        let notice = model.learned.notice(items: model.library.learnedItems)
        let habit = model.learned.habitOffer(items: model.library.learnedItems)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Eyebrow("Today")
                    .accessibilityAddTraits(.isHeader)
                if !isLocked, let numbers, let line = numbers.line {
                    Text(line)
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .help(numbers.help(measuredTypingWPM: model.settings.typingWPM.map { Int($0) }))
                        .accessibilityLabel("Today: \(line)")
                }
                Spacer()
                Button("All history →") { model.section = .history }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.phosphor)
                    .accessibilityLabel("All history")
            }
            if isLocked {
                HomeTodayLocked()
            } else if todayIsEmpty {
                if let notice { LearnedNoticeLine(notice: notice) }
                if let habit { HabitOfferLine(row: habit) }
                HomeTodayEmpty(triggerGlyph: model.settings.triggerKey.glyph)
            } else {
                todayCard(notice: notice, habit: habit)
            }
            if !isLocked, let earlier = selection.earlier {
                earlierDay(earlier)
            }
        }
    }

    private func todayCard(notice: LearnedReview.Notice?, habit: LearnedReview.Row?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // Learned-term notice: one quiet line above today's rows, never a toast.
                if let notice {
                    LearnedNoticeLine(notice: notice)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                                .offset(y: Theme.Space.l / 2)
                        }
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
                if let habit {
                    HabitOfferLine(row: habit)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                                .offset(y: Theme.Space.l / 2)
                        }
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
                ForEach(selection.todayGroups(expansion: expansion, calendar: calendar)) { group in
                    let key = Self.collapseKey(group)
                    TimelineGroupView(
                        group: group, selectedID: selectedEntryID,
                        onSelect: { entry in select(entry) },
                        onUndo: { record in undo(record) },
                        isCollapsed: collapsed.contains(key),
                        onToggleCollapse: { toggle(key) })
                }
                if selection.today.hiddenDictationCount > 0 {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        HomeShowMoreRow(
                            hiddenCount: selection.today.hiddenDictationCount, isExpanded: expansion.showAllToday,
                            day: "today") { onExpansionChange(expansion.togglingShowAllToday()) }
                    }
                }
            }
            .animation(Theme.fade, value: expansion.showAllToday)
        }
    }

    private func earlierDay(_ earlier: HomeDayEntries) -> some View {
        EarlierDaySection(
            day: earlier,
            groups: selection.earlierGroups(expansion: expansion, calendar: calendar),
            isOpen: expansion.isEarlierOpen(todayIsEmpty: todayIsEmpty),
            showAll: expansion.showAllEarlier,
            selectedEntryID: selectedEntryID,
            onToggleOpen: { onExpansionChange(expansion.togglingEarlier(todayIsEmpty: todayIsEmpty)) },
            onToggleShowAll: { onExpansionChange(expansion.togglingShowAllEarlier()) },
            onSelect: { entry in select(entry) },
            onUndo: { record in undo(record) })
    }

    private func select(_ entry: TimelineEntry) {
        switch entry {
        case .dictation(let dictation):
            if let id = dictation.id { onSelectDictation(id) }
        case .note(let note):
            model.section = .notes
            model.selectedNoteID = note.id
        case .action:
            break
        }
    }

    /// Keyed by the group's oldest entry: a new dictation joins the top of the newest group,
    /// so its first entry changes but its last one doesn't — a collapsed group stays collapsed.
    private static func collapseKey(_ group: TimelineGroup) -> String {
        group.entries.last?.id ?? String(group.id)
    }

    private func toggle(_ key: String) {
        withAnimation(Theme.fade) {
            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        }
    }

    private func undo(_ record: ActionRecord) {
        Task { await model.voiceActions.undo(record: record) }
    }
}

/// Today before its first dictation: what will be listed, and how to start. One compact row,
/// not the large centred empty state it was: the dictation card above is the screen's lead now,
/// and an empty day should not outweigh it.
struct HomeTodayEmpty: View {
    let triggerGlyph: String

    var body: some View {
        Card(padding: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "mic")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.bgSunken))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(HomeFeedCopy.todayEmptyTitle)
                        .font(Theme.Font.emphasis)
                        .foregroundStyle(Theme.textPrimary)
                    Text(HomeFeedCopy.todayEmptyMessage(triggerGlyph: triggerGlyph))
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Today while the app lock is on: one quiet row in place of the feed and the earlier day.
struct HomeTodayLocked: View {
    var body: some View {
        Card(padding: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.bgSunken))
                    .accessibilityHidden(true)
                Text(HomeFeedCopy.lockedTodayMessage)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Open (not-done) action items from ready notes, newest notes first — shown in the Assistant
/// column's "Open action items" section. See .claude/TASKS.md #4. Each item is the task with its
/// owner and due phrase under it when the note has them (`ActionItemDetail`), like the note view.
enum OpenActionItems {
    struct Item: Identifiable {
        let note: Note
        let itemIndex: Int
        let detail: ActionItemDetail
        var id: String { "\(note.id ?? 0)-\(itemIndex)" }
        /// The task alone for a note with fields; the whole line for an older note.
        var text: String { detail.task }
        /// "Priya · by Friday"; empty when the note has neither.
        var secondary: String { detail.secondaryText }
    }

    static let limit = 6

    /// The names that mean the user in an owner field: "You" (what the summary and the stored
    /// owner track call the note's owner) and their own name from Settings.
    static func myNames(userName: String?) -> [String] {
        ["You"] + [userName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    @MainActor
    static func current(in library: Library, mine: [String] = []) -> [Item] {
        select(notes: library.notes, isDone: { library.isActionItemDone($0, itemIndex: $1) }, mine: mine)
    }

    /// The open items of `notes` (already newest first) in order, at most `limit`. With `mine` (`myNames`), the user's own
    /// items come first, each group still newest note first; nothing is dropped or reordered
    /// beyond that, and an item whose owner field is empty or someone else's is never "mine".
    static func select(
        notes: [Note], isDone: (Note, Int) -> Bool,
        mine: [String] = [], limit: Int = limit
    ) -> [Item] {
        let open = notes
            .filter { $0.status == .ready && !$0.actionItems.isEmpty }
            .flatMap { note in
                note.actionItems.indices.compactMap { index -> Item? in
                    guard !isDone(note, index), let detail = note.actionItemDetail(at: index) else { return nil }
                    return Item(note: note, itemIndex: index, detail: detail)
                }
            }
        guard !mine.isEmpty else { return Array(open.prefix(limit)) }
        let own = open.filter { $0.detail.isOwned(by: mine) }
        let rest = open.filter { !$0.detail.isOwned(by: mine) }
        return Array((own + rest).prefix(limit))
    }
}

struct ActionItemToggleRow: View {
    let text: String
    var secondary: String = ""
    let noteTitle: String
    let isDone: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? Theme.success : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.system(size: 14))
                        .strikethrough(isDone, color: Theme.textTertiary)
                        .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    if !secondary.isEmpty {
                        Text(secondary)
                            .font(.system(size: 12))
                            .foregroundStyle(isDone ? Theme.textTertiary : Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Text(noteTitle).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Quiet page footer with the privacy promise — what we promise, not how it's built.
struct PrivacyFooter: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("Private by default. Your words, audio and notes stay on your Mac unless you send them.")
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, Theme.Space.m)
    }
}

/// Home's sentences that a test reads.
enum HomeFeedCopy {
    /// Today, before the first dictation of the day: what will appear, and how to start with the
    /// person's own dictation key (hold, or one tap for hands-free).
    static let todayEmptyTitle = "Today's dictations appear here"
    static func todayEmptyMessage(triggerGlyph: String) -> String {
        "Double-tap \(triggerGlyph) to talk, Enter to paste. Or hold \(triggerGlyph) while you talk. Each dictation is kept on this Mac."
    }

    /// The dictation card's lower band (`HomeDictationHero`).
    static let lastDictationTitle = "Last dictation"
    /// Before the first dictation ever, while dictation is ready: the band invites one, with a
    /// sentence that has a deliberate self-correction in it.
    static let tryItTitle = "Try it now"
    static let tryItSentence = "Let's meet at ten, no, nine, and bring your laptop."
    static func tryItMessage(triggerGlyph: String) -> String {
        "Double-tap \(triggerGlyph), say it, then press Enter to paste. Your words show up here."
    }
    /// Before the first dictation while dictation cannot work yet: no invitation to try.
    static let lastEmptyWaiting = "When dictation is ready, what you say shows up here, ready to copy."

    /// While the app lock is on: Home shows no dictated words. The card says so and offers
    /// Unlock; the Today feed says so in its place. Dictation itself is not locked.
    static let lockedMessage = "Your dictations are hidden while Hushy is locked. Dictation still works."
    static let lockedTodayMessage = "Today's dictations are hidden while Hushy is locked."
    static let unlockTitle = "Unlock"
}
