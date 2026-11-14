import Foundation
import MurmurCore

/// Fixture states for `Murmur --snapshots`: pinned agent availability and conversations. Never
/// runs a CLI and never probes the machine.
extension AssistantModel {
    /// Pins what the snapshot renderer shows. `installed` agents are "ready" unless listed in
    /// `signedOut`.
    func pinForSnapshot(
        installed: [AgentKind], messages: [Message], draft: String = "", enabled: Bool = true,
        signedOut: [AgentKind] = [], title: String? = nil
    ) {
        var states: [AgentKind: AgentAccountState] = [:]
        for agent in AgentKind.allCases {
            states[agent] = !installed.contains(agent) ? .notInstalled : signedOut.contains(agent) ? .signedOut : .ready
        }
        accounts.pin(states)
        settings.assistantEnabled = enabled
        agent = .claudeCode
        replaceMessages(messages)
        self.draft = draft
        currentChatTitle = title
        pinRunning(messages.last?.isStreaming ?? false)
    }

    static var snapshotConversation: [Message] {
        [
            Message(role: .user, text: "What did I say about my laptop?"),
            Message(role: .assistant, text: """
                You mentioned your laptop twice today:

                - **9:41** in Hushy — *"Let's meet at nine and bring your laptop."*
                - In **Weekly sync**, you agreed to ship the snapshot tooling this week.

                Nothing about a deadline for your laptop itself.
                """, toolSummary: "Searched your history · Read a note"),
            Message(role: .user, text: "Draft a standup update from today"),
            Message(role: .assistant, text: "", activity: "Searching your history…", isStreaming: true),
        ]
    }

    /// A chat where the agent proposed a reminder: one card awaiting confirmation, one added.
    static var snapshotActionConversation: [Message] {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let sync = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return [
            Message(role: .user, text: "Remind me tomorrow at 9 to send the deck, and book 30 minutes with Sam after lunch"),
            Message(role: .assistant, text: """
                Here's what I'd set up. Nothing is added until you confirm:
                """, toolSummary: "Searched your history · Proposed an action", actions: [
                    ChatActionEntry(action: ProposedAction(
                        kind: .createReminder, title: "Send the deck", start: nine, sourceText: "Remind me tomorrow at 9")),
                    ChatActionEntry(action: ProposedAction(
                        kind: .createEvent, title: "Deck review with Sam", start: sync, end: sync.addingTimeInterval(1800),
                        sourceText: "book 30 minutes with Sam"), status: .added, recordID: 1),
                ]),
        ]
    }

    static func snapshotHistory(now: Date = Date()) -> [AssistantChat] {
        let hour: TimeInterval = 3600
        return [
            ("What did I say about my laptop?", 0.5), ("Draft a standup update from today", 3),
            ("Remind me tomorrow at 9 to send the deck", 26), ("Summarise the pricing call", 60),
            ("Action items from Weekly sync", 24 * 5), ("What did Dana promise last month?", 24 * 20),
        ].enumerated().map { index, item in
            AssistantChat(
                id: Int64(index + 1), title: item.0, createdAt: now.addingTimeInterval(-item.1 * hour),
                updatedAt: now.addingTimeInterval(-item.1 * hour))
        }
    }
}
