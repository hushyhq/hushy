import Foundation

public struct HandoffTask: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case waiting, running, done, failed, interrupted, cancelled }
    public let id: UUID
    public let tool: AgentKind
    public let request: String
    /// The tool's file the person was shown when they confirmed, as a real path. The task runs
    /// this file or fails; it is never looked up again. It lives in memory only (it is not one of
    /// the `CodingKeys`): a task read back from the index has none, so nothing written into the
    /// index can choose what is run.
    public private(set) var executable: String?
    public var state: State
    public var result: String?
    public var failure: String?
    public let createdAt: Date
    public var finishedAt: Date?
    /// The tool's process while the task runs; nil before it starts and once it has ended.
    public var child: HandoffChild?

    private enum CodingKeys: String, CodingKey {
        case id, tool, request, state, result, failure, createdAt, finishedAt, child
    }

    public init(
        id: UUID = UUID(), tool: AgentKind, request: String, executable: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.tool = tool
        self.request = request
        self.executable = executable
        self.state = .waiting
        self.createdAt = createdAt
    }
}

public protocol HandoffRunning: Sendable {
    /// Runs the task with `folder` as the tool's working folder. `started` is called once the
    /// tool's process exists.
    func run(_ task: HandoffTask, in folder: URL, started: @escaping @Sendable (HandoffChild) -> Void) async throws -> String
}

public enum HandoffError: Error, Equatable, Sendable {
    case unavailable, emptyResult, outputTooLarge
    /// The installed tool does not know an option Hushy depends on.
    case outdatedTool
    /// The file the person confirmed is gone or no longer passes the checks made when it was found.
    case toolChanged
    /// The `taskHandoff` flag is off: nothing may be queued or started.
    case disabled
}

/// A serial, durable queue. Call `start()` after creating it on launch.
/// Running work from a previous process becomes interrupted and is never resumed silently; if its
/// tool is still running, that tool is stopped (`HandoffOrphanStopping`).
///
/// Only a click in this session starts work. A task queued in this session (`enqueue`) starts in
/// turn, with the tool's file the person was shown. A task read from the index was queued by some
/// earlier session, or written there by something else: the queue has no way to start it. To run
/// it the person confirms its request again, which queues a new task (`TaskHandoffUIModel.reconfirm`).
///
/// The index and the results live in `root`, inside the app's data folder. The tool never works
/// there: each run gets its own empty folder under `workRoot` (`HandoffWorkFolders`).
///
/// `isEnabled` is the feature flag. It is read wherever work is accepted or started (`enqueue`,
/// every scheduling pass and again immediately before the runner is called), so with the flag off
/// no task starts, including tasks saved as waiting by an earlier session. Listing, cancelling and
/// deleting stay possible. A task that was already running when the flag went off is left to finish.
public actor HandoffQueue {
    public typealias IndexWriter = @Sendable ([HandoffTask], URL) throws -> Void
    public static let maxRequestBytes = 16_384
    public static let maxResultBytes = 1_048_576
    public static var defaultRoot: URL { AppPaths.supportDirectory.appendingPathComponent("Tasks") }
    public static var defaultWorkRoot: URL { AppPaths.cachesDirectory.appendingPathComponent("task-work") }

    /// The list, which of its tasks an earlier session left, and whether an unreadable index is set aside.
    public struct Overview: Sendable {
        public var items: [HandoffTask]
        public var restored: Set<UUID>
        public var hasSetAsideIndex: Bool
    }

    /// The saved index could not be read when this queue was made; it was set aside and the list started empty.
    public nonisolated let indexWasSetAside: Bool
    /// Entries of the saved index that were not tasks and were left out.
    public nonisolated let droppedEntries: Int
    private let root: URL
    private let work: HandoffWorkFolders
    private let runner: any HandoffRunning
    private let isEnabled: @Sendable () -> Bool
    private let write: IndexWriter
    private var items: [HandoffTask]
    /// Tasks a click in this session queued. Only these can start. Never saved.
    private var queuedHere: Set<UUID> = []
    private var worker: Task<Void, Never>?
    private var shuttingDown = false
    public var onFinish: (@Sendable (HandoffTask) -> Void)?

    /// `write` replaces how the index is saved; tests use it to make saving fail.
    public init(
        root: URL = HandoffQueue.defaultRoot, workRoot: URL = HandoffQueue.defaultWorkRoot,
        runner: any HandoffRunning, isEnabled: @escaping @Sendable () -> Bool = { FeatureFlags.taskHandoff },
        onFinish: (@Sendable (HandoffTask) -> Void)? = nil, write: IndexWriter? = nil,
        orphans: any HandoffOrphanStopping = HandoffOrphanStopper()
    ) throws {
        self.root = root
        let work = HandoffWorkFolders(root: workRoot)
        self.work = work
        self.runner = runner
        self.isEnabled = isEnabled
        self.onFinish = onFinish
        let write = write ?? { try HandoffQueue.save($0, to: $1) }
        self.write = write
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The attributes above apply only to a folder made just now.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let loaded = try Self.loadIndex(in: root)
        indexWasSetAside = loaded.setAside
        droppedEntries = loaded.dropped
        var saved = loaded.items
        for position in saved.indices where saved[position].state == .running {
            // The Hushy that started this is gone. Its tool may not be.
            if let child = saved[position].child { orphans.stop(child) }
            saved[position].child = nil
            saved[position].state = .interrupted
            saved[position].finishedAt = Date()
        }
        work.sweep()
        self.items = saved
        try write(saved, root.appendingPathComponent(Self.indexName))
    }

    public func list() -> [HandoffTask] { items }

    public func overview() -> Overview {
        Overview(items: items, restored: restored(), hasSetAsideIndex: Self.hasSetAsideIndex(in: root))
    }

    /// Tasks an earlier session left in the index. None of them can start or be retried as it stands.
    public func restored() -> Set<UUID> {
        Set(items.map(\.id)).subtracting(queuedHere)
    }

    public func setOnFinish(_ callback: @escaping @Sendable (HandoffTask) -> Void) { onFinish = callback }

    /// `executable` is the tool's file the person was shown; the task will run that file only.
    public func enqueue(tool: AgentKind, request: String, executable: String?) throws -> HandoffTask {
        guard isEnabled() else { throw HandoffError.disabled }
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maxRequestBytes else { throw HandoffError.unavailable }
        let item = HandoffTask(tool: tool, request: trimmed, executable: executable)
        items.append(item)
        do { try persist() } catch {
            // A task that could not be saved is not queued: it would vanish on the next launch.
            items.removeAll { $0.id == item.id }
            throw error
        }
        queuedHere.insert(item.id)
        schedule()
        return item
    }

    /// Starts the next waiting task if nothing is running and the flag is on. Safe to call again.
    public func start() { schedule() }

    /// Whether a task is running right now.
    public func isRunning() -> Bool { worker != nil }

    /// Normal quit waits for the child to stop and for its interrupted state to be saved.
    public func stopAndWait() async {
        shuttingDown = true
        let runningID = items.first(where: { $0.state == .running })?.id
        let running = worker
        running?.cancel()
        await running?.value
        guard let runningID, items.first(where: { $0.id == runningID })?.state == .cancelled else { return }
        // Cancellation caused by app quit is an interruption, not a person's cancel.
        update(runningID) { $0.state = .interrupted }
        try? persist()
    }

    public func cancel(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.state {
        case .waiting:
            update(id) {
                $0.state = .cancelled
                $0.finishedAt = Date()
            }
            try persist()
        case .running:
            worker?.cancel()
        default: break
        }
    }

    public func delete(_ id: UUID) throws {
        guard let position = items.firstIndex(where: { $0.id == id }), items[position].state != .running else { return }
        items.remove(at: position)
        queuedHere.remove(id)
        try persist()
        // Builds before the work folder moved made one here per task.
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Removes every task except one that is running, with its request and result, and any index
    /// that was set aside as unreadable. A waiting task is removed without ever starting.
    public func clear() throws {
        let before = items
        items.removeAll { $0.state != .running }
        if items.count != before.count {
            do { try persist() } catch {
                // Not saved means not cleared: the list must not show them gone while the file keeps them.
                items = before
                throw error
            }
            for item in before where !items.contains(where: { $0.id == item.id }) {
                queuedHere.remove(item.id)
                try? FileManager.default.removeItem(at: root.appendingPathComponent(item.id.uuidString, isDirectory: true))
            }
        }
        Self.removeSetAsideFiles(in: root)
    }

    private func schedule() {
        guard !shuttingDown, worker == nil, isEnabled(),
              let next = items.first(where: { $0.state == .waiting && queuedHere.contains($0.id) }) else { return }
        worker = Task { await execute(next.id) }
    }

    /// Runs one task. Other calls (`delete`, `cancel`, `enqueue`) interleave at every `await`, so the
    /// array can shift under a running task: the item is found again by id each time it is touched,
    /// never through a position remembered across a suspension.
    private func execute(_ id: UUID) async {
        // Every way out frees the worker slot and looks for the next task, so one failure cannot stall the queue.
        defer {
            worker = nil
            schedule()
        }
        guard !shuttingDown, !Task.isCancelled, isEnabled() else { return }
        guard items.first(where: { $0.id == id })?.state == .waiting,
              let started = update(id, { $0.state = .running }) else { return }
        do { try persist() } catch {
            finish(id) {
                $0.state = .failed
                $0.failure = "Could not save task"
            }
            return
        }
        let outcome: Result<String, Error>
        do {
            outcome = .success(try await answer(for: started))
        } catch {
            outcome = .failure(error)
        }
        let wasCancelled = Task.isCancelled
        finish(id) { item in
            switch outcome {
            case .success(let answer):
                item.result = answer
                item.state = .done
            case .failure(let error):
                item.state = wasCancelled ? .cancelled : .failed
                item.failure = wasCancelled ? nil : Self.failureLabel(error)
            }
        }
    }

    private func answer(for task: HandoffTask) async throws -> String {
        // The last gate before any process: the flag may have changed since this task was scheduled.
        guard isEnabled() else { throw HandoffError.disabled }
        let folder = try work.make(for: task.id)
        // However the run ends (answer, failure, time limit, cancel), its folder goes.
        defer { work.remove(folder) }
        let id = task.id
        let answer = try await runner.run(task, in: folder) { [weak self] child in
            Task { await self?.record(child, for: id) }
        }
        try Task.checkCancellation()
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HandoffError.emptyResult }
        guard answer.utf8.count <= Self.maxResultBytes else { throw HandoffError.outputTooLarge }
        return answer
    }

    @discardableResult
    private func update(_ id: UUID, _ change: (inout HandoffTask) -> Void) -> HandoffTask? {
        guard let position = items.firstIndex(where: { $0.id == id }) else { return nil }
        change(&items[position])
        return items[position]
    }

    /// Saves which process is running the task, for a launch after a crash or a force-quit. If it
    /// cannot be saved the task runs on; only that later clean-up is lost.
    private func record(_ child: HandoffChild, for id: UUID) {
        guard items.first(where: { $0.id == id })?.state == .running else { return }
        update(id) { $0.child = child }
        try? persist()
    }

    /// Records how a task ended. A task removed in the meantime is left removed.
    private func finish(_ id: UUID, _ change: (inout HandoffTask) -> Void) {
        let finished = update(id) {
            change(&$0)
            $0.child = nil
            $0.finishedAt = Date()
        }
        guard let finished else { return }
        try? persist()
        onFinish?(finished)
    }

    private static func failureLabel(_ error: Error) -> String {
        switch error {
        case HandoffError.emptyResult: "No response"
        case HandoffError.outputTooLarge, AgentChatError.outputTooLarge: "Response exceeded 1 MB"
        case HandoffError.unavailable: "Tool unavailable"
        case HandoffError.outdatedTool: "Update Codex to use background tasks."
        case HandoffError.toolChanged: "Codex has moved or changed since you confirmed. Queue the task again."
        case HandoffError.disabled: "Background AI tasks are off"
        case AgentChatError.timedOut: "Timed out"
        case AgentChatError.notLoggedIn(let agent): "\(agent.title) is not signed in"
        default: "Tool stopped"
        }
    }

    private func persist() throws { try write(items, root.appendingPathComponent(Self.indexName)) }
}
