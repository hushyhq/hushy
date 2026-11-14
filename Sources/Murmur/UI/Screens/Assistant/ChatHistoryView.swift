import MurmurCore
import SwiftUI

/// The Assistant's chat history, VS Code style: a search field, then saved chats grouped
/// Today / Yesterday / Previous 7 days / Older. Click to open, pencil to rename, trash to delete.
/// Shown in a popover from the header's clock button (and rendered flat for snapshots).
struct ChatHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    var onOpen: () -> Void = {}
    /// Snapshot rendering passes fixture chats instead of reading the database.
    var fixture: [AssistantChat]?

    @State private var renamingID: Int64?
    @State private var renameText = ""
    @State private var confirmDeleteID: Int64?

    var body: some View {
        @Bindable var assistant = model.assistant
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                if isSnapshot {
                    Text("Search chats").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                } else {
                    TextField("Search chats", text: $assistant.historyQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
            .padding(Theme.Space.m)

            Rectangle().fill(Theme.hairline).frame(height: 0.5)

            let chats = fixture ?? assistant.history
            if chats.isEmpty {
                Text(assistant.historyQuery.isEmpty ? "No saved chats yet." : "No chats match “\(assistant.historyQuery)”.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollingIfLive {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(AssistantHistoryGroup.grouped(chats), id: \.group) { section in
                            Text(section.group.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .textCase(.uppercase)
                                .padding(.horizontal, Theme.Space.m)
                                .padding(.top, Theme.Space.s)
                                .padding(.bottom, 2)
                            ForEach(section.chats) { chat in row(chat) }
                        }
                    }
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.bottom, Theme.Space.s)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 300)
        .background(Theme.bgBase)
        .onAppear { if fixture == nil { assistant.reloadHistory() } }
        .confirmationDialog("Delete this chat?", isPresented: Binding(
            get: { confirmDeleteID != nil }, set: { if !$0 { confirmDeleteID = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteID { assistant.deleteChat(id) }
                confirmDeleteID = nil
            }
        } message: {
            Text("Removes it from Hushy. Claude Code may keep its own copy of the session in its history.")
        }
    }

    @ViewBuilder
    private func row(_ chat: AssistantChat) -> some View {
        if let id = chat.id, renamingID == id {
            TextField("Chat name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit {
                    model.assistant.renameChat(id, to: renameText)
                    renamingID = nil
                }
                .onExitCommand { renamingID = nil }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 3)
        } else {
            HistoryRow(
                chat: chat, isCurrent: chat.id != nil && chat.id == model.assistant.currentChatID,
                open: {
                    if let id = chat.id { model.assistant.openChat(id) }
                    onOpen()
                },
                rename: {
                    renameText = chat.title
                    renamingID = chat.id
                },
                delete: { confirmDeleteID = chat.id })
        }
    }
}

private struct HistoryRow: View {
    let chat: AssistantChat
    let isCurrent: Bool
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(isCurrent ? Theme.phosphor : Theme.textTertiary)
            Text(chat.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if hovering {
                IconButton(symbol: "pencil", help: "Rename", action: rename)
                IconButton(symbol: "trash", help: "Delete", action: delete)
            } else {
                Text(chat.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering || isCurrent ? Theme.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button("Rename…", action: rename)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chat.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Rename", rename)
        .accessibilityAction(named: "Delete", delete)
    }
}
