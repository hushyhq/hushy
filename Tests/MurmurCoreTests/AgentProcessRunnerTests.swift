import Darwin
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

private final class ProcessIDLog: Sendable {
    private let ids = Mutex<[pid_t]>([])
    var all: [pid_t] { ids.withLock { $0 } }
    func add(_ pid: pid_t) { ids.withLock { $0.append(pid) } }
}

/// `AgentProcessRunner` against harmless system binaries only (`/bin/cat`, `/bin/sleep`, `/bin/sh`).
/// No agent tool is started and nothing leaves this Mac. Every child works in a temporary folder.
@Suite("Agent process runner (system binaries)", .serialized)
struct AgentProcessRunnerTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func invocation(
        _ executable: String, _ arguments: [String] = [], stdin: String = "", in folder: URL, agent: AgentKind = .claudeCode
    ) -> AgentInvocation {
        AgentInvocation(executable: executable, arguments: arguments, stdin: stdin, workingDirectory: folder.path, agent: agent)
    }

    private static func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    private static func eventually(within limit: Duration = .seconds(20), _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        return lines
    }

    private static func processID(in file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("output under the size limit comes back whole", arguments: [false, true])
    func echoesStandardInput(ownsProcessGroup: Bool) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(60), maxOutputBytes: 1_024, ownsProcessGroup: ownsProcessGroup)
        let invocation = Self.invocation("/bin/cat", stdin: "invented line one\ninvented line two", in: folder)
        #expect(try await Self.collect(runner.lines(for: invocation)) == ["invented line one", "invented line two"])
        #expect(try await runner.output(for: invocation) == "invented line one\ninvented line two\n")
    }

    @Test("output over the size limit stops the child and fails", arguments: [false, true])
    func sizeLimit(ownsProcessGroup: Bool) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(60), killGrace: .milliseconds(300), maxOutputBytes: 1_024,
                                        ownsProcessGroup: ownsProcessGroup)
        let large = String(repeating: "invented words\n", count: 400)
        let invocation = Self.invocation("/bin/cat", stdin: large, in: folder)
        await #expect(throws: AgentChatError.outputTooLarge) { _ = try await Self.collect(runner.lines(for: invocation)) }
        await #expect(throws: AgentChatError.outputTooLarge) { _ = try await runner.output(for: invocation) }
    }

    @Test("a child that outlives the time limit is stopped and reported as timed out", arguments: [false, true])
    func timeLimit(ownsProcessGroup: Bool) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .milliseconds(400), killGrace: .milliseconds(300),
                                        ownsProcessGroup: ownsProcessGroup)
        let invocation = Self.invocation("/bin/sleep", ["60"], in: folder)
        let started = ContinuousClock.now
        await #expect(throws: AgentChatError.timedOut(seconds: 0)) { _ = try await Self.collect(runner.lines(for: invocation)) }
        await #expect(throws: AgentChatError.timedOut(seconds: 0)) { _ = try await runner.output(for: invocation) }
        #expect(ContinuousClock.now - started < .seconds(40))
    }

    @Test("in its own group: working folder, environment, arguments and standard input all arrive")
    func groupLaunchPassesEverything() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(60), ownsProcessGroup: true)
        // Present in this test process only, to show the child gets the environment it was given and no more.
        setenv("HUSHY_RUNNER_TEST_PARENT_ONLY", "present", 1)
        defer { unsetenv("HUSHY_RUNNER_TEST_PARENT_ONLY") }
        let invocation = Self.invocation(
            "/bin/sh", ["-c", #"pwd -P; echo "$INVENTED|$1|${HUSHY_RUNNER_TEST_PARENT_ONLY:-unset}"; cat"#, "sh", "second argument"],
            stdin: "invented input", in: folder)
        let lines = try await Self.collect(runner.lines(
            for: invocation, baseEnvironment: ["INVENTED": "paper kite", "PATH": "/usr/bin:/bin"]))
        #expect(lines.count == 3)
        #expect(URL(fileURLWithPath: lines.first ?? "").resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        #expect(lines.dropFirst().first == "paper kite|second argument|unset")
        #expect(lines.last == "invented input")
    }

    @Test("in its own group: exit codes, launch failures and sign-in failures are reported")
    func groupLaunchReportsFailures() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(60), ownsProcessGroup: true)
        await #expect(throws: AgentChatError.exited(code: 3, detail: "invented failure")) {
            _ = try await runner.output(for: Self.invocation("/bin/sh", ["-c", "echo 'invented failure' >&2; exit 3"], in: folder))
        }
        await #expect(throws: AgentChatError.launchFailed(String(cString: strerror(ENOENT)))) {
            _ = try await runner.output(for: Self.invocation(folder.appendingPathComponent("missing").path, in: folder))
        }
        let signedOut = ["-c", "echo 'Not logged in' >&2; exit 1"]
        await #expect(throws: AgentChatError.notLoggedIn(.codex)) {
            _ = try await runner.output(for: Self.invocation("/bin/sh", signedOut, in: folder, agent: .codex))
        }
        await #expect(throws: AgentChatError.notLoggedIn(.claudeCode)) {
            _ = try await runner.output(for: Self.invocation("/bin/sh", signedOut, in: folder))
        }
    }

    /// M4. The shell starts a helper and waits for it. Stopping only the shell would leave the helper running.
    @Test("in its own group: cancelling stops the child and what it started, and waits for the child")
    func cancellingStopsTheWholeGroup() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(120), killGrace: .milliseconds(500), ownsProcessGroup: true)
        let invocation = Self.invocation(
            "/bin/sh", ["-c", "echo $$ > leader.pid; /bin/sleep 120 & echo $! > helper.pid; wait"], in: folder)
        let leaderFile = folder.appendingPathComponent("leader.pid")
        let helperFile = folder.appendingPathComponent("helper.pid")

        let run = Task { try await runner.output(for: invocation) }
        #expect(await Self.eventually { Self.processID(in: leaderFile) != nil && Self.processID(in: helperFile) != nil })
        let leader = try #require(Self.processID(in: leaderFile))
        let helper = try #require(Self.processID(in: helperFile))
        #expect(getpgid(helper) == leader)
        #expect(getpgid(leader) != getpgrp())

        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }

        // `output` returns only after the child has been collected, so it is gone the moment it throws.
        #expect(Self.isGone(leader))
        #expect(await Self.eventually { Self.isGone(helper) })
    }

    @Test("in its own group: a helper that ignores the first signal is killed before the run is reported finished")
    func aHelperThatIgnoresTheFirstSignalIsKilled() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(120), killGrace: .milliseconds(500), ownsProcessGroup: true)
        // The helper shell ignores SIGTERM; the leader does not.
        let script = #"echo $$ > leader.pid; /bin/sh -c 'trap "" TERM; echo $$ > helper.pid; while :; do /bin/sleep 1; done' & wait"#
        let invocation = Self.invocation("/bin/sh", ["-c", script], in: folder)
        let leaderFile = folder.appendingPathComponent("leader.pid")
        let helperFile = folder.appendingPathComponent("helper.pid")

        let run = Task { try await runner.output(for: invocation) }
        #expect(await Self.eventually { Self.processID(in: leaderFile) != nil && Self.processID(in: helperFile) != nil })
        let leader = try #require(Self.processID(in: leaderFile))
        let helper = try #require(Self.processID(in: helperFile))

        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }

        #expect(Self.isGone(leader))
        #expect(await Self.eventually { Self.isGone(helper) })
    }

    @Test("the caller is told the child's process id as soon as it exists", arguments: [false, true])
    func reportsTheProcessID(ownsProcessGroup: Bool) async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(60), ownsProcessGroup: ownsProcessGroup)
        let reported = ProcessIDLog()
        let text = try await runner.output(for: Self.invocation("/bin/sh", ["-c", "echo $$"], in: folder),
                                           onSpawn: { reported.add($0) })
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(reported.all == [pid])
    }

    @Test("a run cancelled before it starts launches nothing")
    func cancelledBeforeStartLaunchesNothing() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = AgentProcessRunner(timeout: .seconds(60), ownsProcessGroup: true)
        let invocation = Self.invocation("/bin/sh", ["-c", "echo started > marker; /bin/sleep 60"], in: folder)
        let run = Task {
            // Let the cancel below land first.
            try? await Task.sleep(for: .seconds(3600))
            return try await runner.output(for: invocation)
        }
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("marker").path))
    }
}
