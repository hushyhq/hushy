import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// The Assistant end to end against a fake `claude` script: chats are saved, reopened chats
/// resume their session, a vanished session is retried once with the transcript as context,
/// and proposed actions only execute when confirmed (and only with Pro).
@Suite("Assistant chat flow (fake agent)", .serialized)
@MainActor
struct AssistantChatFlowTests {
    @MainActor
    final class Harness {
        let directory: URL
        let script: URL
        let log: URL
        let defaultsName = "hushy-test-flow-\(UUID().uuidString)"
        let settings: AppSettings
        let store: Store

        init(start: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-flow-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            script = directory.appendingPathComponent("claude")
            log = directory.appendingPathComponent("calls.txt")
            // Each call appends its argv (NUL-separated) and a separator. `--resume gone` fails
            // like Claude Code does for a session it no longer has.
            try """
                #!/bin/sh
                n=0
                if [ -f "\(directory.path)/stdin-count" ]; then n=$(cat "\(directory.path)/stdin-count"); fi
                cat > "\(directory.path)/stdin-$n.txt"
                echo $((n + 1)) > "\(directory.path)/stdin-count"
                for arg in "$@"; do printf '%s\\0' "$arg" >> "\(log.path)"; done
                printf '=====\\0' >> "\(log.path)"
                prev=""
                for arg in "$@"; do
                  if [ "$prev" = "--resume" ] && [ "$arg" = "gone" ]; then echo 'No conversation found with session ID: gone' >&2; exit 1; fi
                  prev="$arg"
                done
                cat <<'JSON'
                {"type":"system","subtype":"init","session_id":"sess-A","tools":["mcp__hushy__search_notes","mcp__hushy__propose_action"],"mcp_servers":[{"name":"hushy","status":"connected"}]}
                {"type":"assistant","message":{"content":[{"type":"text","text":"Found it."},{"type":"tool_use","id":"t1","name":"mcp__hushy__propose_action","input":{"kind":"createReminder","title":"Send the deck","start":"\(start)"}}]},"session_id":"sess-A"}
                {"type":"result","subtype":"success","is_error":false,"result":"Found it.","session_id":"sess-A"}
                JSON
                """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            settings = AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)
            store = try Store()
        }

        func model() -> AssistantModel {
            let path = script.path
            let model = AssistantModel(
                settings: settings, store: store, workspaceBase: directory.appendingPathComponent("data"),
                makeBridge: {
                    AgentChatBridge(
                        runner: AgentProcessRunner(timeout: .seconds(20), killGrace: .milliseconds(300)),
                        locate: { $0 == "claude" ? path : nil }, serverPath: "/usr/bin/true", murmurHome: nil)
                })
            model.pinForSnapshot(installed: [.claudeCode], messages: [])
            return model
        }

        /// argv of each call so far.
        var calls: [[String]] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "=====\0").filter { !$0.isEmpty }
                .map { Array($0.components(separatedBy: "\0").dropLast()) }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
    }

    private func start() -> String {
        ProposeActionTool.isoFormatter().string(from: Date().addingTimeInterval(86_400))
    }

    private func waitUntilIdle(_ model: AssistantModel) async throws {
        for _ in 0..<200 where model.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!model.isRunning)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    @Test("a chat is saved, titled, and resumed with its session after reopening")
    func saveAndResume() async throws {
        let harness = try Harness(start: start())
        defer { harness.cleanUp() }
        let first = harness.model()
        #expect(first.send("What did I say about the deck?"))
        try await waitUntilIdle(first)

        let chats = try harness.store.assistantChats()
        let chat = try #require(chats.first)
        let chatID = try #require(chat.id)
        #expect(chats.count == 1)
        #expect(chat.title == "What did I say about the deck?")
        #expect(chat.agentSessionId == "sess-A")
        #expect(chat.model == "haiku")
        let saved = try harness.store.assistantMessages(chatId: chatID)
        #expect(saved.map(\.role) == [.user, .assistant])
        #expect(saved.last?.text == "Found it.")
        #expect(saved.last?.actions.first?.action.title == "Send the deck")
        #expect(saved.last?.actions.first?.action.sourceText == "What did I say about the deck?")
        #expect(saved.last?.actions.first?.status == .pending)
        #expect(harness.calls.first.map { value(after: "--resume", in: $0) } == .some(nil))
        #expect(harness.calls.first.flatMap { value(after: "--model", in: $0) } == "haiku")

        // "Relaunch": a new model opens the saved chat and continues its session.
        harness.settings.assistantModel = .sonnet
        let second = harness.model()
        second.openChat(chatID)
        #expect(second.messages.map(\.text) == ["What did I say about the deck?", "Found it."])
        #expect(second.messages.last?.actions.count == 1)
        #expect(second.send("And the deadline?"))
        try await waitUntilIdle(second)
        let resumed = try #require(harness.calls.last)
        #expect(value(after: "--resume", in: resumed) == "sess-A")
        #expect(value(after: "--model", in: resumed) == "sonnet")
        // The same stable workspace is the working directory across launches.
        #expect(FileManager.default.fileExists(
            atPath: AgentWorkspace.forChat(id: chatID, base: harness.directory.appendingPathComponent("data")).workingDirectory.path))
    }

    @Test("a vanished session is retried once, fresh, with the transcript as context and a note")
    func missingSessionRetry() async throws {
        let harness = try Harness(start: start())
        defer { harness.cleanUp() }
        let chat = try harness.store.createAssistantChat(AssistantChat(title: "Old chat", agentSessionId: "gone"))
        let chatID = try #require(chat.id)
        try harness.store.appendAssistantMessage(AssistantMessage(chatId: chatID, role: .user, text: "Earlier question about pricing"))
        try harness.store.appendAssistantMessage(AssistantMessage(chatId: chatID, role: .assistant, text: "Earlier answer: 12 dollars"))

        let model = harness.model()
        model.openChat(chatID)
        #expect(model.send("Follow up"))
        try await waitUntilIdle(model)

        let calls = harness.calls
        #expect(calls.count == 2)
        #expect(value(after: "--resume", in: calls[0]) == "gone")
        #expect(value(after: "--resume", in: calls[1]) == nil)
        let prompt = try #require(value(after: "--append-system-prompt", in: calls[1]))
        #expect(!prompt.contains("Earlier question about pricing"))
        #expect(!prompt.contains("Earlier answer: 12 dollars"))
        let stdin = try String(contentsOf: harness.directory.appendingPathComponent("stdin-1.txt"), encoding: .utf8)
        #expect(stdin.contains("Earlier question about pricing"))
        #expect(stdin.contains("Earlier answer: 12 dollars"))
        #expect(stdin.hasSuffix("Follow up") || stdin.contains("\n\nFollow up"))

        #expect(model.messages.map(\.role) == [.user, .assistant, .user, .notice, .assistant])
        #expect(model.messages.last?.text == "Found it.")
        #expect(model.messages.last?.errorText == nil)
        #expect(try harness.store.assistantChat(id: chatID)?.agentSessionId == "sess-A")
        #expect(try harness.store.assistantMessages(chatId: chatID).map(\.role) == [.user, .assistant, .user, .notice, .assistant])
    }

    @Test("proposed actions run only on confirm, only with Pro, and record their result")
    func actionConfirmation() async throws {
        let harness = try Harness(start: start())
        defer { harness.cleanUp() }
        let model = harness.model()
        var executed: [ProposedAction] = []
        var entitled = false
        model.actionHandlers = AssistantActionHandlers(
            isEntitled: { entitled },
            execute: { action in
                executed.append(action)
                return .success(ActionRecord(id: 42, kind: action.kind, title: action.title, sourceText: action.sourceText))
            },
            undo: { _ in .undone })
        #expect(model.send("Remind me to send the deck"))
        try await waitUntilIdle(model)
        let reply = try #require(model.messages.last)
        let entry = try #require(reply.actions.first)
        #expect(executed.isEmpty, "proposing never executes")

        model.confirmAction(entry.id, in: reply.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(executed.isEmpty, "not Pro: confirm is refused")

        entitled = true
        model.confirmAction(entry.id, in: reply.id)
        for _ in 0..<50 where model.messages.last?.actions.first?.status != .added {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(executed.map(\.title) == ["Send the deck"])
        #expect(model.messages.last?.actions.first?.status == .added)
        let chatID = try #require(model.currentChatID)
        #expect(try harness.store.assistantMessages(chatId: chatID).last?.actions.first?.recordID == 42)

        model.confirmAction(entry.id, in: reply.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(executed.count == 1, "an added action can't run twice")
        #expect(model.canUndo(try #require(model.messages.last?.actions.first)))
    }

    @Test("deleting a chat removes its rows and workspace; clear all removes every chat")
    func deleteAndClear() async throws {
        let harness = try Harness(start: start())
        defer { harness.cleanUp() }
        let model = harness.model()
        #expect(model.send("one"))
        try await waitUntilIdle(model)
        let first = try #require(model.currentChatID)
        let workspace = AgentWorkspace.forChat(id: first, base: harness.directory.appendingPathComponent("data"))
        #expect(FileManager.default.fileExists(atPath: workspace.root.path))
        model.newConversation()
        #expect(model.send("two"))
        try await waitUntilIdle(model)
        #expect(try harness.store.assistantChats().count == 2)

        model.deleteChat(first)
        #expect(!FileManager.default.fileExists(atPath: workspace.root.path))
        #expect(try harness.store.assistantChats().count == 1)
        #expect(!model.messages.isEmpty, "deleting another chat keeps the open one")

        model.clearAllChats()
        #expect(try harness.store.assistantChats().isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.currentChatID == nil)
    }

    @Test("turning the Assistant off stops a running request")
    func disableStops() async throws {
        let harness = try Harness(start: start())
        defer { harness.cleanUp() }
        try "#!/bin/sh\ncat > /dev/null\nsleep 30\n".write(to: harness.script, atomically: true, encoding: .utf8)
        let model = harness.model()
        #expect(model.send("slow"))
        #expect(model.isRunning)
        model.disable()
        #expect(!model.isRunning)
        #expect(!harness.settings.assistantEnabled)
        #expect(model.messages.last?.text == "Stopped.")
    }
}
