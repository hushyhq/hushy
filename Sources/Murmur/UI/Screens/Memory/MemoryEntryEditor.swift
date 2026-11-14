import MurmurCore
import SwiftUI

/// The sheet behind a row's Edit: holds the draft, and hands it back on Save.
struct MemoryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: MemoryEntry
    let save: (MemoryEntry) -> Void

    var body: some View {
        MemoryEntryEditorContent(entry: $entry, cancel: { dismiss() }, save: { save(entry); dismiss() })
    }
}

/// What the edit sheet draws: a word with how it was heard, a writing note, or an edit's two sides.
struct MemoryEntryEditorContent: View {
    @Binding var entry: MemoryEntry
    var cancel: () -> Void = {}
    var save: () -> Void = {}
    @Environment(\.isSnapshot) private var isSnapshot

    static let width: CGFloat = 440
    private static let noteHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: Theme.Space.m) { fields }
            HStack(spacing: Theme.Space.s) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(isBlank)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: Self.width)
        .background(Theme.bgBase)
    }

    private var title: String {
        switch entry.kind {
        case .term, .forgotten: "Edit word"
        case .profile, .style: "Edit note"
        case .correction: "Edit change"
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch entry.kind {
        case .term, .forgotten:
            line("Word", text: $entry.value)
            line("Heard as (separate with commas)", text: Binding(
                get: { entry.heardAs.joined(separator: ", ") },
                set: { entry.heardAs = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
        case .profile, .style:
            note("How you write", text: $entry.value)
        case .correction:
            line("What Hushy wrote", text: Binding(get: { entry.before ?? "" }, set: { entry.before = $0 }))
            line("What you changed it to", text: Binding(get: { entry.after ?? "" }, set: { entry.after = $0 }))
        }
    }

    private var isBlank: Bool {
        let text = entry.kind == .correction ? (entry.after ?? "") : entry.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func line(_ label: String, text: Binding<String>) -> some View {
        field(label) {
            // `ImageRenderer` can't draw a text field; snapshots show its text in the same box.
            if isSnapshot {
                SnapshotTextField(text.wrappedValue, placeholder: " ")
            } else {
                TextField(label, text: text).textFieldStyle(.plain).font(Theme.Font.body).labelsHidden()
            }
        }
    }

    /// Several lines: a note can run to a paragraph.
    private func note(_ label: String, text: Binding<String>) -> some View {
        field(label) {
            // The box does not grow with the text: a long note scrolls, and a snapshot shows its top.
            if isSnapshot {
                Text(text.wrappedValue).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: Self.noteHeight, alignment: .top).clipped()
            } else {
                TextEditor(text: text).font(Theme.Font.body).scrollContentBackground(.hidden)
                    .frame(height: Self.noteHeight)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            content()
                .padding(Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
        }
    }
}
