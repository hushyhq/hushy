import Foundation

/// A judge backend that scores one (input, output, reference) triple and returns a
/// `JudgeVerdict`. Implemented by `ClaudeCLIJudge` and `CodexCLIJudge`; `TypeSafeJudgeBackend`
/// wraps the existing Jev-based judge so all three can be selected the same way from
/// `murmur-eval judge --backend`.
protocol CLIJudgeBackend: Sendable {
    /// Stable name used in cache keys and reports, e.g. "claude-cli", "codex-cli".
    var name: String { get }
    /// The model identifier this backend is configured to use, e.g. "sonnet", "gpt-6-astra".
    var model: String { get }

    func judge(input: String, output: String, reference: String, rubric: String?) async throws -> JudgeVerdict
}

/// Errors shared by both CLI-backed judges: process failures, timeouts, and the case where
/// retrying a bad-JSON response still didn't produce a parseable verdict.
enum CLIJudgeError: LocalizedError, Equatable {
    case timedOut(String)
    case processFailed(String, exitCode: Int32, stderr: String)
    case unparseableAfterRetry(String)
    case cliNotLoggedIn(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let backend): "\(backend) judge call timed out"
        case .processFailed(let backend, let code, let stderr):
            "\(backend) judge process exited \(code): \(stderr.prefix(500))"
        case .unparseableAfterRetry(let backend):
            "\(backend) judge did not return valid JSON, even after one retry"
        case .cliNotLoggedIn(let backend):
            "\(backend) CLI is not logged in — skipping"
        }
    }
}

/// Creates a fresh, empty temp directory for a single judge CLI invocation (each backend runs
/// in an empty working directory so the model has no project context and can't accidentally
/// read real files), and removes it afterward regardless of outcome.
enum JudgeScratchDirectory {
    static func withScratchDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-judge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }
}
