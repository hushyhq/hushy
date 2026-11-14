import MurmurCore
import SwiftUI

/// Snapshot-only: a snippet half written in the composer.
struct SnippetSnapshot: Equatable {
    var trigger = ""
    var expansion = ""
    var showsEmpty = false
}

extension EnvironmentValues {
    @Entry var snapshotSnippet: SnippetSnapshot?
}

/// Snippets tab of Voice & style: a composer that reads as the sentence it makes ("When I say … insert …"), a few
/// starting points, and the saved snippets as spoken phrase → text.
struct SnippetsTabContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotSnippet) private var snapshot
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var placeholder = VoiceStyleCopy.insertPlaceholder
    @State private var error: String?

    private var snippets: [Snippet] { snapshot?.showsEmpty == true ? [] : model.library.snippets }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SnippetComposer(
                trigger: $trigger, expansion: $expansion, placeholder: placeholder, error: error,
                snapshot: snapshot, save: add,
                start: { trigger, placeholder in
                    self.trigger = trigger
                    self.expansion = ""
                    self.placeholder = placeholder
                })

            if snippets.isEmpty {
                Label(VoiceStyleCopy.snippetsEmpty, systemImage: "text.bubble")
                    .labelStyle(FootnoteLabelStyle())
                    .padding(.leading, Theme.Space.xs)
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
                            if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.Space.l) }
                            SnippetRow(snippet: snippet) {
                                if let id = snippet.id { try? model.store.deleteSnippet(id: id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        do {
            try model.store.save(Snippet(trigger: trigger.trimmingCharacters(in: .whitespaces), expansion: expansion))
            trigger = ""
            expansion = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SnippetComposer: View {
    @Binding var trigger: String
    @Binding var expansion: String
    let placeholder: String
    let error: String?
    let snapshot: SnippetSnapshot?
    let save: () -> Void
    let start: (_ trigger: String, _ placeholder: String) -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var scheme

    private var shownTrigger: String { snapshot?.trigger ?? trigger }
    private var shownExpansion: String { snapshot?.expansion ?? expansion }

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    half(VoiceStyleCopy.whenISay, symbol: "waveform") { triggerField }
                        .frame(maxWidth: 220)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        .padding(.top, 30)
                        .accessibilityHidden(true)
                    half(VoiceStyleCopy.insert, symbol: "text.cursor") { expansionField }
                }
                .padding(Theme.Space.l)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                footer.padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
            }
        }
    }

    private func half<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).labelStyle(FootnoteLabelStyle())
            content()
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well(scheme)))
        }
    }

    @ViewBuilder private var triggerField: some View {
        if isSnapshot {
            SnapshotTextField(shownTrigger, placeholder: VoiceStyleCopy.triggerPlaceholder,
                              font: .system(size: 14, design: .serif).italic())
        } else {
            TextField(VoiceStyleCopy.triggerPlaceholder, text: $trigger)
                .textFieldStyle(.plain).font(.system(size: 14, design: .serif).italic())
                .accessibilityLabel(VoiceStyleCopy.whenISay)
        }
    }

    @ViewBuilder private var expansionField: some View {
        if isSnapshot {
            Text(shownExpansion.isEmpty ? placeholder : shownExpansion)
                .font(Theme.Font.body)
                .foregroundStyle(shownExpansion.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        } else {
            TextEditor(text: $expansion)
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .frame(height: 44)
                .overlay(alignment: .topLeading) {
                    if expansion.isEmpty {
                        Text(placeholder).font(Theme.Font.body).foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(VoiceStyleCopy.insert)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if let error {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.error).lineLimit(1)
            } else {
                Text(VoiceStyleCopy.tryLabel).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                SnippetStarters(pick: start)
            }
            Spacer(minLength: Theme.Space.s)
            Text("\(shownExpansion.count)/\(Snippet.maxExpansionLength)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                .opacity(shownExpansion.isEmpty ? 0 : 1)
            Button(VoiceStyleCopy.saveSnippet, action: save)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(shownTrigger.trimmingCharacters(in: .whitespaces).isEmpty || shownExpansion.isEmpty)
        }
    }
}

/// One-click starting points for the snippets people actually use: small glyph chips.
private struct SnippetStarters: View {
    let pick: (_ trigger: String, _ placeholder: String) -> Void

    private let starters: [(symbol: String, trigger: String, placeholder: String)] = [
        ("link", "my LinkedIn", "https://www.linkedin.com/in/your-profile"),
        ("envelope", "my email", "you@example.com"),
        ("calendar", "my calendar link", "https://cal.com/your-name"),
        ("signature", "my signature", "Best,\nYour Name"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(starters, id: \.trigger) { starter in
                StarterChip(symbol: starter.symbol, title: starter.trigger) { pick(starter.trigger, starter.placeholder) }
            }
        }
    }
}

private struct StarterChip: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.phosphor : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Theme.phosphorTint : Theme.bgSunken))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .help("“\(title)”")
        .accessibilityLabel("Start from “\(title)”")
    }
}

/// A saved snippet: the phrase as said, then the text it becomes. Delete under the pointer and in the context menu.
private struct SnippetRow: View {
    let snippet: Snippet
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("“\(snippet.trigger)”")
                .font(.system(size: 13.5, design: .serif)).italic()
                .foregroundStyle(Theme.phosphor)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(snippet.expansion)
                .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "trash", help: "Delete snippet", tint: Theme.textTertiary, action: onDelete)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
        .background(hovering ? Theme.selection.opacity(0.45) : .clear)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .contextMenu { Button("Delete", role: .destructive, action: onDelete) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Delete", onDelete)
    }
}
