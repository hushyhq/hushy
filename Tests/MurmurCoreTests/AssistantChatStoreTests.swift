import Foundation
import GRDB
import Testing
@testable import MurmurCore

@Suite("Assistant chat store")
struct AssistantChatStoreTests {
    @Test("migration v12 appends after v11 and creates both tables")
    func migration() throws {
        let store = try Store()
        let applied = try store.writer.read { db in try Store.migrator.appliedIdentifiers(db) }
        #expect(applied.contains("v12-assistant-chats"))
        let ids = Store.migrator.migrations
        // v13-entitlements (pricing) was appended after this; v12 must still follow v11.
        #expect(ids.firstIndex(of: "v11-voices")! < ids.firstIndex(of: "v12-assistant-chats")!)
        #expect(ids.firstIndex(of: "v12-assistant-chats")! < ids.firstIndex(of: "v13-entitlements")!)
        let tables = try store.writer.read { db in
            (try db.tableExists("assistant_chat"), try db.tableExists("assistant_message"))
        }
        #expect(tables == (true, true))
    }

    @Test("create, append, read back in order, update, rename, session")
    func crud() throws {
        let store = try Store()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let chat = try store.createAssistantChat(AssistantChat(title: "  What did   I say\nabout the deck? ", createdAt: t0))
        let id = try #require(chat.id)
        #expect(chat.title == "What did I say about the deck?")

        let question = try store.appendAssistantMessage(AssistantMessage(chatId: id, role: .user, text: "Q", createdAt: t0.addingTimeInterval(1)))
        let entry = ChatActionEntry(action: ProposedAction(kind: .createReminder, title: "Send deck", sourceText: "Q"))
        var answer = try store.appendAssistantMessage(AssistantMessage(
            chatId: id, role: .assistant, text: "A", activity: "Searched your history", actions: [entry],
            createdAt: t0.addingTimeInterval(2)))
        answer.actions = [ChatActionEntry(action: entry.action, status: .added, recordID: 7)]
        answer.errorText = nil
        try store.updateAssistantMessage(answer)

        let messages = try store.assistantMessages(chatId: id)
        #expect(messages.map(\.text) == ["Q", "A"])
        #expect(messages.first?.id == question.id)
        #expect(messages.last?.activity == "Searched your history")
        #expect(messages.last?.actions.first?.status == .added)
        #expect(messages.last?.actions.first?.recordID == 7)
        #expect(messages.last?.actions.first?.action.title == "Send deck")
        // Appending bumped the chat's activity time.
        #expect(try store.assistantChat(id: id)?.updatedAt == t0.addingTimeInterval(2))

        try store.renameAssistantChat(id: id, to: "Deck")
        try store.renameAssistantChat(id: id, to: "   ")
        try store.setAssistantChatSession(id: id, sessionID: "sess-1", model: "sonnet")
        let reloaded = try #require(try store.assistantChat(id: id))
        #expect(reloaded.title == "Deck")
        #expect(reloaded.agentSessionId == "sess-1")
        #expect(reloaded.model == "sonnet")
    }

    @Test("history is newest activity first, and search matches titles and message text")
    func orderingAndSearch() throws {
        let store = try Store()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let old = try #require(try store.createAssistantChat(AssistantChat(title: "Pricing call", createdAt: base)).id)
        let newer = try #require(try store.createAssistantChat(AssistantChat(title: "Standup", createdAt: base.addingTimeInterval(60))).id)
        let newest = try #require(try store.createAssistantChat(AssistantChat(title: "Deck", createdAt: base.addingTimeInterval(120))).id)
        #expect(try store.assistantChats().map(\.id) == [newest, newer, old])
        // New activity on the oldest chat moves it to the top.
        try store.appendAssistantMessage(AssistantMessage(chatId: old, role: .user, text: "remind me about 50% off_", createdAt: base.addingTimeInterval(500)))
        #expect(try store.assistantChats().map(\.id) == [old, newest, newer])

        #expect(try store.assistantChats(matching: "stand").map(\.id) == [newer])
        #expect(try store.assistantChats(matching: "50% off_").map(\.id) == [old])
        #expect(try store.assistantChats(matching: "%").map(\.id) == [old], "LIKE wildcards are escaped")
        #expect(try store.assistantChats(matching: "nothing like this").isEmpty)
        #expect(try store.assistantChats(matching: "  ").count == 3)
    }

    @Test("deleting a chat removes its messages; clear all removes everything")
    func deletion() throws {
        let store = try Store()
        let a = try #require(try store.createAssistantChat(AssistantChat(title: "A")).id)
        let b = try #require(try store.createAssistantChat(AssistantChat(title: "B")).id)
        try store.appendAssistantMessage(AssistantMessage(chatId: a, role: .user, text: "one"))
        try store.appendAssistantMessage(AssistantMessage(chatId: b, role: .user, text: "two"))
        try store.deleteAssistantChat(id: a)
        #expect(try store.assistantChat(id: a) == nil)
        #expect(try store.assistantMessages(chatId: a).isEmpty)
        #expect(try store.assistantMessages(chatId: b).count == 1)
        #expect(Set(try store.deleteAllAssistantChats()) == [b])
        #expect(try store.assistantChats().isEmpty)
        let orphans = try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assistant_message") }
        #expect(orphans == 0)
    }

    @Test("titles come from the first message, one line, cut at a word")
    func titles() {
        #expect(AssistantChat.title(fromFirstMessage: "What did I say\n about the deck?") == "What did I say about the deck?")
        let long = AssistantChat.title(fromFirstMessage: "Summarise everything I dictated this week about the pricing page and the launch plan")
        #expect(long.hasSuffix("…"))
        #expect(long.count <= AssistantChat.derivedTitleLength + 1)
        #expect(!long.contains("  "))
        #expect(AssistantChat.title(fromFirstMessage: "   ") == "New chat")
    }

    @Test("history groups: today, yesterday, previous 7 days, older")
    func grouping() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 15)))
        func chat(_ id: Int64, hoursAgo: Double) -> AssistantChat {
            let date = now.addingTimeInterval(-hoursAgo * 3600)
            return AssistantChat(id: id, title: "\(id)", createdAt: date, updatedAt: date)
        }
        let chats = [chat(1, hoursAgo: 1), chat(2, hoursAgo: 14), chat(3, hoursAgo: 20), chat(4, hoursAgo: 24 * 4), chat(5, hoursAgo: 24 * 30)]
        let groups = AssistantHistoryGroup.grouped(chats, now: now, calendar: calendar)
        #expect(groups.map(\.group) == [.today, .yesterday, .previousWeek, .older])
        #expect(groups.map { $0.chats.compactMap(\.id) } == [[1, 2], [3], [4], [5]])
        #expect(AssistantHistoryGroup.grouped([], now: now).isEmpty)
    }

    @Test("carried transcript keeps the newest messages within the limit, oldest first")
    func transcript() throws {
        let messages: [(role: AssistantMessage.Role, text: String)] = [
            (.user, "first question " + String(repeating: "x", count: 300)),
            (.assistant, "first answer"),
            (.notice, "Hushy note, skipped"),
            (.user, "second question"),
            (.assistant, "second answer"),
        ]
        let full = try #require(AssistantTranscript.carriedContext(messages))
        #expect(full.contains("User: first question"))
        #expect(!full.contains("Hushy note"))
        #expect(try #require(full.range(of: "first answer")).lowerBound < (try #require(full.range(of: "second answer"))).lowerBound)
        #expect(!full.contains("most recent part only"))

        let trimmed = try #require(AssistantTranscript.carriedContext(messages, limit: 80))
        #expect(trimmed.contains("second answer"))
        #expect(!trimmed.contains("first question"))
        #expect(trimmed.contains("most recent part only"))
        #expect(AssistantTranscript.carriedContext([]) == nil)

        let huge = AssistantTranscript.carriedContext([(.assistant, String(repeating: "y", count: 50_000))])
        #expect((huge?.count ?? 0) < 2_000)
    }
}
