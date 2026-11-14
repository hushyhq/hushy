import AppKit
import MurmurCore
import SwiftUI

/// Selecting many dictations in History, as opposed to opening one. The two used to look alike:
/// the same rows, the same highlight, and a click that either opened a dictation or selected it
/// depending on a button pressed earlier. While selecting, every row now carries a check mark
/// in place of its timeline branch, the header and the detail pane both say what mode this is,
/// a click adds or removes a row (it never opens one), and Done ends it.
///
/// The set arithmetic and the words are pure (`HistoryNavigationTests`).
enum HistorySelection {
    /// A plain click: add the row, or take it out.
    static func toggling(_ id: Int64, in selection: Set<Int64>) -> Set<Int64> {
        selection.contains(id) ? selection.subtracting([id]) : selection.union([id])
    }

    /// A shift-click: add every row from the last one clicked (`anchor`) to this one, in the
    /// order the list shows them. With no usable anchor it is a plain add.
    static func extending(_ selection: Set<Int64>, from anchor: Int64?, to id: Int64, order: [Int64]) -> Set<Int64> {
        guard let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) else {
            return selection.union([id])
        }
        return selection.union(order[min(start, end)...max(start, end)])
    }

    /// Every dictation behind the selected rows, in list order. A selected stack of failures
    /// stands for all of its recordings, so the count and the delete cover each of them.
    static func dictations(in rows: [HistoryRowModel], selected: Set<Int64>) -> [Dictation] {
        rows.filter { selected.contains($0.id) }.flatMap(\.items)
    }

    /// The header band's title: the mode, said once. The count sits beside Delete.
    static let modeTitle = "Selecting dictations"

    static func title(count: Int) -> String {
        count == 0 ? "Nothing selected yet" : "\(count) dictation\(count == 1 ? "" : "s") selected"
    }

    /// Under the header band's title: what a click does here.
    static func hint(count: Int) -> String {
        count == 0
            ? "Click a row to select it. Nothing opens while you are selecting."
            : "Click a row to add or remove it. Done goes back to opening one at a time."
    }

    /// In the detail pane, under the count: what Delete will do, in the confirmation's own words.
    static func paneMessage(count: Int) -> String {
        count == 0
            ? "Pick the dictations to delete from the list. Done goes back to opening one at a time."
            : "Delete removes \(count == 1 ? "it" : "them"), and any saved audio with \(count == 1 ? "it" : "them"). This can't be undone."
    }

    static func deleteTitle(count: Int) -> String {
        count == 0 ? "Delete" : "Delete \(count)"
    }

    /// Whether Shift was held for the click being handled (the rows are buttons, which do not
    /// report modifiers themselves): the click's own event, so releasing Shift a moment before
    /// the mouse button does not lose it.
    @MainActor static var isShiftClick: Bool {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
    }

    /// What the checked rows are being chosen from. While selecting, search and the filters are
    /// not drawn but still decide which rows are listed, so the band says them: the dates, and
    /// any search, "Needs attention" or app filter that is on.
    static func source(dateLabel: String, search: String, needsAttentionOnly: Bool, appName: String?) -> String {
        var parts = ["From \(dateLabel)"]
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { parts.append("matching “\(query)”") }
        if needsAttentionOnly { parts.append("needing attention only") }
        if let appName { parts.append("in \(appName) only") }
        return parts.joined(separator: ", ") + "."
    }

    /// What Command-A does on the History page. While selecting it is the select-all button
    /// (the list selected everything on Command-A before it had a selecting mode of its own).
    /// A text field that has the keyboard keeps its own Select All, whatever the mode: the
    /// Assistant's message field sits beside History.
    enum CommandA: Equatable { case selectAll, leaveToTextField, ignore }

    static func commandA(isSelecting: Bool, textFieldHasFocus: Bool) -> CommandA {
        if textFieldHasFocus { return .leaveToTextField }
        return isSelecting ? .selectAll : .ignore
    }

    /// Every loaded row, whether or not it is scrolled into view.
    static func selectingAll(_ rows: [HistoryRowModel]) -> Set<Int64> { Set(rows.map(\.id)) }

    /// How many dictations the loaded rows stand for (a stack of failures counts each recording).
    static func loadedCount(_ rows: [HistoryRowModel]) -> Int { rows.reduce(0) { $0 + $1.items.count } }

    /// The select-all button's words: the number it selects, and, while older pages have not
    /// loaded yet, that these are only the ones loaded so far. Nil with nothing to select.
    static func selectAllTitle(count: Int, hasMore: Bool) -> String? {
        guard count > 0 else { return nil }
        if hasMore { return "Select the \(count) loaded so far" }
        return count == 1 ? "Select the 1 here" : "Select all \(count)"
    }
}

/// Deleting from History. A request (the Delete button while selecting, the Delete key) never
/// deletes: it names the rows to ask about, and only the confirmation deletes them. The
/// confirmation holds the dictations themselves, so the number asked about, the number on the
/// button and the rows removed cannot differ. Pure (`HistoryNavigationTests`).
enum HistoryDeleteFlow {
    /// The rows a delete request asks to confirm, or nil when there is nothing to delete.
    /// Selecting: the checked rows (never the row that was open before). Browsing: the open row.
    static func rowsToConfirm(isSelecting: Bool, selection: Set<Int64>, openRowID: Int64?) -> Set<Int64>? {
        if isSelecting { return selection.isEmpty ? nil : selection }
        return openRowID.map { [$0] }
    }

    struct Confirmation: Equatable {
        /// Every dictation behind the rows asked about; a stack of failures gives each recording.
        let dictations: [Dictation]

        var count: Int { dictations.count }
        var title: String { "Delete \(count) dictation\(count == 1 ? "" : "s")?" }
    }

    static func confirmation(rows: [HistoryRowModel], selected: Set<Int64>) -> Confirmation {
        Confirmation(dictations: HistorySelection.dictations(in: rows, selected: selected))
    }
}

/// The check mark a row carries while History is selecting: an empty ring, or a filled lime disc
/// with a tick. It sits where the row's timeline branch normally is, so the whole list changes
/// shape the moment selecting starts.
struct HistorySelectionMark: View {
    let isOn: Bool

    static let size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle().fill(isOn ? Theme.phosphorFill : Theme.bgRaised)
            Circle().strokeBorder(isOn ? Theme.phosphorFill : Theme.textTertiary.opacity(0.7), lineWidth: 1.25)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.onPhosphor)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

/// History's header while selecting: a lime-washed band in place of search and filters, saying
/// what mode this is, what the rows are being chosen from (the hidden search and filters still
/// apply) and what a click does, with a select-all button and Done. The count is beside Delete.
struct HistorySelectionHeader: View {
    let count: Int
    /// "From Today, in Mail only.": what the list is showing (`HistorySelection.source`).
    let source: String
    /// The select-all button's words (`HistorySelection.selectAllTitle`); nil hides it.
    let selectAllTitle: String?
    let onSelectAll: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.phosphor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(HistorySelection.modeTitle)
                    .font(Theme.Font.emphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(source)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(HistorySelection.hint(count: count))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let selectAllTitle {
                    Button(selectAllTitle, action: onSelectAll)
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.phosphor)
                        .padding(.top, 2)
                        .help("Checks every one of them, including rows scrolled out of view")
                }
            }
            Spacer(minLength: Theme.Space.s)
            Button("Done", action: onDone)
                .buttonStyle(SecondaryButtonStyle())
                .help("Stop selecting (Esc)")
                .accessibilityLabel("Done selecting")
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.phosphorTint))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.phosphor.opacity(0.25), lineWidth: 0.5))
    }
}

/// What the detail pane shows while selecting: the count and the way out, never one dictation,
/// so the right-hand side cannot be mistaken for an opened item.
struct HistorySelectionSummary: View {
    let count: Int

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack {
                // Stacked sheets: "several", where the resting pane shows one speech bubble.
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.bgRaised)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 1))
                        .frame(width: 54, height: 38)
                        .offset(x: CGFloat(index - 1) * 7, y: CGFloat(1 - index) * 6)
                }
                // On the front sheet.
                HistorySelectionMark(isOn: count > 0).offset(x: 7, y: -6)
            }
            .frame(height: 60)
            .accessibilityHidden(true)
            Text(HistorySelection.title(count: count))
                .font(.system(size: 20, design: .serif))
                .foregroundStyle(Theme.textPrimary)
            Text(HistorySelection.paneMessage(count: count))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }
}

/// The bar under the list while selecting: the count on the left, Delete on the right.
struct HistorySelectionActionBar: View {
    let count: Int
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Text(HistorySelection.title(count: count))
                .font(Theme.Font.emphasis)
                .foregroundStyle(count == 0 ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button(HistorySelection.deleteTitle(count: count), action: onDelete)
                .buttonStyle(HistoryDestructiveButtonStyle())
                .disabled(count == 0)
                .accessibilityLabel(count == 0 ? "Delete" : "Delete \(count) selected dictation\(count == 1 ? "" : "s")")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct HistoryDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .background(Capsule().fill(Theme.error).brightness(configuration.isPressed ? -0.08 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}
