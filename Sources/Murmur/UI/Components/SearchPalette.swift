import MurmurCore
import SwiftUI

/// ⌘K command palette: searches dictations and notes together via the existing FTS
/// (`Store.searchDictations`/`searchNotes`), Esc closes, Enter opens the highlighted result.
/// While the app lock is on it shows one line and Unlock instead, and searches nothing.
/// A sheet rather than a separate window keeps it simple and modal, matching the mockup's
/// overlay behavior without adding new window plumbing.
struct SearchPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.snapshotAppLocked) private var snapshotAppLocked
    @State private var query = ""
    @State private var dictationResults: [Dictation] = []
    @State private var noteResults: [Note] = []
    @State private var selection = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var rows: [SearchRow] {
        dictationResults.map(SearchRow.dictation) + noteResults.map(SearchRow.note)
    }

    /// The app lock is on. The palette is reachable from every section, so it hides its own
    /// content: no field, no search, no results (`SearchPaletteState`).
    private var isLocked: Bool { snapshotAppLocked || model.appLock.isLocked }

    var body: some View {
        VStack(spacing: 0) {
            if isLocked {
                LockedContentNotice(message: LockedCopy.search)
            } else {
                searchField
                Divider().overlay(Theme.hairline)
                results
            }
        }
        .frame(width: 560)
        .background(Theme.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet))
        .onAppear { focused = true }
        .onChange(of: query) { _, newValue in debounceSearch(newValue) }
        // Locking with the palette open drops what it had found and typed.
        .onChange(of: isLocked) { _, locked in
            if locked { clear() } else { focused = true }
        }
        .background(paletteShortcuts)
    }

    private func clear() {
        searchTask?.cancel()
        query = ""
        dictationResults = []
        noteResults = []
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
            TextField(FeatureFlags.meetings ? "Search dictations and notes" : "Search dictations", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit(openSelection)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.l)
    }

    @ViewBuilder
    private var results: some View {
        switch SearchPaletteState.make(isLocked: isLocked, query: query, resultCount: rows.count) {
        case .locked:
            EmptyView()
        case .prompt:
            EmptyState(symbol: "magnifyingglass", title: "Search everything",
                       message: FeatureFlags.meetings
                           ? "Find anything you've dictated or any note you've recorded."
                           : "Find anything you've dictated.")
                .padding(.vertical, Theme.Space.xxl)
        case .noMatches:
            EmptyState(symbol: "magnifyingglass", title: "No matches",
                       message: FeatureFlags.meetings
                           ? "Nothing you've dictated or recorded matches “\(query)”."
                           : "Nothing you've dictated matches “\(query)”.")
                .padding(.vertical, Theme.Space.xxl)
        case .results:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        SearchResultRow(row: row, isSelected: index == selection) {
                            selection = index
                            openSelection()
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private var paletteShortcuts: some View {
        Group {
            Button("") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            Button("") { moveSelection(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { moveSelection(-1) }.keyboardShortcut(.upArrow, modifiers: [])
        }
        .hidden()
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = max(0, min(rows.count - 1, selection + delta))
    }

    private func openSelection() {
        guard !isLocked, rows.indices.contains(selection) else { return }
        switch rows[selection] {
        case .dictation:
            model.section = .history
        case .note(let note):
            model.section = .notes
            model.selectedNoteID = note.id
        }
        dismiss()
    }

    private func debounceSearch(_ text: String) {
        searchTask?.cancel()
        guard let trimmed = SearchPaletteState.queryToRun(isLocked: isLocked, query: text) else {
            dictationResults = []
            noteResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            // The lock can come on during the pause; nothing is read once it has.
            guard !Task.isCancelled, !isLocked else { return }
            let dictations = (try? model.store.searchDictations(trimmed, limit: 8)) ?? []
            let notes = FeatureFlags.meetings
                ? (try? model.store.searchNotes(trimmed, limit: 8)) ?? []
                : []
            guard !Task.isCancelled else { return }
            dictationResults = dictations
            noteResults = notes
            selection = 0
        }
    }
}

/// What the palette shows, and whether it may search. Locked comes first: while the app lock is
/// on there are no results to show and no search is run, whatever was typed. Pure
/// (`AppLockSurfaceTests`).
enum SearchPaletteState: Equatable {
    case locked, prompt, noMatches, results

    static func make(isLocked: Bool, query: String, resultCount: Int) -> SearchPaletteState {
        if isLocked { return .locked }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return .prompt }
        return resultCount == 0 ? .noMatches : .results
    }

    /// The words to search for, or nil when no search should run (locked, or nothing typed).
    static func queryToRun(isLocked: Bool, query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return isLocked || trimmed.isEmpty ? nil : trimmed
    }
}

private enum SearchRow {
    case dictation(Dictation)
    case note(Note)
}

private struct SearchResultRow: View {
    let row: SearchRow
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s + 2)
            .background(isSelected ? Theme.phosphorTint : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch row {
        case .dictation: "text.bubble"
        case .note: "waveform.badge.mic"
        }
    }

    private var title: String {
        switch row {
        case .dictation(let item): item.text.isEmpty ? item.rawText : item.text
        case .note(let note): note.title
        }
    }

    private var subtitle: String {
        switch row {
        case .dictation(let item):
            let app = item.appName ?? "Dictation"
            return "\(app) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
        case .note(let note):
            return "Note · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}
