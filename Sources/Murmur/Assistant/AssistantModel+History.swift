import Foundation
import MurmurCore

/// Saved chats: creating one on the first message, writing each finished message, and the
/// history list (open, rename, delete, clear all). Every write is best-effort: a database
/// error is logged and the chat keeps working in memory.
extension AssistantModel {
    /// Creates the saved chat for a new conversation, titled from its first message.
    func ensureChat(firstMessage: String) {
        guard currentChatID == nil, let store else { return }
        do {
            let chat = try store.createAssistantChat(AssistantChat(
                title: AssistantChat.title(fromFirstMessage: firstMessage), agent: .claude,
                model: settings.assistantModel.rawValue))
            currentChatID = chat.id
            currentChatTitle = chat.title
            // A temporary workspace from an unsaved start is replaced by the chat's stable one.
            workspace?.remove()
            workspace = nil
        } catch {
            log.error("couldn't save a new chat: \(error.localizedDescription)")
        }
    }

    /// Writes `message` (insert or update) and returns its row id. Best-effort: a database error
    /// is logged and the chat keeps working in memory.
    @discardableResult
    func persist(_ message: Message) -> Int64? {
        guard store != nil, currentChatID != nil else { return message.storedID }
        do {
            return try persistThrowing(message)
        } catch {
            log.error("couldn't save a chat message: \(error.localizedDescription)")
            return message.storedID
        }
    }

    /// There is no saved chat to write to (no store, or the chat was never created).
    struct NoSavedChat: Error {}

    /// The same write, but the caller learns whether it landed. Used before an action runs: the
    /// "started" mark must be on disk first, or the action does not run. With no store or no
    /// saved chat there is nowhere to put the mark, which counts as a failed write.
    func persistThrowing(_ message: Message) throws -> Int64? {
        guard let store, let chatID = currentChatID else { throw NoSavedChat() }
        var row = AssistantMessage(
            id: message.storedID, chatId: chatID, role: message.role.stored, text: message.text,
            activity: message.toolSummary, errorText: message.errorText, actions: message.actions)
        if let writeMessage { return try writeMessage(row) }
        if row.id == nil {
            row = try store.appendAssistantMessage(row)
        } else {
            try store.updateAssistantMessage(row)
        }
        return row.id
    }

    /// Remembers which agent session the chat continues with (and the model it used).
    func saveSession() {
        guard let store, let chatID = currentChatID else { return }
        do {
            try store.setAssistantChatSession(id: chatID, sessionID: sessionID, model: settings.assistantModel.rawValue)
        } catch {
            log.error("couldn't save the chat session: \(error.localizedDescription)")
        }
    }

    func reloadHistory() {
        guard let store else { return }
        do {
            history = try store.assistantChats(matching: historyQuery)
        } catch {
            log.error("couldn't load chat history: \(error.localizedDescription)")
        }
    }

    /// Opens a saved chat: its messages on screen, and the next message continues its agent
    /// session with `--resume`.
    func openChat(_ id: Int64) {
        guard let store, id != currentChatID || messages.isEmpty else { return }
        do {
            guard let chat = try store.assistantChat(id: id) else { return }
            let rows = try store.assistantMessages(chatId: id)
            newConversation()
            currentChatID = id
            currentChatTitle = chat.title
            sessionID = chat.agentSessionId
            replaceMessages(rows.map { row in
                Message(
                    storedID: row.id, role: .init(row.role), text: row.text, toolSummary: row.activity,
                    errorText: row.errorText, actions: row.actions)
            })
        } catch {
            log.error("couldn't open a saved chat: \(error.localizedDescription)")
        }
    }

    func renameChat(_ id: Int64, to title: String) {
        guard let store else { return }
        do {
            try store.renameAssistantChat(id: id, to: title)
            if id == currentChatID { currentChatTitle = try store.assistantChat(id: id)?.title }
            reloadHistory()
        } catch {
            log.error("couldn't rename a chat: \(error.localizedDescription)")
        }
    }

    /// Deletes a chat, its messages and its workspace folder.
    func deleteChat(_ id: Int64) {
        guard let store else { return }
        if id == currentChatID { newConversation() }
        do {
            try store.deleteAssistantChat(id: id)
        } catch {
            log.error("couldn't delete a chat: \(error.localizedDescription)")
        }
        AgentWorkspace.forChat(id: id, base: workspaceBase).remove()
        reloadHistory()
    }

    /// Settings → Privacy & security → "Clear all chats".
    func clearAllChats() {
        newConversation()
        guard let store else { return }
        do {
            for id in try store.deleteAllAssistantChats() {
                AgentWorkspace.forChat(id: id, base: workspaceBase).remove()
            }
        } catch {
            log.error("couldn't clear chats: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: workspaceBase.appendingPathComponent("Assistant", isDirectory: true))
        reloadHistory()
    }

    /// The number of saved chats (Settings shows it next to "Clear all chats").
    var savedChatCount: Int {
        (try? store?.assistantChats(limit: 10_000).count) ?? 0
    }
}
