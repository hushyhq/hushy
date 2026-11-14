import AppKit
import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

/// In-memory stand-in for the Codex launcher. No test here starts a process.
private actor FakeHandoffRunner: HandoffRunning {
    private var started: [UUID] = []
    private var tools: [String?] = []
    private var failure: (any Error)?
    func calls() -> [UUID] { started }
    /// The tool's file each task asked for, in the order they ran.
    func toolsAskedFor() -> [String?] { tools }
    func fail(with error: (any Error)?) { failure = error }
    func run(_ task: HandoffTask, in folder: URL, started report: @escaping @Sendable (HandoffChild) -> Void) async throws -> String {
        started.append(task.id)
        tools.append(task.executable)
        if let failure { throw failure }
        return "Invented result"
    }
}

private final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    var value: Value { state.withLock { $0 } }
    func set(_ value: Value) { state.withLock { $0 = value } }
}

/// The confirmation sheet and task list model: one queue per session, the flag, and a confirm
/// that happens once. Every queue lives in a temporary folder with a fake runner.
@Suite("Task hand-off model", .serialized)
@MainActor
final class TaskHandoffUIModelTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-handoff-ui-\(UUID().uuidString)")
    private let runner = FakeHandoffRunner()
    private let flag = Shared(true)
    private var queuesMade = 0
    /// Runs while the queue is being made ready: the moment between a click on Queue task and the task being queued.
    private var whileReadying: (() -> Void)?
    private var storeExists = false
    /// What a search for the tool finds right now. Tests change it between the sheet and the run.
    private var toolFound: String? = "/opt/invented/bin/codex"

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The tool is "found" at an invented path and the store's existence is a variable, so no
    /// test looks at this Mac's own tools or data folder.
    private func makeModel() -> TaskHandoffUIModel {
        let flag = flag
        return TaskHandoffUIModel(
            isEnabled: { flag.value }, locateTool: { [self] in toolFound }, hasStore: { [self] in storeExists },
            hasClearableStore: { [self] in HandoffQueue.storeHasClearableContent(in: root) },
            makeQueue: { [self] isEnabled, onFinish in
                queuesMade += 1
                whileReadying?()
                return try HandoffQueue(root: root, workRoot: root.appendingPathComponent("work"), runner: runner,
                                        isEnabled: isEnabled, onFinish: onFinish)
            })
    }

    private func save(_ tasks: [HandoffTask]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(tasks).write(to: root.appendingPathComponent("index.json"))
    }

    private func saveWaitingTask(_ request: String) throws -> HandoffTask {
        let task = HandoffTask(tool: .codex, request: request)
        try save([task])
        return task
    }

    private func eventually(within limit: Duration = .seconds(20), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// As spoken, and as the sheet shows it: with the file found when the sheet opened.
    private static let kiteTask = HandoffProposal(tool: .codex, request: "Invented task about paper kites")
    private static let shownKiteTask = HandoffProposal(tool: .codex, request: "Invented task about paper kites",
                                                       executable: "/opt/invented/bin/codex")

    /// H2. The list's `.task` and `openList()` both refresh at once; each used to build its own queue.
    @Test("callers that arrive together share one queue, and a saved task does not start")
    func oneQueueForConcurrentCallers() async throws {
        let saved = try saveWaitingTask("Invented saved task")
        let model = makeModel()

        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        model.openList()
        _ = await (first, second)
        try await Task.sleep(for: .milliseconds(200))
        await model.refresh()

        #expect(queuesMade == 1)
        #expect(model.items.map(\.state) == [.waiting])
        #expect(model.restored == [saved.id])
        #expect(await runner.calls().isEmpty)
    }

    /// Second review, item 1. Run on a task an earlier session left opens the confirmation sheet
    /// again, with the tool found now. Nothing starts until Queue task is clicked there, and what
    /// starts is a new task with that tool; whatever path the saved list carried is not used.
    @Test("Run on a saved task asks again and starts only from Queue task")
    func runOnASavedTaskAsksAgain() async throws {
        let id = UUID()
        let planted = #"[{"id":"\#(id.uuidString)","tool":"codex","request":"Invented saved task","state":"waiting","createdAt":0,"executable":"/opt/invented/planted/tool"}]"#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(planted.utf8).write(to: root.appendingPathComponent("index.json"))
        let model = makeModel()
        model.openList()
        await model.refresh()
        let saved = try #require(model.items.first)
        #expect(saved.executable == nil)

        // The list is a sheet too: it closes first, then the confirmation opens.
        model.reconfirm(saved)
        #expect(!model.showingList && !model.showingConfirmation)
        model.listClosed()
        #expect(model.showingConfirmation)
        #expect(model.proposal == HandoffProposal(tool: .codex, request: "Invented saved task", executable: "/opt/invented/bin/codex"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await runner.calls().isEmpty)

        await model.confirm()
        // The sheet has closed; the list comes back.
        model.confirmationClosed()
        #expect(model.showingList)
        #expect(await eventually { model.items.first?.state == .done })

        // One task: the new one. The saved entry it stood for is gone and never ran.
        #expect(model.items.count == 1)
        #expect(model.items.first?.id != id)
        #expect(await runner.calls() == model.items.map(\.id))
        #expect(await runner.toolsAskedFor() == ["/opt/invented/bin/codex"])
        #expect(model.restored.isEmpty)
    }

    @Test("cancelling the sheet opened by Run leaves the saved task as it was")
    func cancellingARerunKeepsTheSavedTask() async throws {
        let saved = try saveWaitingTask("Invented saved task")
        let model = makeModel()
        model.openList()
        await model.refresh()

        model.reconfirm(try #require(model.items.first))
        model.listClosed()
        model.cancelProposal()
        model.confirmationClosed()
        await model.refresh()

        #expect(model.showingList)
        #expect(model.items.map(\.id) == [saved.id])
        #expect(model.items.map(\.state) == [.waiting])
        #expect(await runner.calls().isEmpty)
    }

    /// Second review, item 1. Retry on a saved failed or interrupted task takes the same road; a
    /// task queued in this session retries with the file its sheet showed, without a sheet.
    @Test("Retry asks again for a saved task, and reuses the confirmed file for one queued here")
    func retryAsksAgainOnlyForSavedTasks() async throws {
        var failed = HandoffTask(tool: .codex, request: "Invented saved failed task")
        failed.state = .failed
        try save([failed])
        let model = makeModel()
        await model.refresh()

        await model.retry(try #require(model.items.first))
        #expect(model.showingConfirmation)
        #expect(model.proposal?.request == "Invented saved failed task")
        #expect(model.items.count == 1)
        #expect(await runner.calls().isEmpty)
        model.cancelProposal()
        model.confirmationClosed()

        // Queued here, fails, and is retried after another codex has turned up earlier in the search.
        await runner.fail(with: AgentChatError.timedOut(seconds: 900))
        model.propose(Self.kiteTask)
        await model.confirm()
        #expect(await eventually { model.items.last?.state == .failed })
        await runner.fail(with: nil)
        toolFound = "/opt/invented/earlier/codex"

        await model.retry(try #require(model.items.last))

        #expect(!model.showingConfirmation)
        #expect(await eventually { model.items.last?.state == .done })
        #expect(model.items.count == 3)
        #expect(await runner.toolsAskedFor() == ["/opt/invented/bin/codex", "/opt/invented/bin/codex"])
    }

    @Test("flag off: Run and Retry on a saved task open nothing and say why")
    func rerunNeedsTheFlag() async throws {
        var failed = HandoffTask(tool: .codex, request: "Invented saved failed task")
        failed.state = .failed
        try save([HandoffTask(tool: .codex, request: "Invented saved task"), failed])
        flag.set(false)
        let model = makeModel()
        await model.refresh()

        model.reconfirm(model.items[0])
        #expect(model.issue == TaskHandoffUIModel.offMessage)
        model.issue = nil
        await model.retry(model.items[1])
        #expect(model.issue == TaskHandoffUIModel.offMessage)

        #expect(!model.showingConfirmation && model.proposal == nil)
        #expect(model.items.map(\.state) == [.waiting, .failed])
        #expect(await runner.calls().isEmpty)
    }

    @Test("flag off: opening the list shows a saved waiting task and starts nothing")
    func flagOffStartsNothing() async throws {
        let saved = try saveWaitingTask("Invented saved task")
        flag.set(false)
        let model = makeModel()

        model.openList()
        await model.refresh()
        try await Task.sleep(for: .milliseconds(300))
        await model.refresh()

        #expect(model.items.map(\.id) == [saved.id])
        #expect(model.items.map(\.state) == [.waiting])
        #expect(await runner.calls().isEmpty)
    }

    @Test("flag off: nothing is proposed, confirmed or retried")
    func flagOffAcceptsNoWork() async throws {
        let model = makeModel()
        model.propose(Self.kiteTask)
        #expect(model.showingConfirmation)

        flag.set(false)
        await model.confirm()
        #expect(model.issue == TaskHandoffUIModel.offMessage)
        await model.refresh()
        #expect(model.items.isEmpty)

        var failed = HandoffTask(tool: .codex, request: "Invented failed task")
        failed.state = .failed
        await model.retry(failed)
        await model.refresh()
        #expect(model.items.isEmpty)

        model.cancelProposal()
        model.propose(Self.kiteTask)
        #expect(!model.showingConfirmation)
        #expect(model.proposal == nil)
        #expect(await runner.calls().isEmpty)
    }

    /// M1. A double Return, or a click that lands twice, queues the task once.
    @Test("confirming twice queues one task")
    func confirmIsIdempotent() async throws {
        let model = makeModel()
        model.propose(Self.kiteTask)

        async let first: Void = model.confirm()
        async let second: Void = model.confirm()
        _ = await (first, second)
        await model.confirm()

        #expect(await eventually { model.items.first?.state == .done })
        #expect(model.items.count == 1)
        #expect(model.items.first?.request == Self.kiteTask.request)
        #expect(model.proposal == nil)
        #expect(!model.showingConfirmation)
        #expect(!model.isConfirming)
        #expect(await runner.calls().count == 1)
    }

    /// M1. The text on screen is the text that is sent.
    @Test("a task spoken while the sheet is open does not replace the one shown")
    func proposalIsFrozenWhileShown() async throws {
        let model = makeModel()
        model.propose(Self.kiteTask)
        model.propose(HandoffProposal(tool: .codex, request: "Invented second task"))

        #expect(model.proposal == Self.shownKiteTask)
        #expect(model.issue == TaskHandoffUIModel.busyMessage)

        await model.confirm()
        #expect(await eventually { model.items.first?.state == .done })
        #expect(model.items.map(\.request) == [Self.kiteTask.request])
    }

    /// Finding 4. Cancel lands while the queue is being made ready: the task must not be queued.
    @Test("cancelling while the task is on its way to the queue queues nothing")
    func cancelDuringConfirmQueuesNothing() async throws {
        let model = makeModel()
        model.propose(Self.kiteTask)
        whileReadying = { model.cancelProposal() }

        await model.confirm()
        await model.refresh()

        #expect(model.items.isEmpty)
        #expect(!model.showingConfirmation)
        #expect(model.proposal == nil)
        #expect(await runner.calls().isEmpty)
    }

    /// Finding 4. The same words in a sheet opened afterwards are a different sheet: the earlier click does not count for it.
    @Test("a click on a cancelled sheet does not queue the same words shown again")
    func confirmIsForTheSheetThatWasClicked() async throws {
        let model = makeModel()
        model.propose(Self.kiteTask)
        whileReadying = {
            model.cancelProposal()
            model.propose(Self.kiteTask)
        }

        await model.confirm()
        await model.refresh()

        #expect(model.items.isEmpty)
        #expect(model.proposal == Self.shownKiteTask)
        #expect(model.showingConfirmation)
        #expect(await runner.calls().isEmpty)

        // A click on the sheet now showing does queue it.
        whileReadying = nil
        await model.confirm()
        #expect(await eventually { model.items.first?.state == .done })
        #expect(model.items.count == 1)
    }

    @Test("closing the sheet while a click is on its way cancels that click")
    func closingDuringConfirmQueuesNothing() async throws {
        let model = makeModel()
        model.propose(Self.kiteTask)
        whileReadying = {
            model.showingConfirmation = false
            model.confirmationClosed()
        }

        await model.confirm()
        await model.refresh()

        #expect(model.items.isEmpty)
        #expect(model.proposal == nil)
    }

    /// Finding 9. The sheet names the file that will be run.
    @Test("the sheet shows where the tool was found")
    func proposalShowsTheToolPath() {
        let model = makeModel()
        #expect(model.proposal == nil)
        model.propose(Self.kiteTask)
        #expect(model.proposal?.executable == "/opt/invented/bin/codex")
    }

    /// Follow-up 1. Another codex turns up earlier in the search after the sheet opened: the task
    /// still carries the file the sheet showed. That file is held in memory, never in the saved list.
    @Test("the file shown on the sheet is the file the task runs, whatever a later search finds")
    func confirmedToolIsTheOneRun() async throws {
        let model = makeModel()
        model.propose(Self.kiteTask)
        toolFound = "/opt/invented/earlier/codex"

        await model.confirm()
        #expect(await eventually { model.items.first?.state == .done })

        #expect(model.items.first?.executable == "/opt/invented/bin/codex")
        #expect(await runner.toolsAskedFor() == ["/opt/invented/bin/codex"])
        let saved = try String(contentsOf: root.appendingPathComponent("index.json"), encoding: .utf8)
        #expect(saved.contains("Invented task about paper kites"))
        #expect(!saved.contains("/opt/invented"))
    }

    @Test("a tool that changed since the confirm fails the task with what to do")
    func changedToolSaysWhatToDo() async throws {
        await runner.fail(with: HandoffError.toolChanged)
        let model = makeModel()
        model.propose(Self.kiteTask)
        await model.confirm()
        #expect(await eventually { model.items.first?.state == .failed })
        #expect(model.items.first?.failure == "Codex has moved or changed since you confirmed. Queue the task again.")
    }

    @Test("with no tool found the sheet cannot queue")
    func noToolNoQueue() async throws {
        toolFound = nil
        let model = makeModel()
        model.propose(Self.kiteTask)
        #expect(model.proposal?.executable == nil)

        // Found a moment later: the sheet said not found, so this click still queues nothing.
        toolFound = "/opt/invented/bin/codex"
        await model.confirm()

        #expect(model.issue == "Codex was not found on this Mac.")
        #expect(model.showingConfirmation)
        #expect(queuesMade == 0)
        #expect(await runner.calls().isEmpty)
    }

    /// The seam the Privacy pane reads for its "Clear background tasks" row.
    @Test("the clear row is offered with the flag on, or with it off while anything is saved")
    func clearRowVisibility() async throws {
        let model = makeModel()
        #expect(model.offersClear())

        flag.set(false)
        #expect(!model.offersClear())
        // Asking made neither the queue nor the folder.
        #expect(queuesMade == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // A waiting task counts, and so does a list that could not be read.
        try save([HandoffTask(tool: .codex, request: "Invented waiting task")])
        #expect(model.offersClear())
        try Data("invalid".utf8).write(to: root.appendingPathComponent("index.json"))
        #expect(model.offersClear())
        #expect(queuesMade == 0)

        // With the flag still off the row's action removes it all, and the row goes.
        await model.clearTasks()
        #expect(model.items.isEmpty)
        #expect(model.notice == nil)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("index.corrupt-") })
        #expect(!model.offersClear())
    }

    @Test("closing the sheet clears the task, and the next one is shown")
    func closingTheSheetAllowsTheNextProposal() {
        let model = makeModel()
        model.propose(Self.kiteTask)
        // Escape or a click outside: the binding goes false, then the sheet reports it closed.
        model.showingConfirmation = false
        model.confirmationClosed()
        #expect(model.proposal == nil)

        let next = HandoffProposal(tool: .codex, request: "Invented next task")
        model.propose(next)
        #expect(model.proposal?.request == next.request)
        #expect(model.showingConfirmation)
        #expect(model.issue == nil)
    }

    @Test("a session that never used tasks has no queue to stop at quit")
    func liveQueueOnlyAfterUse() async {
        let model = makeModel()
        #expect(!model.hasLiveQueue)
        await model.refresh()
        #expect(model.hasLiveQueue)
        await model.shutdown()
    }

    @Test("Copy result marks the clipboard write for history managers to skip")
    func copyResultIsMarkedTransient() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.handoff.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let paster = ClipboardPaster(pasteboard: pasteboard, postKey: { _, _ in true })
        let model = makeModel()

        model.copyResult("Invented result about paper kites", using: paster)

        #expect(pasteboard.string(forType: .string) == "Invented result about paper kites")
        let types = pasteboard.pasteboardItems?.first?.types ?? []
        #expect(types.contains(ClipboardPaster.transientType))
        #expect(types.contains(ClipboardPaster.autoGeneratedType))
    }
}
