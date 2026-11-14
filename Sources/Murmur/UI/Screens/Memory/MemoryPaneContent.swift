import MurmurCore
import SwiftUI

/// What the Memory sheet's switches, links and buttons do. Snapshots leave them all empty.
struct MemoryPaneActions {
    var setPaused: (Bool) -> Void = { _ in }
    var edit: (MemoryEntry) -> Void = { _ in }
    var remove: (MemoryEntry) -> Void = { _ in }
    var restore: (MemoryEntry) -> Void = { _ in }
    var showFolder: () -> Void = {}
    var eraseAll: () -> Void = {}
    var done: () -> Void = {}
}

/// The Memory sheet as it is drawn: every entry with its date and app, pause, the folder and
/// erase. Takes plain values, so snapshots need no store (the same split as `UninstallSheetContent`).
struct MemoryPaneContent: View {
    let entries: [MemoryEntry]
    let isPaused: Bool
    var message: String?
    var folder = AppPaths.memoryDirectory.path
    var appName: (String) -> String = { $0 }
    /// Snapshots only: long notes drawn opened out.
    var opensLongNotes = false
    /// Snapshots only: the list of edits drawn opened out.
    var opensAllEdits = false
    var actions = MemoryPaneActions()
    @Environment(\.isSnapshot) private var isSnapshot

    static let width: CGFloat = 560
    /// The tallest the scrolling part may grow, so the buttons stay inside the Settings window.
    private static let listHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            SettingsGroup {
                SettingsRow(title: "Pause memory", detail: MemoryPaneCopy.pauseDetail, showsDivider: false) {
                    SwitchToggle(isOn: Binding(get: { isPaused }, set: { actions.setPaused($0) }))
                        .accessibilityLabel("Pause memory")
                }
            }
            // `ImageRenderer` can't draw a scroll view, so snapshots lay the list out flat.
            if isSnapshot {
                lists
            } else {
                ScrollView(.vertical) { lists }.frame(maxHeight: Self.listHeight)
            }
            footer
        }
        .padding(Theme.Space.xl)
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.bgBase)
        .onExitCommand(perform: actions.done)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Memory").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            Text(MemoryPaneCopy.lead).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if isPaused {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle").font(.system(size: 11, weight: .medium))
                    Text(MemoryPaneCopy.pausedNote)
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                .padding(.top, Theme.Space.xs)
            }
        }
    }

    private var lists: some View {
        let sections = MemoryPaneSections(entries: entries)
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            if sections.isEmpty { emptyCard }
            group("How you write", sections.writing)
            group("Words", sections.words)
            if !sections.edits.isEmpty {
                MemoryEditsGroup(edits: sections.edits, appName: appName, opensAll: opensAllEdits, actions: actions)
            }
            group("Forgotten", sections.forgotten)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [MemoryEntry]) -> some View {
        if !rows.isEmpty {
            SettingsGroup(title: title) {
                ForEach(rows) { entry in
                    MemoryEntryRow(
                        entry: entry, detail: MemoryPaneCopy.detail(entry, appName: appName),
                        isLast: entry.id == rows.last?.id, opensLongNote: opensLongNotes, actions: actions)
                }
            }
        }
    }

    /// The empty state: one line that says what will be listed here.
    private var emptyCard: some View {
        Card(padding: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 14, weight: .light)).foregroundStyle(Theme.textTertiary)
                Text(MemoryPaneCopy.empty).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.l + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsGroup {
                SettingsRow(title: "Memory folder", detail: folder) {
                    Button("Show in Finder", action: actions.showFolder).buttonStyle(SecondaryButtonStyle())
                }
                SettingsRow(title: "Erase all memory", detail: MemoryPaneCopy.eraseDetail, showsDivider: false) {
                    Button("Erase…", action: actions.eraseAll).buttonStyle(SecondaryButtonStyle())
                }
            }
            HStack(spacing: Theme.Space.s) {
                if let message {
                    Text(message).font(Theme.Font.caption).foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done", action: actions.done)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The entries in the order the sheet lists them, newest first inside each group.
struct MemoryPaneSections: Equatable {
    let writing: [MemoryEntry]
    let words: [MemoryEntry]
    let edits: [MemoryEntry]
    let forgotten: [MemoryEntry]

    var isEmpty: Bool { writing.isEmpty && words.isEmpty && edits.isEmpty && forgotten.isEmpty }

    init(entries: [MemoryEntry]) {
        let newestFirst = entries.sorted { $0.createdAt > $1.createdAt }
        // The notes for everywhere read first, in the file's order; the notes for single apps follow.
        writing = entries.filter { $0.kind == .profile } + newestFirst.filter { $0.kind == .style }
        words = newestFirst.filter { $0.kind == .term }
        edits = newestFirst.filter { $0.kind == .correction }
        forgotten = newestFirst.filter { $0.kind == .forgotten }
    }
}

enum MemoryPaneCopy {
    static let lead = "The words, writing notes and edits Hushy keeps about you. They live in a folder on this Mac that you can open and edit."
    static let pauseDetail = "While paused, Hushy does not use anything here. What is saved stays until you remove it."
    static let pausedNote = "Paused. Nothing below is being used."
    static let empty = "Nothing here yet. The words Hushy learns and the changes you make to your dictations are listed here, each with its date."
    static let eraseDetail = "Deletes everything in the folder, including the words you told Hushy to forget. This can't be undone."

    static func title(_ entry: MemoryEntry) -> String {
        guard entry.kind == .correction else { return entry.value }
        return "“\(entry.before ?? "")” → “\(entry.after ?? "")”"
    }

    /// "Heard as “valoria” · 3 Oct 2026 · Quillpad": what was heard (words only), the date, the app.
    static func detail(_ entry: MemoryEntry, appName: (String) -> String) -> String {
        var parts: [String] = []
        if entry.kind == .term, !entry.heardAs.isEmpty {
            parts.append("Heard as " + entry.heardAs.map { "“\($0)”" }.joined(separator: ", "))
        }
        if entry.kind == .forgotten { parts.append("Never learned again") }
        parts.append(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
        if entry.kind != .forgotten {
            parts.append(entry.appBundleID.flatMap { $0.isEmpty ? nil : appName($0) } ?? "All apps")
        }
        return parts.joined(separator: " · ")
    }

    /// The edits the group draws: all of them when open, else the newest few.
    static func shownEdits(_ edits: [MemoryEntry], isOpen: Bool) -> [MemoryEntry] {
        isOpen ? edits : Array(edits.prefix(MemoryEditsGroup.closedCount))
    }

    static func editCount(shown: Int, of total: Int) -> String {
        shown < total ? "The newest \(shown) of \(total)" : "All \(total), newest first"
    }

    /// One edit read aloud: what was written, what it became, then when and where.
    static func spoken(_ entry: MemoryEntry, detail: String) -> String {
        "Hushy wrote: \(entry.before ?? ""). You changed it to: \(entry.after ?? ""). \(detail)"
    }

    /// What to say when a change was not made as asked. Nil when there is nothing to say.
    static func message(for result: MemoryWrite, value: String) -> String? {
        switch result {
        case .written, .merged, .empty, .missing: nil
        case .forgotten: "“\(value)” is under Forgotten. Restore it there to use it again."
        case .full: "The notes for every app are at their limit of 1,500 characters. Shorten one to add more."
        }
    }
}
