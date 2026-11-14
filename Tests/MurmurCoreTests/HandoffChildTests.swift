import Darwin
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Answers from a table that tests change as the invented process "exits" or is "replaced".
private final class TableInspector: ProcessInspecting {
    private let table = Mutex<[pid_t: ProcessFacts]>([:])
    func set(_ pid: pid_t, _ facts: ProcessFacts?) { table.withLock { $0[pid] = facts } }
    func facts(for pid: pid_t) -> ProcessFacts? { table.withLock { $0[pid] } }
}

private final class SignalLog: Sendable {
    private struct Sent: Equatable { var group: pid_t; var signal: Int32 }
    private let sent = Mutex<[Sent]>([])
    func record(_ group: pid_t, _ signal: Int32) { sent.withLock { $0.append(Sent(group: group, signal: signal)) } }
    func signals(to group: pid_t) -> [Int32] { sent.withLock { $0.filter { $0.group == group }.map(\.signal) } }
    var isEmpty: Bool { sent.withLock { $0.isEmpty } }
}

private func eventually(within limit: Duration = .seconds(20), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Finding 6. Whether a tool left behind by a Hushy that crashed or was force-quit is stopped.
/// The processes in the first suite are invented: a table of facts and a log of signals.
@Suite struct HandoffOrphanStopperTests {
    private static let child = HandoffChild(pid: 4_242, startSeconds: 1_700_000_000, startMicroseconds: 123_456,
                                            executable: "/opt/invented/bin/codex", image: "/opt/invented/Cellar/codex")
    /// The recorded process, orphaned: same start, still leading its group, parent is the system.
    private static let sameProcess = ProcessFacts(
        startSeconds: 1_700_000_000, startMicroseconds: 123_456, executable: "/opt/invented/Cellar/codex",
        arguments: ["/opt/invented/bin/codex", "exec"], parent: 1, group: 4_242)

    /// This "Hushy" is process 900 in group 800. `groupHasMembers` is what is left of the tool's group.
    private static func stopper(
        _ inspector: TableInspector, _ log: SignalLog, groupHasMembers: Bool = false
    ) -> HandoffOrphanStopper {
        HandoffOrphanStopper(inspector: inspector, signalGroup: { log.record($0, $1) }, groupExists: { _ in groupHasMembers },
                             killGrace: .milliseconds(50), ownProcess: 900, ownGroup: 800)
    }

    @Test func theSameProcessIsAskedToStopThenKilledIfItStays() async {
        let inspector = TableInspector(), log = SignalLog()
        inspector.set(4_242, Self.sameProcess)

        #expect(Self.stopper(inspector, log).stop(Self.child))

        #expect(log.signals(to: 4_242).first == SIGTERM)
        #expect(await eventually { log.signals(to: 4_242) == [SIGTERM, SIGKILL] })
    }

    @Test func aProcessThatLeavesWhenAskedIsNotSignalledAgain() async throws {
        let inspector = TableInspector(), log = SignalLog()
        inspector.set(4_242, Self.sameProcess)

        #expect(Self.stopper(inspector, log).stop(Self.child))
        inspector.set(4_242, nil)

        try await Task.sleep(for: .milliseconds(300))
        #expect(log.signals(to: 4_242) == [SIGTERM])
    }

    /// Second review, item 4. The leader left on the first signal but something it started did
    /// not: the group still has members, and a group keeps its id while it has any.
    @Test func whatTheLeaderLeftBehindInItsGroupIsKilled() async {
        let inspector = TableInspector(), log = SignalLog()
        inspector.set(4_242, Self.sameProcess)

        #expect(Self.stopper(inspector, log, groupHasMembers: true).stop(Self.child))
        inspector.set(4_242, nil)

        #expect(await eventually { log.signals(to: 4_242) == [SIGTERM, SIGKILL] })
    }

    /// Second review, item 4. A saved record naming Hushy itself, or the group Hushy is in, is
    /// refused before anything is looked up, even when every fact would match.
    @Test(arguments: [900, 800, 1, 0, -1] as [Int32])
    func hushyItselfItsOwnGroupAndTheSystemAreNeverSignalled(_ pid: Int32) async throws {
        let child = HandoffChild(pid: pid, startSeconds: 1_700_000_000, startMicroseconds: 123_456,
                                 executable: "/opt/invented/bin/codex", image: "/opt/invented/Cellar/codex")
        var facts = Self.sameProcess
        facts.group = pid
        let inspector = TableInspector(), log = SignalLog()
        inspector.set(pid, facts)
        if pid > 1 { #expect(child.isStillOurs(facts)) }

        #expect(!Self.stopper(inspector, log, groupHasMembers: true).stop(child))

        try await Task.sleep(for: .milliseconds(150))
        #expect(log.isEmpty)
    }

    @Test func theRealStopperKnowsThisProcessAndItsGroup() {
        let stopper = HandoffOrphanStopper()
        #expect(stopper.ownProcess == getpid())
        #expect(stopper.ownGroup == getpgrp())
        #expect(!stopper.groupExists(0) && !stopper.groupExists(1))
        #expect(stopper.groupExists(getpgrp()))
    }

    /// The id came round again within the grace: the second signal must not reach the newcomer.
    @Test func anIdReusedDuringTheGraceIsNotKilled() async throws {
        let inspector = TableInspector(), log = SignalLog()
        inspector.set(4_242, Self.sameProcess)

        #expect(Self.stopper(inspector, log, groupHasMembers: true).stop(Self.child))
        var newcomer = Self.sameProcess
        newcomer.startSeconds += 1
        inspector.set(4_242, newcomer)

        try await Task.sleep(for: .milliseconds(300))
        #expect(log.signals(to: 4_242) == [SIGTERM])
    }

    @Test func aProcessThatIsGoneIsNotSignalled() async throws {
        let inspector = TableInspector(), log = SignalLog()
        #expect(!Self.stopper(inspector, log).stop(Self.child))
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.isEmpty)
    }

    /// The id alone proves nothing: each of these is some other process that now has it.
    @Test(arguments: ["later start", "other microsecond", "other program", "not a group leader", "still has its Hushy"])
    func anIdThatNowBelongsToSomethingElseIsNotSignalled(_ difference: String) async throws {
        var facts = Self.sameProcess
        switch difference {
        case "later start": facts.startSeconds += 60
        case "other microsecond": facts.startMicroseconds += 1
        case "other program":
            facts.executable = "/usr/bin/invented-editor"
            facts.arguments = ["invented-editor", "notes.txt"]
        case "not a group leader": facts.group = 77
        default: facts.parent = 612
        }
        let inspector = TableInspector(), log = SignalLog()
        inspector.set(4_242, facts)

        #expect(!Self.stopper(inspector, log).stop(Self.child))

        try await Task.sleep(for: .milliseconds(150))
        #expect(log.isEmpty)
    }

    /// A tool installed as a script runs inside its interpreter; the tool's own path is then an argument.
    @Test func aToolRunningInsideItsInterpreterIsRecognisedByItsArguments() {
        var facts = Self.sameProcess
        facts.executable = "/opt/invented/bin/node"
        facts.arguments = ["node", "/opt/invented/bin/codex", "exec", "--sandbox", "read-only"]
        #expect(Self.child.isStillOurs(facts))
        // The path appearing later, as something the program was merely told about, is not enough.
        facts.arguments = ["invented-editor", "--open", "--recent", "/opt/invented/bin/codex"]
        #expect(!Self.child.isStillOurs(facts))
    }
}

/// The real lookup, against this test process and harmless system binaries (`/bin/sh`, `/bin/sleep`).
@Suite("Hand-off process lookup (system binaries)", .serialized)
struct HandoffProcessInspectorTests {
    private static func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    @Test func thisProcessIsDescribedAsTheSystemKnowsIt() throws {
        let inspector = SystemProcessInspector()
        let facts = try #require(inspector.facts(for: getpid()))
        #expect(facts.parent == getppid())
        #expect(facts.group == getpgrp())
        #expect(facts.arguments == ProcessInfo.processInfo.arguments)
        #expect(facts.executable.hasPrefix("/"))
        #expect(facts.startSeconds > 0)
        // The start time is the identity: it must read the same every time.
        #expect(inspector.facts(for: getpid()) == facts)
        #expect(inspector.facts(for: 0) == nil)
        #expect(inspector.facts(for: 1) == nil)
    }

    /// A shell starts `sleep` as the leader of its own group and exits, which is the state a tool
    /// is in after its Hushy has gone. Nothing here is an agent tool.
    @Test func aRealOrphanedGroupLeaderIsFoundAndStoppedAndALookAlikeRecordIsNot() async throws {
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "set -m; /bin/sleep 120 >/dev/null 2>&1 & echo $!"]
        shell.currentDirectoryURL = FileManager.default.temporaryDirectory
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }

        let inspector = SystemProcessInspector()
        // Wait until the shell has gone and the forked child has become `sleep`.
        #expect(await eventually {
            guard let facts = inspector.facts(for: pid) else { return false }
            return facts.parent == 1 && facts.executable.hasSuffix("/sleep")
        })
        let child = try #require(HandoffChild.observed(pid: pid, executable: "/bin/sleep", inspector: inspector))
        let facts = try #require(inspector.facts(for: pid))
        #expect(facts.group == pid)
        #expect(facts.executable == child.image)
        #expect(child.isStillOurs(facts))

        let stopper = HandoffOrphanStopper(killGrace: .milliseconds(500))
        // The same id with another start time is a different process: left alone.
        let lookAlike = HandoffChild(pid: pid, startSeconds: child.startSeconds - 1, startMicroseconds: child.startMicroseconds,
                                     executable: child.executable, image: child.image)
        #expect(!stopper.stop(lookAlike))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!Self.isGone(pid))

        #expect(stopper.stop(child))
        #expect(await eventually { Self.isGone(pid) })
        #expect(inspector.facts(for: pid) == nil)
    }
}
