import MurmurCore
import SwiftUI

/// "Your edits": what Hushy wrote and what the person changed it to, newest first. The list can
/// run to hundreds, so it opens on the newest few and the rest are built only as they scroll
/// into view.
struct MemoryEditsGroup: View {
    let edits: [MemoryEntry]
    let appName: (String) -> String
    let actions: MemoryPaneActions
    @State private var isOpen: Bool

    /// How many show before "Show all".
    static let closedCount = 5

    init(edits: [MemoryEntry], appName: @escaping (String) -> String, opensAll: Bool, actions: MemoryPaneActions) {
        self.edits = edits
        self.appName = appName
        self.actions = actions
        _isOpen = State(initialValue: opensAll)
    }

    var body: some View {
        let shown = MemoryPaneCopy.shownEdits(edits, isOpen: isOpen)
        SettingsGroup(title: "Your edits") {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { entry in
                    MemoryPairRow(entry: entry, detail: MemoryPaneCopy.detail(entry, appName: appName),
                                  isLast: entry.id == shown.last?.id && edits.count <= Self.closedCount, actions: actions)
                }
            }
            if edits.count > Self.closedCount { more(shown: shown.count) }
        }
    }

    /// "5 of 300 shown" and the way to the rest, or back.
    private func more(shown: Int) -> some View {
        HStack(spacing: 6) {
            Text(MemoryPaneCopy.editCount(shown: shown, of: edits.count))
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.l)
            UndoLink(title: isOpen ? "Show fewer" : "Show all \(edits.count)",
                     accessibilityText: isOpen ? "Show only the newest edits" : "Show all \(edits.count) edits") {
                isOpen.toggle()
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }
}

/// One edit: what Hushy wrote above what the person made of it, the changed words marked on
/// both lines so the difference shows without reading either line through.
struct MemoryPairRow: View {
    let entry: MemoryEntry
    let detail: String
    let isLast: Bool
    let actions: MemoryPaneActions

    var body: some View {
        let words = EditPair(before: entry.before ?? "", after: entry.after ?? "").words
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.line(words.before, isBefore: true)).foregroundStyle(Theme.textSecondary)
                Text(Self.line(words.after, isBefore: false)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(.top, 1)
            }
            .font(Theme.Font.body)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MemoryPaneCopy.spoken(entry, detail: detail))
            Spacer(minLength: Theme.Space.l)
            UndoLink(title: "Delete", accessibilityText: "Delete the edit \(MemoryPaneCopy.title(entry))") { actions.remove(entry) }
                .help("Remove this from memory")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.Space.l) }
        }
    }

    /// Hushy's words that went are struck through; the person's words that came are heavier.
    static func line(_ words: [EditPair.Word], isBefore: Bool) -> AttributedString {
        var line = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString(word.text)
            // The stroke is a step quieter than the letters, so the struck words still read.
            if word.isChanged, isBefore { part.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.textTertiary) }
            if word.isChanged, !isBefore { part.swiftUI.font = Theme.Font.body.weight(.semibold) }
            line += part
            if index < words.count - 1 { line += AttributedString(" ") }
        }
        return line
    }
}
