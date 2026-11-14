import Darwin
import Foundation

/// The tool's process, as the system described it when it started. Saved with a running task so
/// a later launch can stop the tool if Hushy was force-quit or crashed while it ran.
public struct HandoffChild: Codable, Equatable, Sendable {
    public let pid: Int32
    /// When the process started. A process id is handed out again after its process ends; the
    /// same id with the same start time is the same process.
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    /// The tool as it was launched, and the file that path led to once links were followed.
    public let executable: String
    public let image: String

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, executable: String, image: String) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executable = executable
        self.image = image
    }

    /// Describes a process that was just started from `executable`, or nil when it is already gone.
    public static func observed(pid: pid_t, executable: String, inspector: any ProcessInspecting) -> HandoffChild? {
        guard let facts = inspector.facts(for: pid) else { return nil }
        let image = realpath(executable, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        return HandoffChild(pid: pid, startSeconds: facts.startSeconds, startMicroseconds: facts.startMicroseconds,
                            executable: executable, image: image ?? executable)
    }

    /// Whether `facts` describe this same process, left behind by a Hushy that is gone.
    ///
    /// All four must hold: it started at the recorded moment; it still leads the process group
    /// Hushy gave it; its parent is the system (a tool whose Hushy is still running belongs to
    /// that Hushy); and it runs the recorded tool. A tool installed as a script runs inside its
    /// interpreter, so there the tool's path is looked for in the arguments just after the
    /// interpreter's name instead.
    public func isStillOurs(_ facts: ProcessFacts) -> Bool {
        guard facts.startSeconds == startSeconds, facts.startMicroseconds == startMicroseconds,
              facts.group == pid, facts.parent == 1 else { return false }
        return facts.executable == image || facts.arguments.dropFirst().prefix(2).contains(executable)
    }
}

/// What the system reports about one running process.
public struct ProcessFacts: Equatable, Sendable {
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    /// The file the process is running, links followed.
    public var executable: String
    public var arguments: [String]
    public var parent: pid_t
    public var group: pid_t

    public init(startSeconds: UInt64, startMicroseconds: UInt64, executable: String, arguments: [String],
                parent: pid_t, group: pid_t) {
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executable = executable
        self.arguments = arguments
        self.parent = parent
        self.group = group
    }
}

/// Looks a process up by id. Tests replace it; nothing else decides whether a process is signalled.
public protocol ProcessInspecting: Sendable {
    /// Nil when no such process exists or it cannot be read.
    func facts(for pid: pid_t) -> ProcessFacts?
}

public struct SystemProcessInspector: ProcessInspecting {
    private static let maxArguments = 4_096

    public init() {}

    public func facts(for pid: pid_t) -> ProcessFacts? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        return ProcessFacts(
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            executable: length > 0 ? String(cString: path) : "", arguments: Self.arguments(of: pid),
            parent: pid_t(bitPattern: info.pbi_ppid), group: pid_t(bitPattern: info.pbi_pgid))
    }

    /// The argument vector the process was started with. The system hands back one block: the
    /// argument count, the executable's path, padding, then the arguments, each ended by a zero.
    static func arguments(of pid: pid_t) -> [String] {
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var block = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &block, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let count = Int(block.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard count > 0, count <= maxArguments else { return [] }
        let afterPath = block[MemoryLayout<Int32>.size..<size].drop(while: { $0 != 0 })
        let strings = afterPath.drop(while: { $0 == 0 })
            .split(separator: 0, maxSplits: count, omittingEmptySubsequences: false)
        return strings.prefix(count).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Stops a tool an earlier Hushy left running.
public protocol HandoffOrphanStopping: Sendable {
    /// Signals the process group `child` led, but only if that process is still the same one.
    /// Returns whether anything was signalled.
    @discardableResult
    func stop(_ child: HandoffChild) -> Bool
}

/// SIGTERM to the group now; SIGKILL after `killGrace` if the same process is still there, or if
/// it has gone and left others behind in its group. A process id that now belongs to something
/// else, or to nothing, is never signalled, and neither is Hushy or the group Hushy is in,
/// whatever the saved record says.
public struct HandoffOrphanStopper: HandoffOrphanStopping {
    public var inspector: any ProcessInspecting
    public var signalGroup: @Sendable (pid_t, Int32) -> Void
    /// Whether a process group with this id still has a member.
    public var groupExists: @Sendable (pid_t) -> Bool
    public var killGrace: Duration
    public var ownProcess: pid_t
    public var ownGroup: pid_t

    public init(
        inspector: any ProcessInspecting = SystemProcessInspector(),
        signalGroup: (@Sendable (pid_t, Int32) -> Void)? = nil, groupExists: (@Sendable (pid_t) -> Bool)? = nil,
        killGrace: Duration = .seconds(2), ownProcess: pid_t = getpid(), ownGroup: pid_t = getpgrp()
    ) {
        self.inspector = inspector
        self.signalGroup = signalGroup ?? { ProcessGroupSpawn.signalGroup($0, $1) }
        self.groupExists = groupExists ?? { $0 > 1 && kill(-$0, 0) == 0 }
        self.killGrace = killGrace
        self.ownProcess = ownProcess
        self.ownGroup = ownGroup
    }

    @discardableResult
    public func stop(_ child: HandoffChild) -> Bool {
        guard child.pid > 1, child.pid != ownProcess, child.pid != ownGroup,
              inspector.facts(for: child.pid).map(child.isStillOurs) == true else { return false }
        signalGroup(child.pid, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: killGrace)
            if needsKilling(child) { signalGroup(child.pid, SIGKILL) }
        }
        return true
    }

    /// After the grace. The leader is looked at again, because once it has gone its id can be
    /// handed to another process: if some process has the id and it is not ours, nothing is sent.
    /// If no process has the id but its group still has members, they are what the leader
    /// started and ignored the first signal; a group keeps its id while it has members.
    private func needsKilling(_ child: HandoffChild) -> Bool {
        guard let facts = inspector.facts(for: child.pid) else { return groupExists(child.pid) }
        return child.isStillOurs(facts)
    }
}
