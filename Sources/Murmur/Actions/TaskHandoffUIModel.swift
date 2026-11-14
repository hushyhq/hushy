import Foundation
import MurmurCore
import Observation

/// The confirmation sheet, the task list and the queue behind them.
///
/// The `taskHandoff` flag is checked here wherever work is accepted (`propose`, `reconfirm`,
/// `confirm`, `retry`) and again inside `HandoffQueue` wherever work is started. With the flag off the list can
/// still be opened, and a task can still be cancelled, deleted or cleared, but nothing is queued
/// and nothing starts.
@MainActor
@Observable
final class TaskHandoffUIModel {
    typealias MakeQueue = @MainActor (
        _ isEnabled: @escaping @Sendable () -> Bool, _ onFinish: @escaping @Sendable (HandoffTask) -> Void
    ) throws -> HandoffQueue

    static let offMessage = "Background AI tasks are off"
    static let busyMessage = "Another task was spoken while this one was open. It was not queued."
    static let notFoundMessage = "Codex was not found on this Mac."
    static let setAsideNotice = "The saved task list could not be read, so it was set aside. This list starts empty."
    static let droppedNotice = "Some saved tasks could not be read and were left out."

    /// A sheet to open: what it asks, the waiting task it stands for (removed once the new one
    /// is queued), and whether the task list opens again when it closes.
    private struct Showing {
        var proposal: HandoffProposal
        var replaces: UUID?
        var returnsToList: Bool
    }

    /// What the confirmation sheet shows, with the tool's file as found when the sheet opened.
    /// It does not change while the sheet is open, and that file is the one the task will run.
    private(set) var proposal: HandoffProposal?
    var showingConfirmation = false
    var showingList = false
    var items: [HandoffTask] = []
    /// Tasks an earlier session left in the saved list. None of them runs as it stands: Run and
    /// Retry on one open the confirmation sheet again (`reconfirm`).
    private(set) var restored: Set<UUID> = []
    /// A saved list that could not be read is still set aside on disk; Clear tasks removes it.
    private(set) var hasSetAsideIndex = false
    var issue: String?
    /// Something the list reports once that is not a failure of the last action.
    private(set) var notice: String?
    /// The list is asking whether to clear. Nothing is removed until the person agrees.
    var confirmingClear = false
    /// A confirm is on its way to the queue; a second one is ignored.
    private(set) var isConfirming = false
    /// Which showing of the sheet is on screen. Two sheets with the same words are two sheets.
    @ObservationIgnored private var shownSheet: UUID?
    @ObservationIgnored private var replaces: UUID?
    @ObservationIgnored private var returnsToList = false
    /// A sheet that waits for the task list to close: one window shows one sheet at a time.
    @ObservationIgnored private var waitingForList: Showing?
    @ObservationIgnored private var queue: HandoffQueue?
    @ObservationIgnored private var retrying: Set<UUID> = []
    @ObservationIgnored private let isEnabled: @Sendable () -> Bool
    @ObservationIgnored private let locateTool: () -> String?
    @ObservationIgnored private let hasStore: () -> Bool
    @ObservationIgnored private let hasClearableStore: () -> Bool
    @ObservationIgnored private let makeQueue: MakeQueue

    /// `locateTool`, `hasStore` and `hasClearableStore` look at this Mac (the installed tool,
    /// the saved task list); tests replace them and `makeQueue` so nothing outside a temporary
    /// folder is read.
    init(
        isEnabled: @escaping @Sendable () -> Bool = { FeatureFlags.taskHandoff },
        locateTool: @escaping () -> String? = { CodexHandoffRunner.locateExecutable() },
        hasStore: @escaping () -> Bool = { TaskHandoffNotifier.hasTaskStore },
        hasClearableStore: @escaping () -> Bool = { HandoffQueue.storeHasClearableContent() },
        makeQueue: MakeQueue? = nil
    ) {
        self.isEnabled = isEnabled
        self.locateTool = locateTool
        self.hasStore = hasStore
        self.hasClearableStore = hasClearableStore
        self.makeQueue = makeQueue ?? { isEnabled, onFinish in
            try HandoffQueue(runner: CodexHandoffRunner(isEnabled: isEnabled), isEnabled: isEnabled, onFinish: onFinish)
        }
    }

    var isOn: Bool { isEnabled() }

    /// A queue exists in this session, so quitting has to stop it first.
    var hasLiveQueue: Bool { queue != nil }

    /// Shows a task for confirmation. While a sheet is open its text stays as it is: a task spoken
    /// meanwhile is dropped and the sheet says so, because swapping the text under the person's
    /// pointer could make them confirm something they never read.
    func propose(_ proposal: HandoffProposal) {
        guard isEnabled() else { return }
        show(Showing(proposal: proposal, replaces: nil, returnsToList: false))
    }

    /// Run on a waiting task, or Retry on an ended one, that an earlier session left in the saved
    /// list. Nothing read from disk is run as it stands, because anything can write that file: the
    /// request goes back through the confirmation sheet, with the tool found afresh, and only a
    /// click on Queue task there starts it, as a new task.
    func reconfirm(_ item: HandoffTask) {
        guard isEnabled() else {
            issue = Self.offMessage
            return
        }
        show(Showing(proposal: HandoffProposal(tool: .codex, request: item.request),
                     replaces: item.state == .waiting ? item.id : nil, returnsToList: showingList))
    }

    private func show(_ showing: Showing) {
        if (showingConfirmation && proposal != nil) || waitingForList != nil {
            issue = Self.busyMessage
            return
        }
        // The list is a sheet too. It closes first, and `listClosed()` opens this one.
        if showingList {
            waitingForList = showing
            showingList = false
            return
        }
        present(showing)
    }

    private func present(_ showing: Showing) {
        // Found once, here. The sheet shows this file and the task carries it; nothing looks again.
        proposal = HandoffProposal(tool: showing.proposal.tool, request: showing.proposal.request, executable: locateTool())
        shownSheet = UUID()
        replaces = showing.replaces
        returnsToList = showing.returnsToList
        issue = nil
        showingConfirmation = true
    }

    /// The task list finished closing.
    func listClosed() {
        guard let next = waitingForList else { return }
        waitingForList = nil
        present(next)
    }

    /// Queues the shown task once. Calls made while one is in flight, or after it succeeded, do nothing.
    func confirm() async {
        guard let proposal, let clicked = shownSheet, !isConfirming else { return }
        guard isEnabled() else {
            issue = Self.offMessage
            return
        }
        guard let executable = proposal.executable else {
            issue = Self.notFoundMessage
            return
        }
        let replaced = replaces
        isConfirming = true
        defer { isConfirming = false }
        do {
            let queue = try await readyQueue()
            // Getting the queue ready takes a moment. If the sheet was cancelled meanwhile, or
            // cancelled and opened again for another task, this click no longer stands.
            guard shownSheet == clicked else { return }
            _ = try await queue.enqueue(tool: proposal.tool, request: proposal.request, executable: executable)
            // The waiting task this sheet stood for has been queued again as the new one.
            if let replaced { try? await queue.delete(replaced) }
            self.proposal = nil
            shownSheet = nil
            replaces = nil
            showingConfirmation = false
            issue = nil
            await refresh()
            TaskHandoffNotifier.prepare()
        } catch { issue = "Could not queue task" }
    }

    func cancelProposal() {
        proposal = nil
        shownSheet = nil
        replaces = nil
        showingConfirmation = false
    }

    /// The sheet closed by any route (Cancel, Escape, a finished confirm). A confirm still on its
    /// way is withdrawn with it. A sheet already opened again for the next task is left alone.
    func confirmationClosed() {
        guard !showingConfirmation else { return }
        proposal = nil
        shownSheet = nil
        replaces = nil
        // A sheet opened from the task list hands back to it.
        if returnsToList {
            returnsToList = false
            openList()
        }
    }

    func shutdown() async {
        await queue?.stopAndWait()
    }

    /// At launch. Opening the queue is what marks a task left running as interrupted and stops a
    /// tool a crashed or force-quit session left behind, so it also happens with the flag off when
    /// an earlier session saved tasks. Nothing starts here, and nothing saved ever starts by itself.
    func resumeAtLaunch() {
        guard isEnabled() || hasStore() else { return }
        Task { await refresh() }
    }

    func openList() {
        showingList = true
        Task { await refresh() }
    }

    func refresh() async {
        do {
            let queue = try await readyQueue()
            let overview = await queue.overview()
            items = overview.items
            restored = overview.restored
            hasSetAsideIndex = overview.hasSetAsideIndex
        }
        catch { issue = "Could not load tasks" }
    }

    func cancel(_ id: UUID) async {
        do { let queue = try await readyQueue(); try await queue.cancel(id); await refresh() }
        catch { issue = "Could not cancel task" }
    }

    func retry(_ item: HandoffTask) async {
        guard item.state == .failed || item.state == .interrupted else { return }
        guard isEnabled() else {
            issue = Self.offMessage
            return
        }
        // Only a task this session queued has a file the person was shown. Anything else asks again.
        guard !restored.contains(item.id), let executable = item.executable else {
            reconfirm(item)
            return
        }
        guard retrying.insert(item.id).inserted else { return }
        defer { retrying.remove(item.id) }
        do {
            let queue = try await readyQueue()
            // The same file as before, under the same rule: this retry shows no sheet, so it finds no new one.
            _ = try await queue.enqueue(tool: item.tool, request: item.request, executable: executable)
            await refresh()
        } catch { issue = "Could not queue task" }
    }

    func delete(_ id: UUID) async {
        do { let queue = try await readyQueue(); try await queue.delete(id); await refresh() }
        catch { issue = "Could not delete task" }
    }

    /// There is something Clear tasks would remove: a task that is not running, or a set-aside list.
    var hasClearableTasks: Bool { hasSetAsideIndex || items.contains { $0.state != .running } }

    /// Whether the Privacy pane offers "Clear background tasks": the flag is on, or an earlier
    /// session left something on disk (a task that is not running, or a list that could not be
    /// read), so someone who tried the feature and turned it off can still remove what it stored.
    /// This only reads; it never makes the queue, the index or its folder.
    func offersClear() -> Bool { isEnabled() || hasClearableStore() }

    /// Removes every task except one that is running, with its request and result, and a saved
    /// list that was set aside as unreadable. The list and the Privacy pane both ask before calling this.
    func clearTasks() async {
        confirmingClear = false
        do {
            let queue = try await readyQueue()
            try await queue.clear()
            // What the notice spoke of is gone with the rest.
            notice = nil
            await refresh()
        } catch { issue = "Could not clear tasks" }
    }

    /// A result goes to the clipboard marked like Hushy's other writes, so clipboard-history apps skip it.
    func copyResult(_ text: String, using paster: ClipboardPaster? = nil) {
        (paster ?? TextInserter.shared).copy(text, markTransient: true)
    }

    func pinForSnapshot(
        _ tasks: [HandoffTask], proposal: HandoffProposal? = nil, restored: Set<UUID> = [], confirmingClear: Bool = false
    ) {
        items = tasks
        self.proposal = proposal
        self.restored = restored
        self.confirmingClear = confirmingClear
    }

    /// One queue per session. It is stored before the first suspension, so callers that arrive
    /// together (the list's `.task` and `openList()`) all get the same one. `start()` only runs
    /// work while the flag is on; calling it on every use lets tasks queued in this session
    /// resume once it is.
    private func readyQueue() async throws -> HandoffQueue {
        if let queue {
            await queue.start()
            return queue
        }
        let newQueue = try makeQueue(isEnabled) { [weak self] item in
            Task { @MainActor in
                guard let self else { return }
                await self.refresh()
                TaskHandoffNotifier.finished(item)
            }
        }
        queue = newQueue
        if newQueue.indexWasSetAside {
            notice = Self.setAsideNotice
        } else if newQueue.droppedEntries > 0 {
            notice = Self.droppedNotice
        }
        await newQueue.start()
        return newQueue
    }
}
