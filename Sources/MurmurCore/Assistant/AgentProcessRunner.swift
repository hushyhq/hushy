import Darwin
import Foundation
import Synchronization

/// Runs one `AgentInvocation` as a child process — `Process` with an executable path and an
/// argument array, never a shell — and streams its stdout line by line.
///
/// - The message is written to stdin, which is then closed.
/// - A timeout terminates the child (SIGTERM, then SIGKILL after a grace period) and ends the
///   stream with `AgentChatError.timedOut`.
/// - Cancelling the consuming task terminates the child the same way.
/// - A non-zero exit ends the stream with `AgentChatError.exited`, carrying the tail of stderr.
public struct AgentProcessRunner: Sendable {
    public var timeout: Duration
    /// How long a terminated child gets to exit before SIGKILL.
    public var killGrace: Duration
    public var maxOutputBytes: Int?
    /// Opt-in, off for the chat. The child is started as the leader of a new process group
    /// (`ProcessGroupSpawn`, not `Process`) and a stop signals the whole group: SIGTERM, then
    /// SIGKILL after `killGrace`, so helpers the tool started are stopped with it.
    public var ownsProcessGroup: Bool
    /// Sees every raw stdout line before it is parsed. A diagnostic tap: the live integration
    /// test uses it to capture real CLI output as fixtures. Nil in the app.
    public var rawLineTap: (@Sendable (String) -> Void)?

    public init(
        timeout: Duration = .seconds(120), killGrace: Duration = .seconds(2), maxOutputBytes: Int? = nil,
        ownsProcessGroup: Bool = false, rawLineTap: (@Sendable (String) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.killGrace = killGrace
        self.maxOutputBytes = maxOutputBytes
        self.ownsProcessGroup = ownsProcessGroup
        self.rawLineTap = rawLineTap
    }

    /// All of stdout, once the child has exited. Unlike `lines`, whose stream ends the moment its
    /// consumer is cancelled, cancelling the caller here stops the child and still waits for it to
    /// be gone, then throws `CancellationError`. A queue that must not leave a child behind on
    /// cancel or quit uses this. `onSpawn` is told the child's process id as soon as it exists.
    public func output(
        for invocation: AgentInvocation,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        onSpawn: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let child = ChildProcess(invocation: invocation, environment: invocation.environment(from: baseEnvironment),
                                 maxOutputBytes: maxOutputBytes, ownsProcessGroup: ownsProcessGroup, onSpawn: onSpawn)
        let timeout = timeout
        let killGrace = killGrace
        let tap = rawLineTap
        // Neither task is cancelled with the caller: the child is told to stop and both run to its exit.
        let work = Task.detached {
            await child.run(timeout: timeout, killGrace: killGrace, continuation: continuation)
        }
        let collected = Task.detached { () throws -> String in
            var text = ""
            for try await line in stream {
                tap?(line)
                text += line + "\n"
            }
            return text
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            child.stop(reason: .cancelled, killGrace: killGrace)
        }
        let text = try await collected.value
        try Task.checkCancellation()
        return text
    }

    public func lines(
        for invocation: AgentInvocation,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AsyncThrowingStream<String, Error> {
        let raw = childLines(for: invocation, baseEnvironment: baseEnvironment)
        guard let tap = rawLineTap else { return raw }
        return AsyncThrowingStream { continuation in
            let forward = Task {
                do {
                    for try await line in raw {
                        tap(line)
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in forward.cancel() }
        }
    }

    private func childLines(
        for invocation: AgentInvocation, baseEnvironment: [String: String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let child = ChildProcess(invocation: invocation, environment: invocation.environment(from: baseEnvironment),
                                     maxOutputBytes: maxOutputBytes, ownsProcessGroup: ownsProcessGroup)
            let timeout = timeout
            let killGrace = killGrace
            let work = Task.detached {
                await child.run(timeout: timeout, killGrace: killGrace, continuation: continuation)
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    child.stop(reason: .cancelled, killGrace: killGrace)
                }
                work.cancel()
            }
        }
    }
}

/// One child process and the bookkeeping to stop it exactly once, from whichever of timeout,
/// cancellation or normal exit happens first. `Process` isn't `Sendable`; every access to it
/// after launch goes through `stop`, which only calls thread-safe `Process`/`kill` APIs.
private final class ChildProcess: @unchecked Sendable {
    enum StopReason { case timedOut, cancelled, outputTooLarge }

    private struct StopState {
        var reason: StopReason?
        var isLaunched = false
        /// The process group id, only for a child that leads its own group.
        var group: pid_t?
    }

    private let process = Process()
    private let invocation: AgentInvocation
    private let environment: [String: String]
    private let maxOutputBytes: Int?
    private let ownsProcessGroup: Bool
    private let onSpawn: (@Sendable (pid_t) -> Void)?
    private let stopState = Mutex(StopState())

    init(
        invocation: AgentInvocation, environment: [String: String], maxOutputBytes: Int?, ownsProcessGroup: Bool,
        onSpawn: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.maxOutputBytes = maxOutputBytes
        self.invocation = invocation
        self.environment = environment
        self.ownsProcessGroup = ownsProcessGroup
        self.onSpawn = onSpawn
    }

    func run(timeout: Duration, killGrace: Duration, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        let (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream()
        // Stopped before anything started: there is nothing to launch.
        guard stopState.withLock({ $0.reason == nil }) else {
            continuation.finish()
            return
        }

        do {
            if ownsProcessGroup {
                try launchInOwnGroup(stdin: stdin, stdout: stdout, stderr: stderr, exit: exitContinuation)
            } else {
                try launchWithProcess(stdin: stdin, stdout: stdout, stderr: stderr, exit: exitContinuation)
            }
        } catch let failure as ProcessGroupSpawn.Failure {
            continuation.finish(throwing: AgentChatError.launchFailed(String(cString: strerror(failure.code))))
            return
        } catch {
            continuation.finish(throwing: AgentChatError.launchFailed(error.localizedDescription))
            return
        }
        // A stop that raced the launch found nothing to signal; it is delivered now.
        let stopWasRequested = stopState.withLock { state -> Bool in
            state.isLaunched = true
            return state.reason != nil
        }
        if stopWasRequested { signalStop(killGrace: killGrace) }

        let output = OutputCollector(continuation: continuation, maxOutputBytes: maxOutputBytes)
        // At end-of-file the handler fires again and again until it is removed, so each one removes itself.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if output.receiveStdout(data) { self.stop(reason: .outputTooLarge, killGrace: killGrace) }
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            output.receiveStderr(data)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        writeStdin(stdin)
        let timer = Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.stop(reason: .timedOut, killGrace: killGrace)
        }
        defer { timer.cancel() }

        var status: Int32 = 0
        for await code in exitStream { status = code }
        await stopGroupStragglers(killGrace: killGrace)
        // Wait for both pipes to reach EOF so the last stdout line and all of stderr (the exit
        // detail) are in before the handlers go. A grandchild that outlived the agent can hold the
        // pipes open forever, so the wait is bounded and we then close them ourselves.
        for _ in 0..<40 where !output.reachedEOF {
            try? await Task.sleep(for: .milliseconds(25))
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        output.flush()
        let detail = output.stderrTail

        switch stopState.withLock({ $0.reason }) {
        case .timedOut:
            continuation.finish(throwing: AgentChatError.timedOut(seconds: Int(timeout.components.seconds)))
        case .cancelled:
            continuation.finish()
        case .outputTooLarge:
            continuation.finish(throwing: AgentChatError.outputTooLarge)
        case nil:
            if status == 0 {
                continuation.finish()
            } else if AgentChatError.looksLikeLoginProblem(detail) {
                continuation.finish(throwing: AgentChatError.notLoggedIn(invocation.agent))
            } else {
                continuation.finish(throwing: AgentChatError.exited(code: status, detail: detail))
            }
        }
    }

    private func launchWithProcess(
        stdin: Pipe, stdout: Pipe, stderr: Pipe, exit: AsyncStream<Int32>.Continuation
    ) throws {
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory, isDirectory: true)
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        process.terminationHandler = { finished in
            exit.yield(finished.terminationStatus)
            exit.finish()
        }
        try process.run()
        onSpawn?(process.processIdentifier)
    }

    private func launchInOwnGroup(
        stdin: Pipe, stdout: Pipe, stderr: Pipe, exit: AsyncStream<Int32>.Continuation
    ) throws {
        // The parent's copies of the child's ends must close either way, or end-of-file never arrives.
        defer {
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        let pid = try ProcessGroupSpawn.spawn(
            executable: invocation.executable, arguments: invocation.arguments, environment: environment,
            workingDirectory: invocation.workingDirectory,
            stdin: stdin.fileHandleForReading.fileDescriptor,
            stdout: stdout.fileHandleForWriting.fileDescriptor,
            stderr: stderr.fileHandleForWriting.fileDescriptor)
        stopState.withLock { $0.group = pid }
        onSpawn?(pid)
        Thread.detachNewThread {
            exit.yield(ProcessGroupSpawn.waitForExit(pid))
            exit.finish()
        }
    }

    /// Stops the child once: SIGTERM now, SIGKILL if it's still alive after `killGrace`.
    func stop(reason: StopReason, killGrace: Duration) {
        let shouldSignal = stopState.withLock { state -> Bool in
            guard state.reason == nil else { return false }
            state.reason = reason
            return state.isLaunched
        }
        if shouldSignal { signalStop(killGrace: killGrace) }
    }

    private func signalStop(killGrace: Duration) {
        if let group = stopState.withLock({ $0.group }) {
            ProcessGroupSpawn.signalGroup(group, SIGTERM)
            Task.detached {
                try? await Task.sleep(for: killGrace)
                ProcessGroupSpawn.signalGroup(group, SIGKILL)
            }
            return
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached { [weak self] in
            try? await Task.sleep(for: killGrace)
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    /// After a stop, the group leader can exit while processes it started ignore SIGTERM. They get
    /// the same grace, then SIGKILL, before the run is reported finished, so a quit that waits for
    /// this run leaves nothing behind. A run that ended by itself is left alone.
    private func stopGroupStragglers(killGrace: Duration) async {
        let state = stopState.withLock { $0 }
        guard state.reason != nil, let group = state.group, kill(-group, 0) == 0 else { return }
        // Not cancelled with this task: the grace is owed to the stragglers either way.
        await Task.detached { try? await Task.sleep(for: killGrace) }.value
        ProcessGroupSpawn.signalGroup(group, SIGKILL)
    }

    /// Writes the message and closes stdin. The write end is marked no-SIGPIPE so a child that
    /// exits without reading can't take the app down with it.
    private func writeStdin(_ pipe: Pipe) {
        let handle = pipe.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? handle.write(contentsOf: Data(invocation.stdin.utf8))
        try? handle.close()
    }
}

/// Splits stdout into lines as it arrives and keeps the tail of stderr. Called from the pipes'
/// readability handlers (a background queue), hence the lock.
private final class OutputCollector: Sendable {
    private struct State {
        var pending = Data()
        var stderr = Data()
        var stdoutBytes = 0
        var stdoutEOF = false
        var stderrEOF = false
    }

    private let state = Mutex(State())
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private static let stderrLimit = 4_096
    private let maxOutputBytes: Int?

    init(continuation: AsyncThrowingStream<String, Error>.Continuation, maxOutputBytes: Int?) {
        self.continuation = continuation
        self.maxOutputBytes = maxOutputBytes
    }

    /// Both pipes are drained. Each pipe's handler runs serially, so once its EOF is seen every
    /// earlier chunk from that pipe has already been recorded.
    var reachedEOF: Bool { state.withLock { $0.stdoutEOF && $0.stderrEOF } }

    func receiveStdout(_ data: Data) -> Bool {
        let (lines, exceeded) = state.withLock { state -> ([String], Bool) in
            guard !data.isEmpty else {
                state.stdoutEOF = true
                return ([], false)
            }
            state.stdoutBytes += data.count
            if let maxOutputBytes, state.stdoutBytes > maxOutputBytes {
                state.pending.removeAll()
                return ([], true)
            }
            state.pending.append(data)
            var lines: [String] = []
            while let newline = state.pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: state.pending[state.pending.startIndex..<newline], as: UTF8.self))
                state.pending.removeSubrange(state.pending.startIndex...newline)
            }
            return (lines, false)
        }
        for line in lines { continuation.yield(line) }
        return exceeded
    }

    func receiveStderr(_ data: Data) {
        state.withLock { state in
            guard !data.isEmpty else {
                state.stderrEOF = true
                return
            }
            state.stderr.append(data)
            if state.stderr.count > Self.stderrLimit { state.stderr.removeFirst(state.stderr.count - Self.stderrLimit) }
        }
    }

    /// Emits a final line that had no trailing newline.
    func flush() {
        let last = state.withLock { state -> String? in
            defer { state.pending.removeAll() }
            return state.pending.isEmpty ? nil : String(decoding: state.pending, as: UTF8.self)
        }
        if let last { continuation.yield(last) }
    }

    /// The last few hundred characters of stderr, trimmed — enough to explain a failure without
    /// pasting a stack trace into the chat.
    var stderrTail: String {
        let text = state.withLock { String(decoding: $0.stderr, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 400 ? "…" + String(text.suffix(400)) : text
    }
}
