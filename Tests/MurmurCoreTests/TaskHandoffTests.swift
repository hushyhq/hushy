import Darwin
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Every runner here is an in-memory fake. No test in this file starts a process.
private actor FakeHandoffRunner: HandoffRunning {
    private var started: [UUID] = []
    private var held: Set<String> = []
    private var gates: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var failure: (any Error)?

    /// Tasks with this request wait inside `run` until `release`.
    func hold(_ request: String) { held.insert(request) }
    func fail(with error: any Error) { failure = error }
    func release(_ id: UUID) { gates.removeValue(forKey: id)?.resume() }
    func calls() -> [UUID] { started }

    func run(_ task: HandoffTask, in folder: URL, started report: @escaping @Sendable (HandoffChild) -> Void) async throws -> String {
        started.append(task.id)
        if held.contains(task.request) {
            await withCheckedContinuation { gates[task.id] = $0 }
        }
        if let failure { throw failure }
        return "Invented result for \(task.request)"
    }
}

/// A value shared with `@Sendable` closures.
private final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    var value: Value { state.withLock { $0 } }
    func set(_ value: Value) { state.withLock { $0 = value } }
    func change(_ body: @Sendable (inout Value) -> Void) { state.withLock { body(&$0) } }
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hushy-handoff-\(UUID().uuidString)")
}

private let codexPath = "/opt/invented/bin/codex"

/// Every queue here names its work folder, so no test reaches the default one.
private func workRoot(_ root: URL) -> URL { root.appendingPathComponent("work") }

/// Polls instead of sleeping a fixed time: a loaded test run can be seconds late.
private func eventually(within limit: Duration = .seconds(20), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func state(of id: UUID, in queue: HandoffQueue) async -> HandoffTask.State? {
    await queue.list().first(where: { $0.id == id })?.state
}

@Suite struct TaskHandoffTests {
    @Test func queueRunsInOrderAndPersists() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHandoffRunner()
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { true })
        let first = try await queue.enqueue(tool: .codex, request: "Invented task A", executable: codexPath)
        let second = try await queue.enqueue(tool: .codex, request: "Invented task B", executable: codexPath)
        #expect(await eventually { await queue.list().allSatisfy { $0.state == .done } })
        #expect(await fake.calls() == [first.id, second.id])
        let reopened = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { true })
        let saved = await reopened.list()
        #expect(saved.map(\.state) == [.done, .done])
        #expect(saved.first?.result == "Invented result for Invented task A")
    }

    @Test func relaunchInterruptsRunningWithoutRestart() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var interrupted = HandoffTask(tool: .codex, request: "Invented running task")
        interrupted.state = .running
        let waiting = HandoffTask(tool: .codex, request: "Invented waiting task")
        try JSONEncoder().encode([interrupted, waiting]).write(to: root.appendingPathComponent("index.json"))
        let fake = FakeHandoffRunner()
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { true })
        #expect(await queue.list().map(\.state) == [.interrupted, .waiting])
        #expect(await fake.calls().isEmpty)
    }

    @Test func indexIsOwnerOnlyAndLeavesNoTemporaryFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: FakeHandoffRunner(), isEnabled: { false })
        _ = await queue.list()
        let index = root.appendingPathComponent("index.json")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: index.appendingPathExtension("tmp").path))
    }

    @Test func signInFailureNamesCodex() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHandoffRunner()
        await fake.fail(with: AgentChatError.notLoggedIn(.codex))
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { true })
        let item = try await queue.enqueue(tool: .codex, request: "Invented sign-in task", executable: codexPath)
        #expect(await eventually { await state(of: item.id, in: queue) == .failed })
        #expect(await queue.list().first?.failure == "Codex is not signed in")
    }
}

@Suite struct TaskHandoffQueueSafetyTests {
    /// H1. The running task used to be reached through an array position remembered across the
    /// run; deleting an earlier task shifted the array under it.
    @Test func deletingAnEarlierTaskWhileAnotherRunsKeepsTheResultOnTheRightTask() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHandoffRunner()
        await fake.hold("Invented slow task")
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { true })
        let early = try await queue.enqueue(tool: .codex, request: "Invented early task", executable: codexPath)
        #expect(await eventually { await state(of: early.id, in: queue) == .done })
        let slow = try await queue.enqueue(tool: .codex, request: "Invented slow task", executable: codexPath)
        let later = try await queue.enqueue(tool: .codex, request: "Invented later task", executable: codexPath)
        #expect(await eventually { await fake.calls().contains(slow.id) })

        try await queue.delete(early.id)
        await fake.release(slow.id)

        #expect(await eventually { await state(of: later.id, in: queue) == .done })
        let items = await queue.list()
        #expect(items.map(\.id) == [slow.id, later.id])
        #expect(items.map(\.state) == [.done, .done])
        #expect(items.map(\.result) == ["Invented result for Invented slow task", "Invented result for Invented later task"])
        let saved = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { false })
        #expect(await saved.list().map(\.id) == [slow.id, later.id])
    }

    /// H3. A waiting task saved by an earlier session must not start while the flag is off.
    @Test func flagOffStartsNothingEvenForASavedWaitingTask() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = HandoffTask(tool: .codex, request: "Invented saved task")
        try JSONEncoder().encode([saved]).write(to: root.appendingPathComponent("index.json"))
        let fake = FakeHandoffRunner()
        let flag = Shared(false)
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { flag.value })

        await queue.start()
        await #expect(throws: HandoffError.disabled) {
            try await queue.enqueue(tool: .codex, request: "Invented new task", executable: codexPath)
        }
        await queue.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fake.calls().isEmpty)
        #expect(await queue.isRunning() == false)
        #expect(await queue.list().map(\.state) == [.waiting])

        // Turned on again, the saved task still does not start: the queue has no way to start it.
        flag.set(true)
        await queue.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.calls().isEmpty)
        #expect(await state(of: saved.id, in: queue) == .waiting)
        #expect(await queue.restored() == [saved.id])
    }

    @Test func flagOffStillAllowsCancelAndDelete() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = HandoffTask(tool: .codex, request: "Invented saved task one")
        let second = HandoffTask(tool: .codex, request: "Invented saved task two")
        try JSONEncoder().encode([first, second]).write(to: root.appendingPathComponent("index.json"))
        let fake = FakeHandoffRunner()
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { false })
        try await queue.cancel(first.id)
        try await queue.delete(second.id)
        #expect(await queue.list().map(\.state) == [.cancelled])
        #expect(await fake.calls().isEmpty)
    }

    /// H3. Turning the flag off while a task runs: that task finishes, the rest stay waiting.
    @Test func turningTheFlagOffStopsTheRemainingTasksFromStarting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHandoffRunner()
        await fake.hold("Invented first task")
        let flag = Shared(true)
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { flag.value })
        let first = try await queue.enqueue(tool: .codex, request: "Invented first task", executable: codexPath)
        let second = try await queue.enqueue(tool: .codex, request: "Invented second task", executable: codexPath)
        #expect(await eventually { await fake.calls().contains(first.id) })

        flag.set(false)
        await fake.release(first.id)

        #expect(await eventually { await state(of: first.id, in: queue) == .done })
        #expect(await eventually { await queue.isRunning() == false })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await state(of: second.id, in: queue) == .waiting)
        #expect(await fake.calls() == [first.id])
    }

    /// M5. A task whose running state cannot be saved fails without ever starting, and the queue moves on.
    @Test func aTaskThatCannotBeSavedFailsAndTheNextOneStillRuns() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHandoffRunner()
        await fake.hold("Invented first task")
        struct SaveRefused: Error {}
        let finished = Shared<[UUID]>([])
        let queue = try HandoffQueue(
            root: root, workRoot: workRoot(root), runner: fake, isEnabled: { true },
            onFinish: { item in finished.change { $0.append(item.id) } },
            write: { items, url in
                if items.contains(where: { $0.request == "Invented unlucky task" && $0.state == .running }) { throw SaveRefused() }
                try HandoffQueue.save(items, to: url)
            })
        let first = try await queue.enqueue(tool: .codex, request: "Invented first task", executable: codexPath)
        let unlucky = try await queue.enqueue(tool: .codex, request: "Invented unlucky task", executable: codexPath)
        let last = try await queue.enqueue(tool: .codex, request: "Invented last task", executable: codexPath)
        #expect(await eventually { await fake.calls().contains(first.id) })
        await fake.release(first.id)

        #expect(await eventually { await state(of: last.id, in: queue) == .done })
        let items = await queue.list()
        #expect(items.map(\.state) == [.done, .failed, .done])
        #expect(items[1].failure == "Could not save task")
        #expect(items[1].finishedAt != nil)
        #expect(await fake.calls() == [first.id, last.id])
        #expect(finished.value == [first.id, unlucky.id, last.id])
    }

    /// A task that could not be saved when confirmed is not left in memory to start later.
    @Test func aTaskThatCannotBeSavedWhenQueuedIsNotQueued() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHandoffRunner()
        struct SaveRefused: Error {}
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: fake, isEnabled: { true }, write: { items, url in
            if !items.isEmpty { throw SaveRefused() }
            try HandoffQueue.save(items, to: url)
        })
        await #expect(throws: SaveRefused.self) {
            try await queue.enqueue(tool: .codex, request: "Invented unsaved task", executable: codexPath)
        }
        await queue.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await queue.list().isEmpty)
        #expect(await fake.calls().isEmpty)
    }
}

private final class HandoffDecisionModel: LanguageModel {
    let json: String
    init(_ json: String) { self.json = json }
    var identifier: String { "handoff-fake" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec,
                 options: LanguageModelOptions) async throws -> String { json }
}

@Suite struct TaskHandoffIntentTests {
    @Test func modelSelectsHandoffAndCopiesTask() async {
        let model = HandoffDecisionModel(#"{"choice":"handoff","tool":"codex","request":"Invented kite study"}"#)
        let proposal = await TaskHandoffIntent.propose("Please hand this task to an AI tool", model: model)
        #expect(proposal == HandoffProposal(tool: .codex, request: "Invented kite study"))
    }

    @Test func unsupportedToolAndOtherChoiceAreNotProposed() async {
        let other = HandoffDecisionModel(#"{"choice":"other","tool":"codex","request":"Invented kite study"}"#)
        let unsupported = HandoffDecisionModel(#"{"choice":"handoff","tool":"other","request":"Invented kite study"}"#)
        #expect(await TaskHandoffIntent.propose("Invented utterance", model: other) == nil)
        #expect(await TaskHandoffIntent.propose("Invented utterance", model: unsupported) == nil)
    }
}

private actor WaitingHandoffRunner: HandoffRunning {
    func run(_ task: HandoffTask, in folder: URL, started: @escaping @Sendable (HandoffChild) -> Void) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "Invented answer"
    }
}

@Suite struct TaskHandoffRecoveryTests {
    @Test func cancellationStopsRunningTask() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: WaitingHandoffRunner(), isEnabled: { true })
        let item = try await queue.enqueue(tool: .codex, request: "Invented wait task", executable: codexPath)
        #expect(await eventually { await state(of: item.id, in: queue) == .running })
        try await queue.cancel(item.id)
        #expect(await eventually { await state(of: item.id, in: queue) == .cancelled })
    }
}

@Suite struct TaskHandoffQuitTests {
    @Test func quitInterruptsRunningWork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try HandoffQueue(root: root, workRoot: workRoot(root), runner: WaitingHandoffRunner(), isEnabled: { true })
        let long = try await queue.enqueue(tool: .codex, request: "Invented long task", executable: codexPath)
        _ = try await queue.enqueue(tool: .codex, request: "Invented waiting task", executable: codexPath)
        #expect(await eventually { await state(of: long.id, in: queue) == .running })
        await queue.stopAndWait()
        #expect(await queue.list().map(\.state) == [.interrupted, .waiting])
        let reopened = try HandoffQueue(root: root, workRoot: workRoot(root), runner: WaitingHandoffRunner(), isEnabled: { false })
        #expect(await reopened.list().map(\.state) == [.interrupted, .waiting])
    }
}
