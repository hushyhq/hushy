import Foundation
import GRDB

/// One saved Assistant conversation (migration "v12-assistant-chats"). Its messages live in
/// `assistant_message`; `agentSessionId` is the agent CLI's own session id, passed back as
/// `--resume` when the chat is continued.
///
/// Stored like dictation text: plain rows in Hushy's local SQLite (protected by FileVault and
/// `PRAGMA secure_delete`, not by Hushy's own encryption, which covers audio files only; see
/// `.claude/DECISIONS.md`). Nothing here ever leaves the Mac by itself.
public struct AssistantChat: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Agent: String, Codable, Sendable {
        case claude, codex
    }

    public var id: Int64?
    public var title: String
    public var agent: Agent
    /// The model alias the chat last used (`haiku`, `sonnet`).
    public var model: String
    public var agentSessionId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, title: String, agent: Agent = .claude, model: String = AssistantModelChoice.haiku.rawValue,
        agentSessionId: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.model = model
        self.agentSessionId = agentSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Longest title kept, whether derived or typed by the user.
    public static let maxTitleLength = 80
    /// Derived titles are shorter, so they fit the history list on one line.
    public static let derivedTitleLength = 48

    /// A title from the chat's first message: one line, whitespace collapsed, cut at a word
    /// boundary with an ellipsis when it's long.
    public static func title(fromFirstMessage text: String, limit: Int = derivedTitleLength) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "New chat" }
        guard collapsed.count > limit else { return collapsed }
        let clipped = String(collapsed.prefix(limit))
        let cut = clipped.lastIndex(of: " ").map { String(clipped[..<$0]) } ?? clipped
        return (cut.count >= limit / 2 ? cut : clipped).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

/// One message in a saved chat.
public struct AssistantMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
        /// A quiet line from Hushy itself ("Started a new session…"), not from either side.
        case notice
    }

    public var id: Int64?
    public var chatId: Int64
    public var role: Role
    public var text: String
    /// What the agent looked up, e.g. "Searched your history · Read a note".
    public var activity: String?
    /// The error shown under an answer that failed, in the words the user saw.
    public var errorText: String?
    /// Proposed actions on this reply and what became of them, as JSON (`[ChatActionEntry]`).
    public var actionsJSON: String?
    public var createdAt: Date

    public init(
        id: Int64? = nil, chatId: Int64, role: Role, text: String, activity: String? = nil,
        errorText: String? = nil, actions: [ChatActionEntry] = [], createdAt: Date = Date()
    ) {
        self.id = id
        self.chatId = chatId
        self.role = role
        self.text = text
        self.activity = activity
        self.errorText = errorText
        self.createdAt = createdAt
        self.actions = actions
    }

    /// The decoded `actionsJSON`; empty when there are none or the JSON is unreadable.
    public var actions: [ChatActionEntry] {
        get {
            guard let data = actionsJSON?.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ChatActionEntry].self, from: data)) ?? []
        }
        set {
            actionsJSON = newValue.isEmpty
                ? nil
                : (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}

/// A proposed action shown in a chat and where it got to. `recordID` links to the
/// `ActionRecord` once it was executed, for Undo.
public struct ChatActionEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending, added, cancelled, failed, undone
        /// It may have happened and Hushy can't tell (a Shortcut that timed out). No Retry.
        case uncertain
        /// Refused for something missing or not found. No Retry: it would fail the same way.
        case blocked
    }

    public var action: ProposedAction
    public var status: Status
    public var recordID: Int64?
    public var failure: String?

    public var id: UUID { action.id }

    public init(action: ProposedAction, status: Status = .pending, recordID: Int64? = nil, failure: String? = nil) {
        self.action = action
        self.status = status
        self.recordID = recordID
        self.failure = failure
    }
}

extension AssistantChat: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "assistant_chat"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension AssistantMessage: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "assistant_message"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, chatId, role, text, activity, errorText, actionsJSON, createdAt
    }
}

extension AssistantChat.Agent: DatabaseValueConvertible {}
extension AssistantMessage.Role: DatabaseValueConvertible {}

// MARK: - Schema

enum AssistantChatSchema {
    /// "v12-assistant-chats": add-only. Messages cascade with their chat.
    static func migrate(_ db: Database) throws {
        try db.create(table: "assistant_chat") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull()
            t.column("agent", .text).notNull()
            t.column("model", .text).notNull()
            t.column("agentSessionId", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull().indexed()
        }
        try db.create(table: "assistant_message") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("chatId", .integer).notNull().indexed()
                .references("assistant_chat", onDelete: .cascade)
            t.column("role", .text).notNull()
            t.column("text", .text).notNull()
            t.column("activity", .text)
            t.column("errorText", .text)
            t.column("actionsJSON", .text)
            t.column("createdAt", .datetime).notNull()
        }
    }
}

// MARK: - Store CRUD

extension Store {
    /// Saves a new chat and returns it with its id.
    @discardableResult
    public func createAssistantChat(_ chat: AssistantChat) throws -> AssistantChat {
        try writer.write { db in
            var copy = chat
            copy.title = Self.cleanChatTitle(copy.title) ?? "New chat"
            try copy.insert(db)
            return copy
        }
    }

    public func assistantChat(id: Int64) throws -> AssistantChat? {
        try writer.read { db in try AssistantChat.fetchOne(db, key: id) }
    }

    /// Chats, most recently active first. `query` matches the title or any message's text.
    public func assistantChats(matching query: String? = nil, limit: Int = 500) throws -> [AssistantChat] {
        try writer.read { db in
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let order = "ORDER BY updatedAt DESC, id DESC LIMIT ?"
            guard !trimmed.isEmpty else {
                return try AssistantChat.fetchAll(db, sql: "SELECT * FROM assistant_chat \(order)", arguments: [limit])
            }
            let pattern = "%" + trimmed.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            return try AssistantChat.fetchAll(db, sql: """
                SELECT * FROM assistant_chat
                WHERE title LIKE ? ESCAPE '\\'
                   OR id IN (SELECT chatId FROM assistant_message WHERE text LIKE ? ESCAPE '\\')
                \(order)
                """, arguments: [pattern, pattern, limit])
        }
    }

    /// A chat's messages in the order they were said.
    public func assistantMessages(chatId: Int64) throws -> [AssistantMessage] {
        try writer.read { db in
            try AssistantMessage.fetchAll(
                db, sql: "SELECT * FROM assistant_message WHERE chatId = ? ORDER BY createdAt, id", arguments: [chatId])
        }
    }

    /// Appends a message and marks the chat as just active.
    @discardableResult
    public func appendAssistantMessage(_ message: AssistantMessage) throws -> AssistantMessage {
        try writer.write { db in
            var copy = message
            try copy.insert(db)
            try db.execute(
                sql: "UPDATE assistant_chat SET updatedAt = ? WHERE id = ?", arguments: [copy.createdAt, copy.chatId])
            return copy
        }
    }

    /// Rewrites a saved message (an answer finishing, an action's status changing).
    public func updateAssistantMessage(_ message: AssistantMessage) throws {
        try writer.write { db in try message.update(db) }
    }

    /// Renames a chat; a blank title is ignored.
    public func renameAssistantChat(id: Int64, to title: String) throws {
        guard let clean = Self.cleanChatTitle(title) else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE assistant_chat SET title = ? WHERE id = ?", arguments: [clean, id])
        }
    }

    /// Records the agent session a chat continues with, and the model it used.
    public func setAssistantChatSession(id: Int64, sessionID: String?, model: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE assistant_chat SET agentSessionId = ?, model = ? WHERE id = ?",
                arguments: [sessionID, model, id])
        }
    }

    public func deleteAssistantChat(id: Int64) throws {
        discardPreMeetingsBackup()
        _ = try writer.write { db in try AssistantChat.deleteOne(db, key: id) }
    }

    /// "Clear all chats" (Settings → Privacy & security). Returns the ids that were removed, so
    /// the caller can delete their workspaces.
    @discardableResult
    public func deleteAllAssistantChats() throws -> [Int64] {
        discardPreMeetingsBackup()
        return try writer.write { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM assistant_chat")
            try db.execute(sql: "DELETE FROM assistant_message")
            try db.execute(sql: "DELETE FROM assistant_chat")
            return ids
        }
    }

    static func cleanChatTitle(_ title: String) -> String? {
        let collapsed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(AssistantChat.maxTitleLength))
    }
}
