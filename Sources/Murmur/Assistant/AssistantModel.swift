import Foundation
import MurmurCore
import Observation
import os

/// Home's assistant chat: the open conversation, its saved history, the opt-in and consent
/// state, and one request at a time through `AgentChatBridge`. The bridge does the subprocess
/// work; this type owns UI state and writes each finished message to Hushy's database
/// (`assistant_chat` / `assistant_message`). History, actions and snapshot fixtures live in
/// the `AssistantModel+…` extensions.
@MainActor
@Observable
final class AssistantModel {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant, notice }

        let id: UUID
        /// The row this message was saved as, once it's saved.
        var storedID: Int64?
        let role: Role
        var text: String
        /// "Searching your history…" while a tool call is in flight.
        var activity: String?
        /// What the finished answer looked up ("Searched your history · Read a note").
        var toolSummary: String?
        var errorText: String?
        var isStreaming = false
        /// Hushy's MCP server didn't connect, so this answer isn't based on the user's data.
        var dataUnavailable = false
        /// Calendar/Reminders/Shortcuts actions the agent proposed, awaiting the user.
        var actions: [ChatActionEntry] = []

        init(
            id: UUID = UUID(), storedID: Int64? = nil, role: Role, text: String, activity: String? = nil,
            toolSummary: String? = nil, errorText: String? = nil, isStreaming: Bool = false, actions: [ChatActionEntry] = []
        ) {
            self.id = id
            self.storedID = storedID
            self.role = role
            self.text = text
            self.activity = activity
            self.toolSummary = toolSummary
            self.errorText = errorText
            self.isStreaming = isStreaming
            self.actions = actions
        }
    }

    /// Where the consent sheet was asked for, so exactly one window presents it.
    enum ConsentHost { case home, settings }

    /// Longest message accepted; a chat question, not a document.
    static let maxMessageLength = 8_000
    static let suggestions = [
        "Summarise my last meeting",
        "What were the action items from the weekly sync?",
    ]

    private(set) var messages: [Message] = []
    var agent: AgentKind = .claudeCode
    var draft = ""
    private(set) var isRunning = false
    /// The saved chat on screen, or nil for a new one that hasn't been sent yet.
    var currentChatID: Int64?
    var currentChatTitle: String?
    /// Set while the consent sheet should show, and in which window.
    var consentHost: ConsentHost?
    /// Saved chats for the history popover, filtered by `historyQuery`.
    var history: [AssistantChat] = []
    var historyQuery = "" { didSet { reloadHistory() } }
    /// Actions whose confirmation is executing right now.
    var executingActions: Set<UUID> = []
    /// The line under an action card for this session only. It can name a calendar, list or
    /// Shortcut the person said, so it is never saved with the chat (`ChatActionEntry` keeps only
    /// the fixed status).
    var actionNotes: [UUID: String] = [:]

    let accounts: AgentAccountsModel
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let store: Store?
    @ObservationIgnored var actionHandlers = AssistantActionHandlers.unavailable
    /// Test seam: replaces the chat-message write, so a storage failure can be simulated.
    @ObservationIgnored var writeMessage: ((AssistantMessage) throws -> Int64?)?
    @ObservationIgnored var sessionID: String?
    @ObservationIgnored var workspace: AgentWorkspace?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Identifies the running request, so a cancelled one finishing late can't clear the flag
    /// for the request that replaced it.
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored let workspaceBase: URL
    @ObservationIgnored private let makeBridge: () -> AgentChatBridge
    @ObservationIgnored let log = Logger(subsystem: "app.hushy", category: "assistant")

    init(
        settings: AppSettings, store: Store?, accounts: AgentAccountsModel = AgentAccountsModel(),
        workspaceBase: URL = AppPaths.supportDirectory,
        makeBridge: @escaping () -> AgentChatBridge = { AgentChatBridge(serverPath: MCPInstaller.resolvedServerPath) }
    ) {
        self.settings = settings
        self.store = store
        self.accounts = accounts
        self.workspaceBase = workspaceBase
        self.makeBridge = makeBridge
    }

    // MARK: Availability

    /// The user turned the Assistant on (and agreed to the consent text).
    var isEnabled: Bool { settings.assistantEnabled }
    var claudeState: AgentAccountState { accounts.state(of: .claudeCode) }
    /// Chat is possible right now: on, Claude Code installed and not known to be signed out.
    var isConnected: Bool { isEnabled && claudeState.canChat && Entitlements.has(.assistantChat) }
    var installedAgents: [AgentKind] { accounts.installedAgents }
    /// Show the picker only when there's a real choice to make or an installed agent to explain.
    var showsAgentPicker: Bool { installedAgents.count > 1 }

    func refreshAvailability() {
        Task { await accounts.refresh() }
    }

    var canSend: Bool {
        isConnected && !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Opt-in

    /// "Turn on…": straight on if the current consent was already given, else the sheet.
    func requestEnable(from host: ConsentHost) {
        if settings.assistantConsentVersion >= AssistantConsent.currentVersion {
            settings.assistantEnabled = true
            refreshAvailability()
        } else {
            consentHost = host
        }
    }

    func acceptConsent() {
        settings.assistantConsentVersion = AssistantConsent.currentVersion
        settings.assistantEnabled = true
        consentHost = nil
        refreshAvailability()
    }

    func declineConsent() {
        consentHost = nil
    }

    /// Off: stops any running request right away. Saved chats stay until cleared.
    func disable() {
        cancel()
        settings.assistantEnabled = false
    }

    // MARK: Sending

    func sendDraft() {
        let text = draft
        guard send(text) else { return }
        draft = ""
    }

    /// Starts a turn. Returns false (and does nothing) when a request is already running, the
    /// text is empty, or no agent is connected.
    @discardableResult
    func send(_ rawText: String) -> Bool {
        let text = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxMessageLength))
        guard isConnected, !isRunning, !text.isEmpty else { return false }
        ensureChat(firstMessage: text)
        var question = Message(role: .user, text: text)
        question.storedID = persist(question)
        messages.append(question)
        startTurn(text: text, carriedContext: nil, allowRetry: true)
        return true
    }

    private func startTurn(text: String, carriedContext: String?, allowRetry: Bool) {
        messages.append(Message(role: .assistant, text: "", activity: "Thinking…", isStreaming: true))
        let replyID = messages[messages.count - 1].id
        isRunning = true

        let workspace: AgentWorkspace
        do {
            workspace = try currentWorkspace()
        } catch {
            var reply = AgentReply(agent: agent)
            reply.fail(.launchFailed(error.localizedDescription))
            finishTurn(replyID, reply: reply, text: text, allowRetry: false)
            return
        }
        let turn = AgentTurnOptions(
            model: settings.assistantModel, resumeSessionID: sessionID, carriedContext: carriedContext)
        let stream = makeBridge().send(message: text, agent: agent, turn: turn, workspace: workspace)
        let run = UUID()
        runID = run
        task = Task { [weak self] in
            var last: AgentReply?
            for await reply in stream {
                guard !Task.isCancelled else { break }
                last = reply
                self?.update(replyID, from: reply, sourceText: text)
            }
            guard let self, self.runID == run else { return }
            self.task = nil
            self.finishTurn(replyID, reply: last, text: text, allowRetry: allowRetry)
        }
    }

    /// A turn ended. A resumed session that no longer exists gets one automatic retry in a
    /// fresh session with the visible transcript as context, and a small note saying so.
    private func finishTurn(_ replyID: UUID, reply: AgentReply?, text: String, allowRetry: Bool) {
        if allowRetry, reply?.error == .sessionNotFound {
            messages.removeAll { $0.id == replyID }
            let earlier = messages.dropLast().map { (role: $0.role.stored, text: $0.text) }
            sessionID = nil
            saveSession()
            var note = Message(role: .notice, text: AssistantConsent.freshSessionNote)
            note.storedID = persist(note)
            messages.append(note)
            startTurn(text: text, carriedContext: AssistantTranscript.carriedContext(earlier), allowRetry: false)
            return
        }
        isRunning = false
        if let reply { update(replyID, from: reply, sourceText: text) }
        if reply?.error == .notLoggedIn(.claudeCode) { accounts.markSignedOut(.claudeCode) }
        if let index = messages.firstIndex(where: { $0.id == replyID }) {
            messages[index].isStreaming = false
            messages[index].activity = nil
            messages[index].toolSummary = reply.flatMap { AgentReply.toolSummary($0.toolsUsed) }
            messages[index].storedID = persist(messages[index])
        }
        saveSession()
    }

    /// Stops the running request; the agent process is terminated by the bridge.
    func cancel() {
        guard isRunning || task != nil else { return }
        runID = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        if let index = messages.lastIndex(where: { $0.role == .assistant }), messages[index].isStreaming {
            messages[index].isStreaming = false
            messages[index].activity = nil
            if messages[index].text.isEmpty { messages[index].text = "Stopped." }
            messages[index].storedID = persist(messages[index])
        }
    }

    /// Starts a new, unsaved chat. The previous one stays in history.
    func newConversation() {
        cancel()
        messages = []
        // A reason shown under a card belongs to the conversation it was shown in.
        actionNotes = [:]
        currentChatID = nil
        currentChatTitle = nil
        sessionID = nil
        workspace = nil
    }

    /// App quit: stop anything running and drop a temporary (unsaved) workspace.
    func shutdown() {
        cancel()
        if currentChatID == nil { workspace?.remove() }
    }

    private func update(_ id: UUID, from reply: AgentReply, sourceText: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if let session = reply.sessionID { sessionID = session }
        messages[index].text = reply.text
        messages[index].activity = reply.isFinished ? nil : (reply.activity ?? (reply.text.isEmpty ? "Thinking…" : nil))
        messages[index].errorText = reply.error?.userMessage
        messages[index].dataUnavailable = reply.dataUnavailable
        messages[index].isStreaming = !reply.isFinished
        let known = Set(messages[index].actions.map(\.action.id))
        for proposed in reply.proposedActions where !known.contains(proposed.id) {
            var action = proposed
            action.sourceText = sourceText
            messages[index].actions.append(ChatActionEntry(action: action))
        }
    }

    /// The saved chat's stable workspace, or a temporary one when the database is unavailable.
    private func currentWorkspace() throws -> AgentWorkspace {
        if let workspace { return workspace }
        let created = try currentChatID.map { AgentWorkspace.forChat(id: $0, base: workspaceBase) }
            ?? AgentWorkspace.makeTemporary()
        try FileManager.default.createDirectory(at: created.workingDirectory, withIntermediateDirectories: true)
        workspace = created
        return created
    }

    /// Replaces the on-screen conversation (opening a saved chat, snapshots).
    func replaceMessages(_ newMessages: [Message]) {
        messages = newMessages
    }

    /// Edits one on-screen message in place (action status changes).
    func updateMessage(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    /// Snapshot fixtures pin a running state without a process.
    func pinRunning(_ running: Bool) {
        isRunning = running
    }
}

extension AssistantModel.Message.Role {
    var stored: AssistantMessage.Role {
        switch self {
        case .user: .user
        case .assistant: .assistant
        case .notice: .notice
        }
    }

    init(_ stored: AssistantMessage.Role) {
        switch stored {
        case .user: self = .user
        case .assistant: self = .assistant
        case .notice: self = .notice
        }
    }
}

/// The versioned consent text and the one-line notes the Assistant shows.
enum AssistantConsent {
    /// Bump when the consent wording changes materially; users see the sheet again.
    static let currentVersion = 1

    /// "History" is the dictation list in Hushy, which the Assistant never reads, so the name
    /// says what it does read (`MCPServer.Scope.notes`).
    static let title = "Chat with your notes"
    static let points = [
        "Your questions, and whatever Claude Code looks up in Hushy, are sent to Anthropic through your own Claude Code account.",
        "The Assistant never sends anything in the background. Nothing from your history leaves until you press Send.",
        "Everything else in Hushy stays on this Mac. Chats are saved here, and you can delete them any time.",
    ]

    static let freshSessionNote = "Couldn't continue this chat's earlier session, so Hushy started a new one and gave it the recent messages as context."
}

/// How the Assistant executes a confirmed action card. Wired by `AppModel` to
/// `VoiceActionsController` (the same executor, Undo and History as voice actions).
struct AssistantActionHandlers {
    var isEntitled: @MainActor () -> Bool
    var execute: @MainActor (ProposedAction) async -> Result<ActionRecord, ActionExecutionFailure>
    var undo: @MainActor (Int64) async -> VoiceActionsController.UndoOutcome

    static let unavailable = AssistantActionHandlers(
        isEntitled: { Entitlements.has(.voiceActions) },
        execute: { _ in .failure(ActionExecutionFailure(message: "Actions aren't available right now")) },
        undo: { _ in .unavailable })
}
