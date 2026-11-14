import Darwin
import Foundation
import Synchronization

/// Launches the person's installed Codex command-line tool for one task:
/// `codex exec --sandbox read-only --skip-git-repo-check --ephemeral --ignore-user-config -`,
/// task text on standard input.
///
/// - Read-only is the tool's own sandbox: it stops the tool changing files. It does not stop the
///   tool reading files on this Mac or sending what it reads to its provider, and `codex exec` is
///   non-interactive, so it asks the person nothing while it runs.
/// - `--ignore-user-config` leaves out the person's own `config.toml` (their extra servers, web
///   search and profiles), so a task runs with the tool's defaults. The login is still theirs.
/// - `--ephemeral` keeps the tool from saving a copy of the session.
///
/// The file that is run is the one held with the task, which is the one the confirmation sheet
/// showed (`HandoffTask.executable`): a real path, links already followed. It is checked again
/// here and never looked up again, so a different `codex` that has since appeared earlier in the
/// search order, or a link since pointed somewhere else, is not used.
///
/// An older tool may not know the last two, and running without them is not what the person was
/// told. So before the first task of a session the tool is asked for its help text
/// (`codex exec --help`) and every option in `requiredFlags` must be listed there.
public struct CodexHandoffRunner: HandoffRunning {
    public enum Purpose: Sendable { case probe, task }
    /// Starts one process and returns its standard output. The last argument is told the process id.
    public typealias Launch = @Sendable (
        AgentInvocation, [String: String], Purpose, @escaping @Sendable (pid_t) -> Void
    ) async throws -> String

    public static let arguments = [
        "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "-",
    ]
    public static let probeArguments = ["exec", "--help"]
    public static let requiredFlags = ["--sandbox", "--ephemeral", "--ignore-user-config"]
    public static let timeout: Duration = .seconds(900)
    public static let maxOutputBytes = 1_048_576
    /// The real launcher: its own process group, so cancel, quit, the time limit and the size limit
    /// stop the tool and whatever it started.
    public static let processRunner = AgentProcessRunner(
        timeout: timeout, maxOutputBytes: maxOutputBytes, ownsProcessGroup: true)
    /// The help text is a few thousand bytes and arrives at once; anything slower or larger is not it.
    public static let probeRunner = AgentProcessRunner(
        timeout: .seconds(10), maxOutputBytes: 262_144, ownsProcessGroup: true)

    /// The only variables copied from Hushy's own environment into the child. Anything else Hushy
    /// was started with, such as keys and tokens exported in a shell, stays out.
    /// - `HOME`, `USER`, `LOGNAME`: who is running; the tool finds its settings and login under the home folder.
    /// - `PATH`: rebuilt in `environment(from:executable:)`.
    /// - `LANG`, `LC_ALL`, `LC_CTYPE`: text encoding.
    /// - `TMPDIR`: the per-user temporary folder.
    /// - `CODEX_HOME`: where the tool keeps its settings and login when the person moved it.
    /// - Proxy and certificate variables: a network that needs them is otherwise unreachable.
    /// `OPENAI_API_KEY` and `CODEX_API_KEY` are left out on purpose: Hushy passes no key, the tool
    /// uses the login it has saved.
    public static let inheritedVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "CODEX_HOME",
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE",
    ]
    static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The check on the confirmed file, made again before every run (`checkedExecutable`): the
    /// real path it leads to now, or nil when it may not be run.
    public var resolve: @Sendable (String) -> String?
    public var isEnabled: @Sendable () -> Bool
    public var baseEnvironment: @Sendable () -> [String: String]
    public var launch: Launch
    public var inspector: any ProcessInspecting
    /// Tools whose help text listed every required option, by path. One runner lives for a session.
    private let checked = CheckedTools()

    private final class CheckedTools: Sendable {
        let paths = Mutex<Set<String>>([])
    }

    /// `launch` starts the process; tests replace it to inspect the invocation without starting anything.
    public init(
        resolve: @escaping @Sendable (String) -> String? = { CodexHandoffRunner.checkedExecutable($0) },
        isEnabled: @escaping @Sendable () -> Bool = { FeatureFlags.taskHandoff },
        baseEnvironment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        inspector: any ProcessInspecting = SystemProcessInspector(), launch: Launch? = nil
    ) {
        self.resolve = resolve
        self.isEnabled = isEnabled
        self.baseEnvironment = baseEnvironment
        self.inspector = inspector
        self.launch = launch ?? { invocation, environment, purpose, spawned in
            let runner = purpose == .probe ? CodexHandoffRunner.probeRunner : CodexHandoffRunner.processRunner
            return try await runner.output(for: invocation, baseEnvironment: environment, onSpawn: spawned)
        }
    }

    public func run(
        _ task: HandoffTask, in folder: URL, started: @escaping @Sendable (HandoffChild) -> Void
    ) async throws -> String {
        guard isEnabled() else { throw HandoffError.disabled }
        guard task.tool == .codex else { throw HandoffError.unavailable }
        // The file the person was shown, or nothing. It was a real path when shown; if it now
        // leads somewhere else, or fails the checks, it is no longer that file.
        guard let path = task.executable, resolve(path) == path else { throw HandoffError.toolChanged }
        let environment = Self.environment(from: baseEnvironment(), executable: path)
        try await requireFlags(of: path, in: folder, environment: environment)
        // The check above took a moment; the flag may have gone off meanwhile.
        guard isEnabled() else { throw HandoffError.disabled }
        let invocation = AgentInvocation(executable: path, arguments: Self.arguments, stdin: task.request,
                                         workingDirectory: folder.path, agent: .codex)
        let inspector = inspector
        return try await launch(invocation, environment, .task) { pid in
            if let child = HandoffChild.observed(pid: pid, executable: path, inspector: inspector) { started(child) }
        }
    }

    /// Asks the tool at `path` for its help text once a session and throws unless every required
    /// option is in it. A tool that failed the check is asked again next time, so updating it is
    /// enough. A help command that fails, hangs or floods counts as no tool.
    private func requireFlags(of path: String, in folder: URL, environment: [String: String]) async throws {
        if checked.paths.withLock({ $0.contains(path) }) { return }
        let probe = AgentInvocation(executable: path, arguments: Self.probeArguments, stdin: "",
                                    workingDirectory: folder.path, agent: .codex)
        let help: String
        do {
            help = try await launch(probe, environment, .probe) { _ in }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HandoffError.unavailable
        }
        guard Self.listsRequiredFlags(help) else { throw HandoffError.outdatedTool }
        checked.paths.withLock { _ = $0.insert(path) }
    }

    /// Whether `help` names every required option as a whole word (`--ephemeral-x` is not `--ephemeral`).
    public static func listsRequiredFlags(_ help: String) -> Bool {
        let optionCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let words = Set(help.components(separatedBy: optionCharacters.inverted))
        return requiredFlags.allSatisfy(words.contains)
    }

    /// The child's whole environment: the allowed variables and a rebuilt `PATH`.
    ///
    /// `PATH` is the system folders, then the tool's own folder, the absolute folders of the
    /// inherited `PATH` and the folders `ExecutableLocator` searches. The system folders come first
    /// so a program in a folder the person's account can write to never stands in for a system
    /// command of the same name. An app started from the Dock inherits only the system folders, and
    /// a tool installed as a script needs its interpreter, which lives in one of the others.
    /// Relative entries are dropped: the child works in a task folder, and a relative entry would be
    /// looked up inside it. Nothing here is a folder Hushy would not already accept the tool itself from.
    public static func environment(from base: [String: String], executable: String) -> [String: String] {
        var result = base.filter { inheritedVariables.contains($0.key) }
        let ownFolder = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let inherited = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = base["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let located = ExecutableLocator.fallbackDirectories.compactMap { folder -> String? in
            folder.hasPrefix("/") ? folder : home.map { "\($0)/\(folder)" }
        }
        var seen = Set<String>()
        result["PATH"] = (systemPath + [ownFolder] + inherited + located)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .joined(separator: ":")
        return result
    }

    /// The installed tool as a real path, or nil. `ExecutableLocator` chooses the folders (`PATH`,
    /// then its fixed list); the file it finds is then resolved and checked. Called once, when the
    /// confirmation sheet opens; what it returns is shown there and held with the task.
    public static func locateExecutable() -> String? {
        ExecutableLocator.locate(AgentKind.codex.command).flatMap { checkedExecutable($0) }
    }

    /// The real file `path` leads to once every link is followed, or nil when it may not be run.
    /// That real path is what gets started, so a link changed afterwards changes nothing.
    ///
    /// Refused: a relative path; anything but a regular file; a file, or a folder holding it,
    /// that other accounts can write to or that is owned by an account other than the person or
    /// root (whoever can write the folder can swap the file). It cannot tell a genuine tool from
    /// a look-alike the person's own account put there.
    public static func checkedExecutable(_ path: String, user: uid_t = getuid()) -> String? {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var file = stat()
        guard lstat(real, &file) == 0, file.st_mode & S_IFMT == S_IFREG, isOwnerOnly(file, user: user) else { return nil }
        var folder = stat()
        let parent = URL(fileURLWithPath: real).deletingLastPathComponent().path
        guard lstat(parent, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR, isOwnerOnly(folder, user: user) else { return nil }
        return real
    }

    public static func isAcceptableExecutable(_ path: String, user: uid_t = getuid()) -> Bool {
        checkedExecutable(path, user: user) != nil
    }

    private static func isOwnerOnly(_ info: stat, user: uid_t) -> Bool {
        info.st_mode & (S_IWGRP | S_IWOTH) == 0 && (info.st_uid == user || info.st_uid == 0)
    }
}
