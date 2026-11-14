import Darwin
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// What the runner saw of its working folder while it ran.
private struct WorkFolderSighting: Sendable, Equatable {
    var folder: URL
    var existed: Bool
    var mode: Int?
    var contents: [String]
}

/// An in-memory runner that records where it was asked to work. No test in this file starts a process.
private actor RecordingHandoffRunner: HandoffRunning {
    private var started: [UUID] = []
    private var seen: [WorkFolderSighting] = []
    private var gates: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var holding = false
    private var failure: (any Error)?
    private var child: HandoffChild?

    func calls() -> [UUID] { started }
    func sightings() -> [WorkFolderSighting] { seen }
    /// Every task waits inside `run` until `release`.
    func holdAll() { holding = true }
    func release(_ id: UUID) { gates.removeValue(forKey: id)?.resume() }
    func fail(with error: any Error) { failure = error }
    func report(_ child: HandoffChild) { self.child = child }

    func run(_ task: HandoffTask, in folder: URL, started report: @escaping @Sendable (HandoffChild) -> Void) async throws -> String {
        started.append(task.id)
        let files = FileManager.default
        let mode = (try? files.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
        seen.append(WorkFolderSighting(folder: folder, existed: files.fileExists(atPath: folder.path), mode: mode,
                                       contents: (try? files.contentsOfDirectory(atPath: folder.path)) ?? []))
        if let child { report(child) }
        if holding { await withCheckedContinuation { gates[task.id] = $0 } }
        if let failure { throw failure }
        return "Invented result for \(task.request)"
    }
}

private final class RecordingOrphanStopper: HandoffOrphanStopping {
    private let seen = Mutex<[HandoffChild]>([])
    var stopped: [HandoffChild] { seen.withLock { $0 } }
    func stop(_ child: HandoffChild) -> Bool {
        seen.withLock { $0.append(child) }
        return true
    }
}

private final class RefusalSwitch: Sendable {
    private let state = Mutex(false)
    var isOn: Bool { state.withLock { $0 } }
    func turnOn() { state.withLock { $0 = true } }
}

/// A temporary home for one test: the task store and, beside it, the work folders.
private struct Places {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-handoff-store-\(UUID().uuidString)")
    var root: URL { base.appendingPathComponent("data/Tasks") }
    var workRoot: URL { base.appendingPathComponent("caches/task-work") }
    var index: URL { root.appendingPathComponent("index.json") }

    func save(_ tasks: [HandoffTask]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(tasks).write(to: index)
    }

    func queue(
        _ runner: any HandoffRunning, isEnabled: @escaping @Sendable () -> Bool = { true },
        write: HandoffQueue.IndexWriter? = nil, orphans: any HandoffOrphanStopping = RecordingOrphanStopper()
    ) throws -> HandoffQueue {
        try HandoffQueue(root: root, workRoot: workRoot, runner: runner, isEnabled: isEnabled, write: write, orphans: orphans)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func eventually(within limit: Duration = .seconds(20), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func mode(of url: URL) throws -> Int {
    let value = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    return value.intValue
}

private func task(_ request: String, _ state: HandoffTask.State) -> HandoffTask {
    var item = HandoffTask(tool: .codex, request: request)
    item.state = state
    if state == .done { item.result = "Invented result" }
    return item
}

private let codexPath = "/opt/invented/bin/codex"

private let inventedChild = HandoffChild(pid: 4_242, startSeconds: 1_700_000_000, startMicroseconds: 123_456,
                                         executable: "/opt/invented/bin/codex", image: "/opt/invented/bin/codex")

/// What is kept on disk between sessions and what a new session does with it.
@Suite struct TaskHandoffStoreTests {
    /// Finding 7. A waiting entry in the index is not a click: it must not start by itself.
    @Test func aWaitingTaskReadFromDiskDoesNotStartByItself() async throws {
        let places = Places()
        defer { places.remove() }
        let saved = HandoffTask(tool: .codex, request: "Invented saved task")
        try places.save([saved])
        let runner = RecordingHandoffRunner()
        let queue = try places.queue(runner)

        await queue.start()
        try await Task.sleep(for: .milliseconds(200))
        await queue.start()

        #expect(await runner.calls().isEmpty)
        #expect(await queue.list().map(\.state) == [.waiting])
        #expect(await queue.restored() == [saved.id])
    }

    /// Second review, item 1. Whatever the index says, the queue starts only what this session queued.
    @Test func nothingReadFromDiskCanBeStartedAndNewTasksPassIt() async throws {
        let places = Places()
        defer { places.remove() }
        let saved = HandoffTask(tool: .codex, request: "Invented saved task")
        try places.save([saved, task("Invented failed task", .failed)])
        let runner = RecordingHandoffRunner()
        let queue = try places.queue(runner)

        let fresh = try await queue.enqueue(tool: .codex, request: "Invented new task", executable: codexPath)
        #expect(await eventually { await queue.list().last?.state == .done })
        await queue.start()
        try await Task.sleep(for: .milliseconds(100))

        #expect(await runner.calls() == [fresh.id])
        #expect(await queue.list().first?.state == .waiting)
        let overview = await queue.overview()
        #expect(overview.restored == Set(overview.items.dropLast().map(\.id)))
        #expect(!overview.restored.contains(fresh.id))
    }

    /// Second review, item 1. The tool's file is held in memory only: the index neither keeps it
    /// nor can supply one.
    @Test func theToolPathIsNeitherWrittenToTheIndexNorReadFromIt() async throws {
        let places = Places()
        defer { places.remove() }
        let runner = RecordingHandoffRunner()
        await runner.holdAll()
        let queue = try places.queue(runner)
        let item = try await queue.enqueue(tool: .codex, request: "Invented task", executable: "/opt/invented/shown/codex")
        #expect(item.executable == "/opt/invented/shown/codex")
        #expect(await eventually { await runner.calls() == [item.id] })
        #expect(await queue.list().first?.executable == "/opt/invented/shown/codex")
        #expect(try !String(contentsOf: places.index, encoding: .utf8).contains("shown"))

        // Something else writes a path into the saved list.
        let planted = #"[{"id":"\#(UUID().uuidString)","tool":"codex","request":"Invented planted task","state":"waiting","createdAt":0,"executable":"/opt/invented/planted/tool"}]"#
        let other = Places()
        defer { other.remove() }
        try FileManager.default.createDirectory(at: other.root, withIntermediateDirectories: true)
        try Data(planted.utf8).write(to: other.index)
        let reopened = try other.queue(RecordingHandoffRunner())
        let read = try #require(await reopened.list().first)
        #expect(read.request == "Invented planted task")
        #expect(read.executable == nil)
        await runner.release(item.id)
    }

    /// Finding 7. A file that cannot be read is set aside and the list starts empty.
    @Test func anUnreadableIndexIsSetAsideAndTheListStartsEmpty() async throws {
        let places = Places()
        defer { places.remove() }
        try FileManager.default.createDirectory(at: places.root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: places.index)
        // One from an earlier time is replaced, not added to.
        try Data("older".utf8).write(to: places.root.appendingPathComponent("index.corrupt-1.json"))

        let queue = try places.queue(RecordingHandoffRunner())

        #expect(queue.indexWasSetAside)
        #expect(await queue.list().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: places.root.path)
        let aside = names.filter { $0.hasPrefix("index.corrupt-") && $0.hasSuffix(".json") }
        #expect(aside.count == 1)
        let kept = try #require(aside.first)
        #expect(try String(contentsOf: places.root.appendingPathComponent(kept), encoding: .utf8) == "invalid")
        #expect(try mode(of: places.root.appendingPathComponent(kept)) == 0o600)
        #expect(try String(contentsOf: places.index, encoding: .utf8) == "[]")

        // The next session reads the fresh index and has nothing to report.
        let reopened = try places.queue(RecordingHandoffRunner())
        #expect(!reopened.indexWasSetAside)
    }

    /// Finding 5. A folder that already exists with wider access is narrowed.
    @Test func theTaskFolderIsOwnerOnlyEvenWhenItAlreadyExisted() async throws {
        let places = Places()
        defer { places.remove() }
        try FileManager.default.createDirectory(at: places.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        _ = try places.queue(RecordingHandoffRunner(), isEnabled: { false })
        #expect(try mode(of: places.root) == 0o700)
        #expect(try mode(of: places.index) == 0o600)
    }

    /// Second review, item 3. One action removes everything but a running task, and the set-aside list.
    @Test func clearingRemovesEveryTaskButTheRunningOneAndTheSetAsideList() async throws {
        let places = Places()
        defer { places.remove() }
        try places.save([task("Invented done task", .done), task("Invented failed task", .failed),
                         task("Invented left waiting task", .waiting), task("Invented cancelled task", .cancelled)])
        let aside = places.root.appendingPathComponent("index.corrupt-1.json")
        try Data("Invented unreadable list".utf8).write(to: aside)
        let runner = RecordingHandoffRunner()
        await runner.holdAll()
        let queue = try places.queue(runner)
        let running = try await queue.enqueue(tool: .codex, request: "Invented running task", executable: codexPath)
        let behind = try await queue.enqueue(tool: .codex, request: "Invented task in line", executable: codexPath)
        #expect(await eventually { await runner.calls() == [running.id] })
        #expect(await queue.overview().hasSetAsideIndex)

        try await queue.clear()

        #expect(await queue.list().map(\.id) == [running.id])
        #expect(!FileManager.default.fileExists(atPath: aside.path))
        #expect(await !queue.overview().hasSetAsideIndex)
        let onDisk = try String(contentsOf: places.index, encoding: .utf8)
        for gone in ["done", "failed", "left waiting", "cancelled", "in line"] {
            #expect(!onDisk.contains("Invented \(gone) task"))
        }
        // The task that was in line is gone for good: it does not start when the running one ends.
        await runner.release(running.id)
        #expect(await eventually { await queue.list().first?.state == .done })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await runner.calls() == [running.id])
        _ = behind
    }

    /// The Privacy pane asks this with the flag off; asking must leave the disk as it was.
    @Test func lookingForSomethingToClearOnlyReads() throws {
        let places = Places()
        defer { places.remove() }
        #expect(!HandoffQueue.storeHasClearableContent(in: places.root))
        #expect(!FileManager.default.fileExists(atPath: places.base.path))

        try places.save([task("Invented running task", .running)])
        #expect(!HandoffQueue.storeHasClearableContent(in: places.root))
        try places.save([task("Invented running task", .running), task("Invented waiting task", .waiting)])
        #expect(HandoffQueue.storeHasClearableContent(in: places.root))
        try places.save([])
        #expect(!HandoffQueue.storeHasClearableContent(in: places.root))

        // A list set aside earlier counts, and so does one that cannot be read; a look moves neither.
        try Data("older".utf8).write(to: places.root.appendingPathComponent("index.corrupt-1.json"))
        #expect(HandoffQueue.storeHasClearableContent(in: places.root))
        try FileManager.default.removeItem(at: places.root.appendingPathComponent("index.corrupt-1.json"))
        try Data("invalid".utf8).write(to: places.index)
        #expect(HandoffQueue.storeHasClearableContent(in: places.root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: places.root.path) == ["index.json"])
        #expect(try String(contentsOf: places.index, encoding: .utf8) == "invalid")
    }

    @Test func tasksThatCouldNotBeClearedOnDiskStayInTheList() async throws {
        let places = Places()
        defer { places.remove() }
        try places.save([task("Invented done task", .done)])
        struct SaveRefused: Error {}
        let refuse = RefusalSwitch()
        let queue = try places.queue(RecordingHandoffRunner(), write: { items, url in
            if refuse.isOn { throw SaveRefused() }
            try HandoffQueue.save(items, to: url)
        })
        refuse.turnOn()
        await #expect(throws: SaveRefused.self) { try await queue.clear() }
        #expect(await queue.list().map(\.request) == ["Invented done task"])
    }
}

/// Second review, item 6. What is read back is bounded, and damage costs as little as it can.
@Suite struct TaskHandoffIndexReadTests {
    @Test func oneEntryThatIsNotATaskIsLeftOutAndTheRestAreKept() async throws {
        let places = Places()
        defer { places.remove() }
        let good = task("Invented good task", .done)
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        try FileManager.default.createDirectory(at: places.root, withIntermediateDirectories: true)
        try Data(#"[{"id":"not-an-id","state":"done"},\#(goodJSON),42,{"tool":"codex"}]"#.utf8).write(to: places.index)

        let queue = try places.queue(RecordingHandoffRunner())

        #expect(!queue.indexWasSetAside)
        #expect(queue.droppedEntries == 3)
        #expect(await queue.list() == [good])
        // The rewritten index holds only what could be read.
        let saved = try JSONDecoder().decode([HandoffTask].self, from: Data(contentsOf: places.index))
        #expect(saved == [good])
    }

    @Test func anIndexOverTheSizeLimitIsNotReadAndIsSetAside() throws {
        let places = Places()
        defer { places.remove() }
        try places.save([task("Invented task with a long request " + String(repeating: "k", count: 2_000), .done)])
        guard case .tasks(let tasks, 0) = HandoffQueue.readIndex(in: places.root) else {
            Issue.record("the index should be readable under the real limit")
            return
        }
        #expect(tasks.count == 1)
        guard case .unreadable = HandoffQueue.readIndex(in: places.root, limit: 1_024) else {
            Issue.record("an index over the limit must not be read")
            return
        }

        let loaded = try HandoffQueue.loadIndex(in: places.root, limit: 1_024)

        #expect(loaded.items.isEmpty && loaded.setAside)
        #expect(!FileManager.default.fileExists(atPath: places.index.path))
        #expect(HandoffQueue.hasSetAsideIndex(in: places.root))
        #expect(HandoffQueue.maxIndexBytes == 32 * 1_048_576)
    }

    /// A link is never followed and a special file is never opened to read: both are set aside.
    @Test func anIndexThatIsALinkIsNotFollowed() async throws {
        let places = Places()
        defer { places.remove() }
        try FileManager.default.createDirectory(at: places.root, withIntermediateDirectories: true)
        let elsewhere = places.base.appendingPathComponent("elsewhere.json")
        try JSONEncoder().encode([task("Invented task from elsewhere", .waiting)]).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: places.index, withDestinationURL: elsewhere)

        let queue = try places.queue(RecordingHandoffRunner())

        #expect(queue.indexWasSetAside)
        #expect(await queue.list().isEmpty)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}

/// Finding 1. The tool works in an empty folder of its own, away from the app's data.
@Suite struct TaskHandoffWorkFolderTests {
    @Test func theToolWorksInAFreshEmptyOwnerOnlyFolderOutsideTheTaskStoreAndItIsRemoved() async throws {
        let places = Places()
        defer { places.remove() }
        let runner = RecordingHandoffRunner()
        let queue = try places.queue(runner)

        let item = try await queue.enqueue(tool: .codex, request: "Invented task", executable: codexPath)
        #expect(await eventually { await queue.list().first?.state == .done })

        let sighting = try #require(await runner.sightings().first)
        #expect(sighting.folder.path == places.workRoot.appendingPathComponent(item.id.uuidString).path)
        #expect(sighting.existed)
        #expect(sighting.mode == 0o700)
        #expect(sighting.contents.isEmpty)
        // Nothing of the store is at or above the folder.
        #expect(!sighting.folder.path.hasPrefix(places.root.deletingLastPathComponent().path + "/"))
        #expect(try mode(of: places.workRoot) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: sighting.folder.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: places.root.path) == ["index.json"])
    }

    @Test func theFolderIsRemovedWhenTheTaskTimesOut() async throws {
        let places = Places()
        defer { places.remove() }
        let runner = RecordingHandoffRunner()
        await runner.fail(with: AgentChatError.timedOut(seconds: 900))
        let queue = try places.queue(runner)

        _ = try await queue.enqueue(tool: .codex, request: "Invented task that times out", executable: codexPath)

        #expect(await eventually { await queue.list().first?.state == .failed })
        #expect(await queue.list().first?.failure == "Timed out")
        #expect(await runner.sightings().first?.existed == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: places.workRoot.path).isEmpty)
    }

    @Test func theFolderIsRemovedWhenTheTaskIsCancelled() async throws {
        let places = Places()
        defer { places.remove() }
        let runner = RecordingHandoffRunner()
        await runner.holdAll()
        let queue = try places.queue(runner)
        let item = try await queue.enqueue(tool: .codex, request: "Invented task to cancel", executable: codexPath)
        #expect(await eventually { await runner.calls() == [item.id] })
        #expect(try FileManager.default.contentsOfDirectory(atPath: places.workRoot.path) == [item.id.uuidString])

        try await queue.cancel(item.id)
        await runner.release(item.id)

        #expect(await eventually { await queue.list().first?.state == .cancelled })
        #expect(try FileManager.default.contentsOfDirectory(atPath: places.workRoot.path).isEmpty)
    }

    @Test(arguments: [
        (HandoffError.outdatedTool, "Update Codex to use background tasks."),
        (HandoffError.toolChanged, "Codex has moved or changed since you confirmed. Queue the task again."),
    ])
    func aToolThatCannotBeUsedIsReportedInPlainWords(error: HandoffError, sentence: String) async throws {
        let places = Places()
        defer { places.remove() }
        let runner = RecordingHandoffRunner()
        await runner.fail(with: error)
        let queue = try places.queue(runner)
        _ = try await queue.enqueue(tool: .codex, request: "Invented task", executable: codexPath)
        #expect(await eventually { await queue.list().first?.state == .failed })
        #expect(await queue.list().first?.failure == sentence)
    }

    @Test func foldersLeftByAnEarlierSessionAreRemovedAtLaunch() async throws {
        let places = Places()
        defer { places.remove() }
        let stale = places.workRoot.appendingPathComponent(UUID().uuidString)
        let other = places.workRoot.appendingPathComponent("not-a-task")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: stale.appendingPathComponent("left-behind"))

        _ = try places.queue(RecordingHandoffRunner(), isEnabled: { false })

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // Only folders named like a task are touched.
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func theDefaultWorkFolderIsOutsideTheDataFolderAndFollowsTheOverride() {
        let data = AppPaths.supportDirectory.standardizedFileURL.path
        let work = HandoffQueue.defaultWorkRoot.standardizedFileURL.path
        #expect(HandoffQueue.defaultWorkRoot.lastPathComponent == "task-work")
        #expect(work != data && !work.hasPrefix(data + "/") && !data.hasPrefix(work + "/"))
        #expect(HandoffQueue.defaultRoot.standardizedFileURL.path.hasPrefix(data + "/"))
        let environment = ProcessInfo.processInfo.environment
        if let override = [environment["HUSHY_HOME"], environment["MURMUR_HOME"]].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            let home = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            #expect(AppPaths.cachesDirectory.path == home.path + "-Caches")
        } else {
            #expect(AppPaths.cachesDirectory.path.hasSuffix("/Library/Caches/Hushy"))
        }
    }
}

/// Finding 6. The running tool's process is saved, and a launch after a crash hands it to the stopper.
@Suite struct TaskHandoffChildRecordTests {
    @Test func theRunningToolIsSavedWithTheTaskAndForgottenWhenItEnds() async throws {
        let places = Places()
        defer { places.remove() }
        let runner = RecordingHandoffRunner()
        await runner.report(inventedChild)
        await runner.holdAll()
        let queue = try places.queue(runner)

        let item = try await queue.enqueue(tool: .codex, request: "Invented task", executable: codexPath)
        #expect(await eventually { await queue.list().first?.child == inventedChild })
        let saved = try JSONDecoder().decode([HandoffTask].self, from: Data(contentsOf: places.index))
        #expect(saved.first?.child == inventedChild)
        #expect(saved.first?.state == .running)

        await runner.release(item.id)
        #expect(await eventually { await queue.list().first?.state == .done })
        #expect(await queue.list().first?.child == nil)
        let after = try JSONDecoder().decode([HandoffTask].self, from: Data(contentsOf: places.index))
        #expect(after.first?.child == nil)
    }

    @Test func aTaskLeftRunningHandsItsToolToTheStopperAndBecomesInterrupted() async throws {
        let places = Places()
        defer { places.remove() }
        var withTool = task("Invented task with a tool", .running)
        withTool.child = inventedChild
        // Saved before the process existed, or by a build that did not record it.
        let withoutTool = task("Invented task without a tool", .running)
        var done = task("Invented done task", .done)
        done.child = HandoffChild(pid: 77, startSeconds: 1, startMicroseconds: 1, executable: "/opt/invented/x", image: "/opt/invented/x")
        try places.save([withTool, withoutTool, done])
        let stopper = RecordingOrphanStopper()
        let runner = RecordingHandoffRunner()

        let queue = try places.queue(runner, orphans: stopper)

        // Only a task recorded as running, and only the process recorded with it.
        #expect(stopper.stopped == [inventedChild])
        let items = await queue.list()
        #expect(items.map(\.state) == [.interrupted, .interrupted, .done])
        #expect(items[0].child == nil && items[1].child == nil)
        #expect(await runner.calls().isEmpty)
    }

    @Test func anIndexSavedBeforeProcessesWereRecordedStillLoads() async throws {
        let places = Places()
        defer { places.remove() }
        try FileManager.default.createDirectory(at: places.root, withIntermediateDirectories: true)
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","tool":"codex","request":"Invented old task","state":"done","result":"Invented result","createdAt":0}]"#
        try Data(old.utf8).write(to: places.index)
        let queue = try places.queue(RecordingHandoffRunner())
        #expect(!queue.indexWasSetAside)
        #expect(await queue.list().map(\.id) == [id])
    }
}
