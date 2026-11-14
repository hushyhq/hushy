import MurmurCore
import SwiftUI

/// One remembered word or note with its actions. A word and a forgotten word are a settings
/// row; a writing note is its text in the body face, since it is a sentence and not a name.
/// (An edit has its own row, `MemoryPairRow`.)
struct MemoryEntryRow: View {
    let entry: MemoryEntry
    let detail: String
    let isLast: Bool
    var opensLongNote = false
    let actions: MemoryPaneActions

    var body: some View {
        if entry.kind == .profile || entry.kind == .style {
            MemoryNoteRow(text: entry.value, detail: detail, isLast: isLast, opensLongNote: opensLongNote) { controls }
        } else {
            SettingsRow(title: MemoryPaneCopy.title(entry), detail: detail, showsDivider: !isLast) { controls }
        }
    }

    @ViewBuilder
    private var controls: some View {
        let name = MemoryPaneCopy.title(entry)
        if entry.kind == .forgotten {
            // The person's own way back: nothing else takes a word out of Forgotten.
            UndoLink(title: "Restore", accessibilityText: "Restore \(name)") { actions.restore(entry) }
                .help("Let Hushy use this word again")
        } else {
            HStack(spacing: Theme.Space.m) {
                Button("Edit") { actions.edit(entry) }.buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Edit \(name)")
                // A quiet link, not a second capsule, as in "Learned from your edits".
                UndoLink(title: entry.kind == .term ? "Forget" : "Delete",
                         accessibilityText: "\(entry.kind == .term ? "Forget" : "Delete") \(name)") {
                    actions.remove(entry)
                }
                .help(entry.kind == .term ? "Remove this word and never learn it again" : "Remove this from memory")
            }
            .fixedSize()
        }
    }
}

/// A writing note: up to three lines of it, with "Show all" when there is more. Same insets and
/// hairline as `SettingsRow`.
private struct MemoryNoteRow<Controls: View>: View {
    let text: String
    let detail: String
    let isLast: Bool
    @ViewBuilder var controls: Controls
    @State private var isOpen: Bool

    /// About three lines at this width; a shorter note never needs the link.
    private static var longNote: Int { 150 }
    private static var closedLines: Int { 3 }

    init(text: String, detail: String, isLast: Bool, opensLongNote: Bool, @ViewBuilder controls: () -> Controls) {
        self.text = text
        self.detail = detail
        self.isLast = isLast
        self.controls = controls()
        _isOpen = State(initialValue: opensLongNote)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(text).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                    .lineLimit(isOpen ? nil : Self.closedLines)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    if text.count > Self.longNote {
                        Text("·").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                        UndoLink(title: isOpen ? "Show less" : "Show all",
                                 accessibilityText: isOpen ? "Show less of this note" : "Show all of this note") {
                            isOpen.toggle()
                        }
                    }
                }
            }
            Spacer(minLength: Theme.Space.l)
            controls
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.Space.l) }
        }
    }
}
