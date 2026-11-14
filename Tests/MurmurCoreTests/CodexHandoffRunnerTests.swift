import Darwin
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

private final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    var value: Value { state.withLock { $0 } }
    func change(_ body: @Sendable (inout Value) -> Void) { state.withLock { body(&$0) } }
}

private struct Captured: Sendable {
    var invocation: AgentInvocation
    var environment: [String: String]
    var purpose: CodexHandoffRunner.Purpose
}

/// Invented help text in the shape the tool prints. Not copied from any tool.
private enum HelpText {
    static let current = """
        Run the tool without a window

        Usage: tool exec [OPTIONS] [PROMPT]

        Options:
          -s, --sandbox <SANDBOX_MODE>   Choose what commands may touch
              --skip-git-repo-check      Allow running outside a repository
              --ephemeral                Run without saving the session
              --ignore-user-config       Do not load the settings file
          -h, --help                     Print help
        """
    static let older = """
        Usage: tool exec [OPTIONS] [PROMPT]

        Options:
          -s, --sandbox <SANDBOX_MODE>   Choose what commands may touch
              --skip-git-repo-check      Allow running outside a repository
          -h, --help                     Print help
        """
    /// Longer options that only begin with the required names.
    static let nearMiss = """
        Options:
          -s, --sandbox <SANDBOX_MODE>
              --ephemeral-cache
              --ignore-user-config-file <FILE>
        """
}

private struct FixedInspector: ProcessInspecting {
    var facts: ProcessFacts?
    func facts(for pid: pid_t) -> ProcessFacts? { facts }
}

/// What `CodexHandoffRunner` would launch, captured through its `launch` seam. Nothing starts:
/// the help text and the answers are fixture strings.
@Suite struct CodexHandoffInvocationTests {
    private static let parentEnvironment = [
        "HOME": "/Users/invented", "USER": "invented", "LOGNAME": "invented", "LANG": "en_GB.UTF-8",
        "TMPDIR": "/var/folders/invented/T/", "CODEX_HOME": "/Users/invented/.codex-elsewhere",
        "HTTPS_PROXY": "http://proxy.invalid:8080", "PATH": "/opt/tools/bin:relative/bin:.:/usr/bin",
        "OPENAI_API_KEY": "invented-key", "CODEX_API_KEY": "invented-key", "GITHUB_TOKEN": "invented-token",
        "AWS_SECRET_ACCESS_KEY": "invented-secret", "HUSHY_HOME": "/tmp/invented", "CLAUDECODE": "1",
    ]
    private static let folder = URL(fileURLWithPath: "/tmp/invented-tasks/work", isDirectory: true)

    /// A task confirmed with the tool at the invented path.
    private static func task(_ request: String) -> HandoffTask {
        HandoffTask(tool: .codex, request: request, executable: "/opt/invented/bin/codex")
    }

    /// A runner whose launches are recorded. The help command answers `help`; a task answers "Invented answer".
    private static func runner(
        help: @escaping @Sendable () throws -> String, captured: Shared<[Captured]>,
        isEnabled: @escaping @Sendable () -> Bool = { true }, inspector: any ProcessInspecting = FixedInspector()
    ) -> CodexHandoffRunner {
        CodexHandoffRunner(
            resolve: { $0 }, isEnabled: isEnabled,
            baseEnvironment: { parentEnvironment }, inspector: inspector,
            launch: { invocation, environment, purpose, spawned in
                captured.change { $0.append(Captured(invocation: invocation, environment: environment, purpose: purpose)) }
                if purpose == .probe { return try help() }
                spawned(4_242)
                return "Invented answer"
            })
    }

    @Test func buildsTheReadOnlyCommandWithTheTaskOnStandardInputAndASmallEnvironment() async throws {
        let captured = Shared<[Captured]>([])
        let runner = Self.runner(help: { HelpText.current }, captured: captured)
        let task = Self.task("Invented task about paper kites --sandbox danger-full-access")

        let answer = try await runner.run(task, in: Self.folder) { _ in }

        #expect(answer == "Invented answer")
        let launch = try #require(captured.value.last)
        #expect(launch.purpose == .task)
        #expect(launch.invocation.executable == "/opt/invented/bin/codex")
        #expect(launch.invocation.arguments == [
            "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "-",
        ])
        // The task travels on standard input only; no argument carries any of it.
        #expect(launch.invocation.stdin == task.request)
        #expect(!launch.invocation.arguments.contains { $0.contains("kites") || $0.contains("danger") })
        #expect(launch.invocation.workingDirectory == Self.folder.path)
        #expect(launch.invocation.agent == .codex)
        #expect(launch.invocation.environmentOverrides.isEmpty)
        // The whole environment the child gets, after the invocation's own (empty) overrides.
        let environment = launch.invocation.environment(from: launch.environment)
        #expect(Set(environment.keys) == ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "CODEX_HOME", "HTTPS_PROXY", "PATH"])
        #expect(environment["HOME"] == "/Users/invented")
        #expect(environment["CODEX_HOME"] == "/Users/invented/.codex-elsewhere")
        // The system folders first, then the tool's own folder, inherited absolute folders and the
        // locator's folders. No relative entry.
        #expect(environment["PATH"] == [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/invented/bin", "/opt/tools/bin",
            "/Users/invented/.local/bin", "/Users/invented/.claude/local", "/Users/invented/.npm-global/bin",
            "/Users/invented/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
        ].joined(separator: ":"))
    }

    /// Finding 2. The help command runs first, the same way a task would, and once a session.
    @Test func theToolIsAskedForItsHelpTextOnceBeforeTheFirstTask() async throws {
        let captured = Shared<[Captured]>([])
        let runner = Self.runner(help: { HelpText.current }, captured: captured)

        _ = try await runner.run(Self.task("Invented first task"), in: Self.folder) { _ in }
        _ = try await runner.run(Self.task("Invented second task"), in: Self.folder) { _ in }

        let launches = captured.value
        #expect(launches.map(\.purpose) == [.probe, .task, .task])
        let probe = try #require(launches.first)
        #expect(probe.invocation.executable == "/opt/invented/bin/codex")
        #expect(probe.invocation.arguments == ["exec", "--help"])
        #expect(probe.invocation.stdin.isEmpty)
        #expect(probe.invocation.workingDirectory == Self.folder.path)
        #expect(probe.invocation.environmentOverrides.isEmpty)
        // The same small environment as the task: no key, token or Hushy variable.
        #expect(probe.environment == launches[1].environment)
        #expect(probe.environment["OPENAI_API_KEY"] == nil)
    }

    @Test func aToolWithoutTheRequiredOptionsRunsNoTask() async throws {
        let captured = Shared<[Captured]>([])
        let help = Shared(HelpText.older)
        let runner = Self.runner(help: { help.value }, captured: captured)
        let task = Self.task("Invented task")

        await #expect(throws: HandoffError.outdatedTool) { try await runner.run(task, in: Self.folder) { _ in } }
        #expect(captured.value.map(\.purpose) == [.probe])

        // After an update the next task asks again and runs.
        help.change { $0 = HelpText.current }
        #expect(try await runner.run(task, in: Self.folder) { _ in } == "Invented answer")
        #expect(captured.value.map(\.purpose) == [.probe, .probe, .task])
    }

    @Test func aHelpCommandThatFailsRunsNoTask() async throws {
        let captured = Shared<[Captured]>([])
        let runner = Self.runner(help: { throw AgentChatError.timedOut(seconds: 10) }, captured: captured)
        await #expect(throws: HandoffError.unavailable) {
            try await runner.run(Self.task("Invented task"), in: Self.folder) { _ in }
        }
        #expect(captured.value.map(\.purpose) == [.probe])
    }

    @Test func everyRequiredOptionMustBeListedAsAWholeWord() {
        #expect(CodexHandoffRunner.requiredFlags == ["--sandbox", "--ephemeral", "--ignore-user-config"])
        #expect(CodexHandoffRunner.requiredFlags.allSatisfy(CodexHandoffRunner.arguments.contains))
        #expect(CodexHandoffRunner.listsRequiredFlags(HelpText.current))
        #expect(!CodexHandoffRunner.listsRequiredFlags(HelpText.older))
        #expect(!CodexHandoffRunner.listsRequiredFlags(HelpText.nearMiss))
        #expect(!CodexHandoffRunner.listsRequiredFlags(""))
    }

    /// Finding 6. The process is described the moment it exists, for a launch after a crash.
    @Test func theStartedProcessIsReportedWithItsStartTimeAndTool() async throws {
        let facts = ProcessFacts(startSeconds: 1_700_000_000, startMicroseconds: 123_456,
                                 executable: "/opt/invented/bin/codex", arguments: [], parent: 99, group: 4_242)
        let reported = Shared<[HandoffChild]>([])
        let runner = Self.runner(help: { HelpText.current }, captured: Shared([]), inspector: FixedInspector(facts: facts))

        _ = try await runner.run(Self.task("Invented task"), in: Self.folder) { child in
            reported.change { $0.append(child) }
        }

        // The invented path does not exist, so the file it leads to is the path itself.
        #expect(reported.value == [HandoffChild(pid: 4_242, startSeconds: 1_700_000_000, startMicroseconds: 123_456,
                                                executable: "/opt/invented/bin/codex", image: "/opt/invented/bin/codex")])
    }

    @Test func theRealLaunchersUseTheirOwnProcessGroupATimeLimitAndASizeLimit() {
        let runner = CodexHandoffRunner.processRunner
        #expect(runner.ownsProcessGroup)
        #expect(runner.timeout == .seconds(900))
        #expect(runner.maxOutputBytes == 1_048_576)
        #expect(runner.killGrace == .seconds(2))
        let probe = CodexHandoffRunner.probeRunner
        #expect(probe.ownsProcessGroup)
        #expect(probe.timeout == .seconds(10))
        #expect(probe.maxOutputBytes == 262_144)
    }

    @Test func nothingIsLaunchedWhileTheFlagIsOff() async throws {
        let captured = Shared<[Captured]>([])
        let runner = Self.runner(help: { HelpText.current }, captured: captured, isEnabled: { false })
        await #expect(throws: HandoffError.disabled) {
            try await runner.run(Self.task("Invented task"), in: Self.folder) { _ in }
        }
        #expect(captured.value.isEmpty)
    }

    @Test func anotherToolOrATaskWithNoRecordedFileLaunchesNothing() async throws {
        let captured = Shared<[Captured]>([])
        let runner = Self.runner(help: { HelpText.current }, captured: captured)
        await #expect(throws: HandoffError.unavailable) {
            try await runner.run(HandoffTask(tool: .claudeCode, request: "Invented task", executable: "/opt/invented/bin/codex"),
                                 in: Self.folder) { _ in }
        }
        // Saved before the file was recorded: there is nothing the person was shown, so nothing runs.
        await #expect(throws: HandoffError.toolChanged) {
            try await runner.run(HandoffTask(tool: .codex, request: "Invented task"), in: Self.folder) { _ in }
        }
        #expect(captured.value.isEmpty)
    }

    @Test func onlyAFileThatOtherAccountsCannotWriteIsAccepted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-handoff-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String, mode: Int) throws -> String {
            let url = folder.appendingPathComponent(name)
            try Data("invented".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url.path
        }
        let ownerOnly = try file("owner-only", mode: 0o755)
        #expect(CodexHandoffRunner.isAcceptableExecutable(ownerOnly))
        // What is handed back to run is the real path, here with the temporary folder's own links followed.
        let real = try #require(CodexHandoffRunner.checkedExecutable(ownerOnly))
        #expect(real == URL(fileURLWithPath: ownerOnly).resolvingSymlinksInPath().path || real.hasSuffix(ownerOnly))
        #expect(CodexHandoffRunner.checkedExecutable(real) == real)
        #expect(!CodexHandoffRunner.isAcceptableExecutable(try file("group-writable", mode: 0o775)))
        #expect(!CodexHandoffRunner.isAcceptableExecutable(try file("world-writable", mode: 0o757)))
        #expect(!CodexHandoffRunner.isAcceptableExecutable(folder.path))
        #expect(!CodexHandoffRunner.isAcceptableExecutable(folder.appendingPathComponent("missing").path))
        #expect(!CodexHandoffRunner.isAcceptableExecutable("relative/codex"))
        // Owned by neither the person nor root.
        #expect(!CodexHandoffRunner.isAcceptableExecutable(ownerOnly, user: getuid() + 1))
        // A link is judged by the file it leads to.
        let link = folder.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: ownerOnly)
        #expect(CodexHandoffRunner.isAcceptableExecutable(link))
        #expect(CodexHandoffRunner.checkedExecutable(link) == real)

        // Second review, item 5. Whoever can write the folder can swap the file in it.
        for mode in [0o775, 0o757, 0o777] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
            #expect(CodexHandoffRunner.checkedExecutable(ownerOnly) == nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(CodexHandoffRunner.checkedExecutable(ownerOnly) == real)
    }
}

/// Follow-up 1. The file run is the file the person was shown. These use real files in a
/// temporary folder and the real check on them; the launch is still a recording stand-in.
@Suite struct CodexHandoffConfirmedToolTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-handoff-confirmed-\(UUID().uuidString)")
    private var earlier: URL { base.appendingPathComponent("earlier") }
    private var later: URL { base.appendingPathComponent("later") }
    private var searchPath: String { "\(earlier.path):\(later.path)" }

    private func install(in folder: URL, mode: Int = 0o755) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("codex")
        try Data("invented".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file.path
    }

    /// What the confirmation sheet would find: the real search, over the two temporary folders
    /// only, then the real check, which hands back the real path.
    private func found() -> String? {
        ExecutableLocator.locate("codex", path: searchPath, home: base.appendingPathComponent("home").path)
            .flatMap { CodexHandoffRunner.checkedExecutable($0) }
    }

    private func real(_ path: String) throws -> String { try #require(CodexHandoffRunner.checkedExecutable(path)) }

    private func runner(_ captured: Shared<[Captured]>) -> CodexHandoffRunner {
        CodexHandoffRunner(isEnabled: { true }, baseEnvironment: { ["HOME": "/Users/invented"] }, inspector: FixedInspector(),
                           launch: { invocation, environment, purpose, _ in
            captured.change { $0.append(Captured(invocation: invocation, environment: environment, purpose: purpose)) }
            return purpose == .probe ? HelpText.current : "Invented answer"
        })
    }

    @Test func aDifferentToolAppearingEarlierInTheSearchOrderIsNotUsed() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let confirmed = try real(install(in: later))
        #expect(found() == confirmed)
        let task = HandoffTask(tool: .codex, request: "Invented task", executable: try #require(found()))

        // Between the confirm and the run another file takes first place in the search.
        let newcomer = try real(install(in: earlier))
        #expect(found() == newcomer)

        let captured = Shared<[Captured]>([])
        #expect(try await runner(captured).run(task, in: base) { _ in } == "Invented answer")

        // The help check and the task both ran the confirmed file.
        #expect(captured.value.map(\.purpose) == [.probe, .task])
        #expect(captured.value.map(\.invocation.executable) == [confirmed, confirmed])
    }

    @Test func aConfirmedToolThatIsGoneOrFailsTheCheckRunsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let confirmed = try real(install(in: later))
        let other = try real(install(in: earlier))
        let task = HandoffTask(tool: .codex, request: "Invented task", executable: confirmed)
        let captured = Shared<[Captured]>([])
        let runner = runner(captured)

        // Its folder is now writable by others on this Mac.
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: later.path)
        await #expect(throws: HandoffError.toolChanged) { try await runner.run(task, in: base) { _ in } }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: later.path)

        // Now writable by others on this Mac.
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: confirmed)
        await #expect(throws: HandoffError.toolChanged) { try await runner.run(task, in: base) { _ in } }
        // Replaced by a folder of the same name.
        try FileManager.default.removeItem(atPath: confirmed)
        try FileManager.default.createDirectory(atPath: confirmed, withIntermediateDirectories: false)
        await #expect(throws: HandoffError.toolChanged) { try await runner.run(task, in: base) { _ in } }
        // Gone. The other file is still findable, and still not used.
        try FileManager.default.removeItem(atPath: confirmed)
        #expect(found() == other)
        await #expect(throws: HandoffError.toolChanged) { try await runner.run(task, in: base) { _ in } }

        #expect(captured.value.isEmpty)
    }

    /// Second review, item 5. What is started is the real file that was checked, so a link
    /// pointed elsewhere afterwards changes nothing, and a link is never what a task holds.
    @Test func aLinkIsResolvedWhenFoundAndNeverFollowedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let target = try real(install(in: later))
        let impostor = try real(install(in: base.appendingPathComponent("impostor")))
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        let link = earlier.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: target))
        // The sheet shows, and the task holds, the real file, not the link.
        #expect(found() == target)
        let task = HandoffTask(tool: .codex, request: "Invented task", executable: try #require(found()))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: impostor))
        #expect(found() == impostor)

        let captured = Shared<[Captured]>([])
        #expect(try await runner(captured).run(task, in: base) { _ in } == "Invented answer")
        #expect(captured.value.map(\.invocation.executable) == [target, target])

        // A task holding a link (which no sheet produces) is refused rather than followed.
        let viaLink = HandoffTask(tool: .codex, request: "Invented task", executable: link.path)
        await #expect(throws: HandoffError.toolChanged) { try await runner(captured).run(viaLink, in: base) { _ in } }
        #expect(captured.value.count == 2)
    }
}

/// Second review, item 2. A release build cannot have the feature turned on.
@Suite struct TaskHandoffFlagTests {
    @Test func theFlagIsReadOnlyInADebugBuild() throws {
        #if DEBUG
        // This is a debug build: the Developer pane's switch is what the flag reads.
        #expect(FeatureFlags.taskHandoffCanBeTurnedOn)
        #else
        // A release build: a stored `true` is not read, and writing the flag stores nothing.
        #expect(!FeatureFlags.taskHandoffCanBeTurnedOn)
        let name = "app.hushy.test.handoff-flag.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        let previous = FeatureFlags.source
        defer {
            FeatureFlags.source = previous
            suite.removePersistentDomain(forName: name)
        }
        FeatureFlags.source = suite
        suite.set(true, forKey: FeatureFlags.taskHandoffKey)
        #expect(!FeatureFlags.taskHandoff)
        suite.removeObject(forKey: FeatureFlags.taskHandoffKey)
        FeatureFlags.taskHandoff = true
        #expect(suite.object(forKey: FeatureFlags.taskHandoffKey) == nil)
        #expect(!FeatureFlags.taskHandoff)
        #endif
    }
}
