import Foundation

/// The reusable entry point any eval runner calls to get a judge verdict, independent of which
/// backend is configured. `murmur-eval judge` is the first caller; the held-out reformat eval
/// (on another branch) is expected to call this same `judge(input:output:reference:rubric:)`
/// rather than reimplementing CLI plumbing.
enum JudgeClient {
    /// At most 3 judge calls run concurrently, regardless of backend — keeps a large golden set
    /// from hammering either CLI (which itself may be rate-limited) or spawning dozens of
    /// subprocesses at once.
    static let maxConcurrency = 3

    /// Runs `body` (a single case's judge call) for every element of `items`, bounded to
    /// `maxConcurrency` in flight at a time, preserving input order in the result array. Shared
    /// by both single-backend and `both`-mode runs so the concurrency cap is enforced in one
    /// place.
    static func mapConcurrently<Input: Sendable, Output: Sendable>(
        _ items: [Input], _ body: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        var results = [Output?](repeating: nil, count: items.count)
        var nextIndex = 0
        var firstError: Error?

        await withThrowingTaskGroup(of: (Int, Output).self) { group in
            func scheduleNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                let item = items[index]
                nextIndex += 1
                group.addTask {
                    let output = try await body(item)
                    return (index, output)
                }
            }
            for _ in 0..<min(maxConcurrency, items.count) { scheduleNext() }
            while true {
                do {
                    guard let (index, output) = try await group.next() else { break }
                    results[index] = output
                    scheduleNext()
                } catch {
                    if firstError == nil { firstError = error }
                    group.cancelAll()
                    break
                }
            }
        }
        if let firstError { throw firstError }
        return results.compactMap { $0 }
    }
}

/// Which judge backend(s) `murmur-eval judge --backend <selector>` should run.
enum JudgeBackendSelector: String {
    case typesafe
    case claude
    case codex
    case both

    /// Default backend, per product direction: Codex (via the account's own login) is the
    /// primary dev-eval judge; `typesafe`/`claude` remain available via `--backend` but are no
    /// longer the default.
    static let defaultSelector: JudgeBackendSelector = .codex
}

/// One case's agreement (or disagreement) between two backends in `--backend both` mode.
struct JudgeAgreementEntry {
    let caseID: String
    let claudeVerdict: JudgeVerdict
    let codexVerdict: JudgeVerdict
    var agree: Bool { claudeVerdict.passed == codexVerdict.passed }
}

/// Aggregate report for `--backend both`: agreement rate plus every disagreeing case, which is
/// the actually useful signal for reviewing eval quality (a case where two independent models
/// disagree on pass/fail is worth a human look).
struct JudgeAgreementReport {
    let entries: [JudgeAgreementEntry]

    var agreementRate: Double {
        guard !entries.isEmpty else { return 1.0 }
        return Double(entries.filter(\.agree).count) / Double(entries.count)
    }

    var disagreements: [JudgeAgreementEntry] { entries.filter { !$0.agree } }

    static func compute(_ entries: [JudgeAgreementEntry]) -> JudgeAgreementReport {
        JudgeAgreementReport(entries: entries)
    }
}
