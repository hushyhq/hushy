import Darwin
import Foundation
import Synchronization

/// Runs an external CLI (`claude` or `codex`) as a subprocess: argument array only, never a
/// shell, with a hard wall-clock timeout that kills the process and its whole process group if
/// exceeded. Both judge backends route through this so timeout/kill behavior is defined once
/// and is independently testable with a fake script standing in for the real CLI.
///
/// The child is started with `posix_spawn` in its own process group, so a timeout kill reaches
/// whatever the CLI itself spawned (a shell's `sleep`, a helper). Output is read by plain
/// threads that poll their pipe and stop at end-of-file; nothing waits on a cooperative-pool
/// thread, and nothing spins on a closed pipe (a `readabilityHandler` left installed on a pipe
/// at end-of-file fires again and again, which starved the rest of a busy test run).
enum CLIProcessRunner {
    struct Output {
        let stdout: Data
        let stderr: Data
        let terminationStatus: Int32
        let timedOut: Bool
    }

    enum RunError: LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): "Failed to launch judge CLI: \(message)"
            }
        }
    }

    /// Launches `executableURL` with `arguments` in `workingDirectory`, feeding `stdin` (if any)
    /// to the process's standard input, then closing it. Kills the process (sending `SIGKILL` to
    /// its whole process group, since these CLIs may spawn children) if it hasn't exited within
    /// `timeout` seconds, or if the calling task is cancelled. Never touches a shell: the
    /// arguments are an argv array, so no argument is ever interpreted by `/bin/sh`.
    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        stdin: Data?,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) async throws -> Output {
        let child = try SpawnedChild.launch(
            executable: executableURL.path, arguments: arguments, workingDirectory: workingDirectory.path,
            environment: environment ?? ProcessInfo.processInfo.environment)
        child.feed(stdin ?? Data())

        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            child.killForTimeout()
        }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: child.waitForExit()) }
            }
        } onCancel: {
            child.killGroup()
        }
        timer.cancel()

        let (stdout, stderr) = await child.collectOutput()
        return Output(stdout: stdout, stderr: stderr, terminationStatus: status, timedOut: child.didTimeOut)
    }
}

/// One child process: its pipes, its exit, and a kill that cannot hit a reused process id.
private final class SpawnedChild: @unchecked Sendable {
    private struct State {
        var exited = false
        var timedOut = false
    }

    private let pid: pid_t
    private let stdinFD: Int32
    private let stdout: PipeReader
    private let stderr: PipeReader
    private let state = Mutex(State())

    private init(pid: pid_t, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.stdinFD = stdinFD
        stdout = PipeReader(fd: stdoutFD)
        stderr = PipeReader(fd: stderrFD)
    }

    var didTimeOut: Bool { state.withLock { $0.timedOut } }

    static func launch(
        executable: String, arguments: [String], workingDirectory: String, environment: [String: String]
    ) throws -> SpawnedChild {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw CLIProcessRunner.RunError.launchFailed("could not create pipes (errno \(errno))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group (so the kill reaches children), and no descriptor but 0, 1, 2 inherited.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard result == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw CLIProcessRunner.RunError.launchFailed(String(cString: strerror(result)))
        }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        return SpawnedChild(pid: pid, stdinFD: inPipe[1], stdoutFD: outPipe[0], stderrFD: errPipe[0])
    }

    /// Writes `data` to the child's stdin and closes it, on a thread of its own: a child that does not read
    /// its input must not hold up the caller.
    func feed(_ data: Data) {
        let fd = stdinFD
        Thread.detachNewThread {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { break }
                }
            }
            close(fd)
        }
    }

    /// Blocks until the child is gone; call it off the cooperative pool. Returns its exit code, or the signal
    /// that ended it.
    func waitForExit() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        state.withLock { $0.exited = true }
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return status & 0x7f
    }

    func killForTimeout() {
        let alive = state.withLock { state -> Bool in
            guard !state.exited else { return false }
            state.timedOut = true
            return true
        }
        if alive { sendKill() }
    }

    func killGroup() {
        if !state.withLock({ $0.exited }) { sendKill() }
    }

    /// Everything the child wrote. The child has exited, so each reader stops as soon as its pipe has nothing
    /// more to give, even if a stray grandchild still holds the other end open.
    func collectOutput() async -> (Data, Data) {
        async let out = stdout.finishAndCollect()
        async let err = stderr.finishAndCollect()
        return await (out, err)
    }

    private func sendKill() {
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }
}

/// Reads one pipe on its own thread until end-of-file, or until told the child is gone and the pipe is empty.
private final class PipeReader: @unchecked Sendable {
    private struct State {
        var data = Data()
        var finished = false
        var childGone = false
        var waiter: CheckedContinuation<Data, Never>?
    }

    private let state = Mutex(State())

    init(fd: Int32) {
        Thread.detachNewThread { [self] in pump(fd) }
    }

    func finishAndCollect() async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let ready = state.withLock { state -> Data? in
                state.childGone = true
                if state.finished { return state.data }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func pump(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 && errno != EINTR { break }
            if ready <= 0 {
                if state.withLock({ $0.childGone }) { break }
                continue
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                state.withLock { $0.data.append(buffer, count: count) }
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        close(fd)
        let (waiter, data) = state.withLock { state -> (CheckedContinuation<Data, Never>?, Data) in
            state.finished = true
            defer { state.waiter = nil }
            return (state.waiter, state.data)
        }
        waiter?.resume(returning: data)
    }
}
