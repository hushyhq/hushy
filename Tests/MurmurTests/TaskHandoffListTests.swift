import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

/// In-memory stand-in for the Codex launcher. No test here starts a process.
private actor FakeHandoffRunner: HandoffRunning {
    private var started: [UUID] = []
    func calls() -> [UUID] { started }
    func run(_ task: HandoffTask, in folder: URL, started report: @escaping @Sendable (HandoffChild) -> Void) async throws -> String {
        started.append(task.id)
        return "Invented result"
    }
}

/// The task list: clearing, the notice after an unreadable index, what a new session does at
/// launch, and how much of a long result is drawn. Every queue lives in a temporary folder.
@Suite("Task hand-off list", .serialized)
@MainActor
final class TaskHandoffListTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-handoff-list-\(UUID().uuidString)")
    private let runner = FakeHandoffRunner()
    private var queuesMade = 0

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeModel(isEnabled: Bool = true, hasStore: Bool = false) -> TaskHandoffUIModel {
        TaskHandoffUIModel(
            isEnabled: { isEnabled }, locateTool: { nil }, hasStore: { hasStore }, hasClearableStore: { false },
            makeQueue: { [self] isEnabled, onFinish in
                queuesMade += 1
                return try HandoffQueue(root: root, workRoot: root.appendingPathComponent("work"), runner: runner,
                                        isEnabled: isEnabled, onFinish: onFinish)
            })
    }

    private func task(_ request: String, _ state: HandoffTask.State) -> HandoffTask {
        var item = HandoffTask(tool: .codex, request: request)
        item.state = state
        return item
    }

    private func save(_ tasks: [HandoffTask]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(tasks).write(to: root.appendingPathComponent("index.json"))
    }

    /// Finding 5, and the second review's item 3.
    @Test("Clear tasks asks first, then removes every task that is not running")
    func clearTasks() async throws {
        try save([task("Invented done task", .done), task("Invented waiting task", .waiting), task("Invented failed task", .failed)])
        let model = makeModel()
        await model.refresh()
        #expect(model.hasClearableTasks)

        model.confirmingClear = true
        #expect(model.items.count == 3)
        await model.clearTasks()

        #expect(model.items.isEmpty)
        #expect(!model.confirmingClear)
        #expect(!model.hasClearableTasks)
        #expect(try String(contentsOf: root.appendingPathComponent("index.json"), encoding: .utf8) == "[]")
        #expect(await runner.calls().isEmpty)
        #expect(TaskHandoffListView.clearQuestion
            == "Remove every task that is not running, with its result, and any saved task list that could not be read?")
    }

    @Test("Clear tasks also removes a task list that was set aside, and the notice about it")
    func clearRemovesTheSetAsideList() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("index.json"))
        let model = makeModel()
        await model.refresh()
        #expect(model.notice != nil)
        // Nothing in the list, but the set-aside file is still something to clear.
        #expect(model.items.isEmpty && model.hasSetAsideIndex && model.hasClearableTasks)

        await model.clearTasks()

        #expect(model.notice == nil)
        #expect(!model.hasSetAsideIndex && !model.hasClearableTasks)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix("index.corrupt-") })
    }

    /// Second review, item 6.
    @Test("a saved entry that cannot be read is left out, and the list says so")
    func droppedEntriesShowANotice() async throws {
        let good = String(decoding: try JSONEncoder().encode(task("Invented good task", .done)), as: UTF8.self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[\(good),{\"state\":\"done\"}]".utf8).write(to: root.appendingPathComponent("index.json"))
        let model = makeModel()

        await model.refresh()

        #expect(model.items.map(\.request) == ["Invented good task"])
        #expect(model.notice == "Some saved tasks could not be read and were left out.")
    }

    /// Finding 7.
    @Test("an unreadable task list is set aside and the list says so once")
    func unreadableIndexShowsANotice() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("index.json"))
        let model = makeModel()
        #expect(model.notice == nil)

        await model.refresh()

        #expect(model.items.isEmpty)
        #expect(model.issue == nil)
        #expect(model.notice == "The saved task list could not be read, so it was set aside. This list starts empty.")
    }

    /// Finding 6. With the flag off a store from an earlier session is still opened at launch, so a
    /// tool left running is stopped; a Mac that never used tasks is not touched.
    @Test("launch opens the queue when the flag is on or tasks were saved before, and starts nothing")
    func launch() async throws {
        let unused = makeModel(isEnabled: false, hasStore: false)
        unused.resumeAtLaunch()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!unused.hasLiveQueue)
        #expect(queuesMade == 0)

        var left = task("Invented task left running", .running)
        left.child = nil
        try save([left, task("Invented waiting task", .waiting)])
        let used = makeModel(isEnabled: false, hasStore: true)
        used.resumeAtLaunch()
        let deadline = ContinuousClock.now + .seconds(20)
        while used.items.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(used.hasLiveQueue)
        #expect(used.items.map(\.state) == [.interrupted, .waiting])
        #expect(await runner.calls().isEmpty)
        await used.shutdown()
    }

    /// Finding 10.
    @Test("a long result is drawn in part; a short one whole")
    func longResultIsDrawnInPart() {
        let short = String(repeating: "k", count: 20_000)
        #expect(TaskHandoffListView.visiblePart(of: short) == TaskHandoffListView.VisibleResult(text: short, isPartial: false))
        let long = String(repeating: "invented words ", count: 70_000)
        let shown = TaskHandoffListView.visiblePart(of: long)
        #expect(shown.isPartial)
        #expect(shown.text.count == 20_000)
        #expect(long.hasPrefix(shown.text))
        #expect(TaskHandoffListView.partialNote == "Showing the first part. Copy gives you all of it.")
        #expect(TaskHandoffListView.visiblePart(of: "") == TaskHandoffListView.VisibleResult(text: "", isPartial: false))
    }

    /// Finding 7.
    @Test("a waiting task left by an earlier session is labelled with what to do")
    func heldTaskLabel() {
        let waiting = task("Invented waiting task", .waiting)
        #expect(TaskHandoffListView.stateLabel(waiting, isHeld: true) == "Waiting. Click Run")
        #expect(TaskHandoffListView.stateLabel(waiting, isHeld: false) == "Waiting")
        #expect(TaskHandoffListView.stateLabel(task("Invented done task", .done), isHeld: false) == "Done")
    }

    /// Finding 2. The sheet must say exactly what these options allow.
    @Test("the confirm sheet says what Codex can and cannot do, and for how long")
    func disclosure() {
        #expect(TaskHandoffConfirmationView.disclosure
            == "Codex runs with your own login. It can read files on this Mac and send what it reads to OpenAI, but it cannot change files. It may keep running in the background for up to 15 minutes.")
        // The sentence is only true while these hold.
        #expect(CodexHandoffRunner.timeout == .seconds(900))
        #expect(CodexHandoffRunner.arguments.contains("read-only"))
        #expect(AgentKind.codex.provider == "OpenAI")
        #expect(TaskHandoffConfirmationView.toolLine("/opt/invented/bin/codex") == "Using /opt/invented/bin/codex")
        #expect(TaskHandoffConfirmationView.toolLine(nil) == "Codex was not found on this Mac.")
    }

    /// Finding 8. Without an app bundle the notification centre must not be touched at all.
    @Test("notification taps are answered only in a real app, and only when a task notification could exist")
    func notificationTaps() {
        #expect(!TaskHandoffNotifier.answersTaps(isBundled: false, isEnabled: true, hasTaskStore: true))
        #expect(!TaskHandoffNotifier.answersTaps(isBundled: true, isEnabled: false, hasTaskStore: false))
        #expect(TaskHandoffNotifier.answersTaps(isBundled: true, isEnabled: true, hasTaskStore: false))
        #expect(TaskHandoffNotifier.answersTaps(isBundled: true, isEnabled: false, hasTaskStore: true))
        // The test runner is not an app bundle, so this run never reaches the notification centre.
        #expect(!TaskHandoffNotifier.isAvailable)
    }
}
