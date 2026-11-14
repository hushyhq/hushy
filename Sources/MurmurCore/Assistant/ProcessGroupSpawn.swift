import Darwin
import Foundation

/// Starts a child as the leader of a new process group, which Foundation's `Process` cannot do.
/// Everything the child starts stays in that group unless it moves itself out, so one signal to
/// the group reaches the helpers an agent tool launches as well as the tool.
///
/// Like `Process`: no shell, an executable path and an argument vector, only the three standard
/// descriptors inherited, default signal handling in the child.
enum ProcessGroupSpawn {
    struct Failure: Error, Equatable { let code: Int32 }

    /// Returns the child's process id, which is also its process group id.
    static func spawn(
        executable: String, arguments: [String], environment: [String: String], workingDirectory: String,
        stdin: Int32, stdout: Int32, stderr: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
        try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory))

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var mostSignals = sigset_t()
        sigfillset(&mostSignals)
        sigdelset(&mostSignals, SIGKILL)
        sigdelset(&mostSignals, SIGSTOP)
        try check(posix_spawnattr_setsigmask(&attributes, &noSignals))
        try check(posix_spawnattr_setsigdefault(&attributes, &mostSignals))
        // Group id 0 means "a new group led by the child".
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))

        let argv = cStrings([executable] + arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, argv, envp))
        return pid
    }

    /// Blocks until the child exits and returns what `Process.terminationStatus` would: the exit
    /// code, or the signal number when a signal ended it. -1 when the status cannot be read.
    static func waitForExit(_ pid: pid_t) -> Int32 {
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1 {
            if errno != EINTR { return -1 }
        }
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : signal
    }

    /// Signals every process in the group. A group that is already gone is not an error.
    static func signalGroup(_ group: pid_t, _ signal: Int32) {
        guard group > 1 else { return }
        _ = kill(-group, signal)
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw Failure(code: code) }
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }
}
