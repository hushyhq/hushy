import Foundation
import MurmurCore

/// `murmur-eval judge --golden <file(s)> [--strategy rules|hybrid] [--level clean|polished]
///     [--include-voicelab] [--limit N] [--sample all|fails+N] [--report path]
///     [--backend jev|typesafe|claude|codex|both]`
/// `murmur-eval judge calibrate [--build-set] [--jev-calls 300] [--codex-calls 60] …`
///     (see `JudgeCalibrationRunner`, results in `Evals/JUDGES.md`)
///
/// An optional, independent judge of cleanup quality — a second opinion next to the
/// deterministic checks, never a gate (policy: `Evals/JUDGES.md`). `--backend jev` (alias
/// `typesafe`) uses TypeSafe's Jev with rubric v2 (`JevRubric`): eight typed judgments per case
/// grounded in the cleanup level's promise (meaning 1–4, dropped content, changed fact, disfluency
/// left, correction left, over-edited, reads clean, list layout), composed into a verdict in code
/// and reported against the golden set's exact-match pass/fail.
///
/// `--backend claude`/`codex`/`both` (default: `codex`) instead drive the developer's own
/// locally installed, already-logged-in `claude`/`codex` CLI as an LLM judge — no API key
/// needed, only a CLI login. This sends synthetic golden-set text (never real user/Voice Lab
/// data) through the developer's own CLI account; it is a dev-eval-only tool, never used by the
/// shipping app. See `Sources/murmur-eval/CLIJudge/` for the backend implementations and
/// `.claude/DECISIONS.md` for the dev-only/synthetic-data-only rationale. `both` reports the
/// agreement rate between Claude and Codex plus every case where they disagree.
///
/// `--sample fails+N` judges every exact-match failure plus a deterministic N% of passes (the
/// policy default for the quota-limited Codex judge); `all` (default) judges every case.
///
/// Every backend is optional and skips cleanly (prints a `· skipped` header, exits 0) when its
/// credential/login is missing, so callers (like `scripts/run-evals.sh`) can treat that as SKIP
/// rather than FAIL.
enum JudgeRunner {
    // MARK: Key loading

    /// Loads the TypeSafe API key from `TYPESAFE_API_KEY`, falling back to
    /// `~/.config/hushy/typesafe_api_key` (whitespace-trimmed). Returns `nil` when neither is
    /// present — callers treat that as "skip, don't fail". Warns (to stderr) if the key file's
    /// permissions are broader than owner-read/write (0600), without ever printing the key
    /// itself. `home` is injectable so tests can point at a fixture directory instead of the
    /// real one; it defaults to `HOME`.
    static func loadAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) -> String? {
        if let fromEnv = environment["TYPESAFE_API_KEY"] {
            let trimmed = fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let keyFile = home.appendingPathComponent(".config/hushy/typesafe_api_key")
        guard fileManager.fileExists(atPath: keyFile.path) else { return nil }
        if let attributes = try? fileManager.attributesOfItem(atPath: keyFile.path),
           let permissions = attributes[.posixPermissions] as? NSNumber {
            let mode = permissions.uint16Value & 0o777
            if mode & (0o077) != 0 {
                FileHandle.standardError.write(Data(
                    "warning: \(keyFile.path) has permissions \(String(mode, radix: 8)) — expected 0600 or stricter\n".utf8))
            }
        }
        guard let raw = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Case loading

    /// Reuses `Runners.GoldenCase` (spoken/expected/alternatives/tag) rather than a parallel
    /// decodable type: `--golden` here accepts the same golden-set files the `cleanup` command
    /// scores, so both commands must agree on what a case looks like.
    static func loadCases(_ args: Arguments) throws -> [Runners.GoldenCase] {
        let paths = args.string("golden").map { $0.split(separator: ",").map(String.init) } ?? []
        guard !paths.isEmpty else {
            throw EvalError.missing("usage: murmur-eval judge --golden <file[,file...]> [--strategy rules|hybrid] [--include-voicelab] [--limit N] [--report path]")
        }
        let includeVoiceLab = args.string("include-voicelab") != nil
        var allCases: [Runners.GoldenCase] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let isVoiceLab = url.lastPathComponent.localizedCaseInsensitiveContains("voicelab")
            if isVoiceLab && !includeVoiceLab {
                throw EvalError.missing("'\(path)' looks like Voice Lab data; pass --include-voicelab to send the owner's real transcripts, or use a synthetic golden file")
            }
            let cases = try JSONDecoder().decode([Runners.GoldenCase].self, from: Data(contentsOf: url))
            allCases.append(contentsOf: cases)
        }
        guard !allCases.isEmpty, Set(allCases.map(\.id)).count == allCases.count else {
            throw EvalError.missing("Golden set(s) must be nonempty with unique IDs across all files")
        }
        if let limit = args.int("limit") {
            allCases = Array(allCases.prefix(limit))
        }
        return allCases
    }

    // MARK: Command

    /// Dispatches on `--backend jev|typesafe|claude|codex|both` (default: `codex`, see
    /// `JudgeBackendSelector.defaultSelector`); `judge calibrate` runs the calibration instead.
    static func run(_ args: Arguments) async throws {
        if args.positional.first == "calibrate" {
            try await JudgeCalibrationRunner.run(args)
            return
        }
        let raw = args.string("backend") ?? ""
        let selector = JudgeBackendSelector(rawValue: raw == "jev" ? "typesafe" : raw) ?? .defaultSelector
        switch selector {
        case .typesafe:
            try await runJev(args)
        case .claude, .codex, .both:
            try await runCLIBackend(args, selector: selector)
        }
    }

    // MARK: CLI-judge backends (claude-cli / codex-cli / both)

    /// Runs the simpler CLI-judge path: cleanup output vs. reference, one `JudgeVerdict` per
    /// case, from `claude`, `codex`, or both. Does not require any API key — it drives the
    /// developer's own already-logged-in CLI. Skips cleanly (matching the TypeSafe path's
    /// contract) if the selected CLI isn't logged in, rather than failing the whole eval run.
    private static func runCLIBackend(_ args: Arguments, selector: JudgeBackendSelector) async throws {
        let prepared = try await prepare(args).map { (item: $0.item, output: $0.output) }

        do {
            switch selector {
            case .claude:
                let backend = ClaudeCLIJudge()
                let verdicts = try await JudgeClient.mapConcurrently(prepared) { entry in
                    try await backend.judge(input: entry.item.spoken, output: entry.output.text, reference: entry.item.expected, rubric: nil)
                }
                reportCLIVerdicts(backendName: backend.name, model: backend.model, cases: prepared, verdicts: verdicts, args: args)
            case .codex:
                let backend = CodexCLIJudge()
                let verdicts = try await JudgeClient.mapConcurrently(prepared) { entry in
                    try await backend.judge(input: entry.item.spoken, output: entry.output.text, reference: entry.item.expected, rubric: nil)
                }
                reportCLIVerdicts(backendName: backend.name, model: backend.model, cases: prepared, verdicts: verdicts, args: args)
            case .both:
                try await runBoth(prepared, args: args)
            case .typesafe:
                fatalError("unreachable: typesafe is handled by runJev")
            }
        } catch let error as CLIJudgeError {
            if case .cliNotLoggedIn(let backend) = error {
                print("### Judge (\(backend)) · skipped")
                print(error.localizedDescription)
                return
            }
            throw error
        }
    }

    private static func runBoth(
        _ prepared: [(item: Runners.GoldenCase, output: SmartCleaner.Output)], args: Arguments
    ) async throws {
        let claudeBackend = ClaudeCLIJudge()
        let codexBackend = CodexCLIJudge()

        let claudeVerdicts = try await JudgeClient.mapConcurrently(prepared) { entry in
            try await claudeBackend.judge(input: entry.item.spoken, output: entry.output.text, reference: entry.item.expected, rubric: nil)
        }
        let codexVerdicts = try await JudgeClient.mapConcurrently(prepared) { entry in
            try await codexBackend.judge(input: entry.item.spoken, output: entry.output.text, reference: entry.item.expected, rubric: nil)
        }

        let entries = zip(prepared, zip(claudeVerdicts, codexVerdicts)).map { pair, verdicts in
            JudgeAgreementEntry(caseID: pair.item.id, claudeVerdict: verdicts.0, codexVerdict: verdicts.1)
        }
        let agreement = JudgeAgreementReport.compute(entries)

        let summary = """
            ### Judge (both: claude-cli + codex-cli) · \(args.strategy.rawValue) · \(entries.count) cases
            - claude-cli model: \(claudeBackend.model), codex-cli model: \(codexBackend.model)
            - Agreement rate (pass/fail): \(Runners.percent(agreement.agreementRate))
            - Disagreements: \(agreement.disagreements.count) / \(entries.count)
            """
        let disagreementDetails = agreement.disagreements.map { entry -> String in
            """
              ✘ \(entry.caseID) claude=\(entry.claudeVerdict.passed)(\(String(format: "%.1f", entry.claudeVerdict.meaningScore))) codex=\(entry.codexVerdict.passed)(\(String(format: "%.1f", entry.codexVerdict.meaningScore)))
                claude reasoning: \(entry.claudeVerdict.reasoning)
                codex reasoning:  \(entry.codexVerdict.reasoning)
            """
        }
        Runners.emit(summary, details: disagreementDetails.isEmpty ? [] : ["Disagreements:"] + disagreementDetails)

        if let path = args.string("report") {
            try writeAgreementReport(agreement, claudeModel: claudeBackend.model, codexModel: codexBackend.model, path: path, args: args)
        }
    }

    private static func reportCLIVerdicts(
        backendName: String, model: String,
        cases: [(item: Runners.GoldenCase, output: SmartCleaner.Output)], verdicts: [JudgeVerdict], args: Arguments
    ) {
        let count = Double(verdicts.count)
        let passCount = verdicts.filter(\.passed).count
        let meanScore = verdicts.reduce(0.0) { $0 + $1.meaningScore } / max(count, 1)
        let summary = """
            ### Judge (\(backendName)) · \(args.strategy.rawValue) · \(verdicts.count) cases
            - Model: \(model)
            - Passed: \(passCount) / \(verdicts.count) (\(Runners.percent(Double(passCount) / max(count, 1))))
            - Mean meaning_score: \(String(format: "%.2f", meanScore)) / 4.0
            """
        let worst = zip(cases, verdicts)
            .sorted { (4 - $0.1.meaningScore) > (4 - $1.1.meaningScore) }
            .prefix(15)
            .map { pair -> String in
                let (entry, verdict) = pair
                return """
                      \(verdict.passed ? "✔" : "✘") \(entry.item.id) [\(entry.item.tag)] meaning_score=\(String(format: "%.1f", verdict.meaningScore))
                        spoken:   \(entry.item.spoken.replacingOccurrences(of: "\n", with: " ⏎ "))
                        got:      \(entry.output.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                        expected: \(entry.item.expected.replacingOccurrences(of: "\n", with: " ⏎ "))
                        reasoning: \(verdict.reasoning)
                    """
            }
        Runners.emit(summary, details: worst.isEmpty ? [] : ["Worst 15 cases by meaning_score:"] + worst)

        if let path = args.string("report") {
            try? writeCLIVerdictReport(backendName: backendName, model: model, cases: cases, verdicts: verdicts, path: path, args: args)
        }
    }

    private static func writeCLIVerdictReport(
        backendName: String, model: String,
        cases: [(item: Runners.GoldenCase, output: SmartCleaner.Output)], verdicts: [JudgeVerdict],
        path: String, args: Arguments
    ) throws {
        let entries: [[String: Any]] = zip(cases, verdicts).map { entry, verdict in
            [
                "id": entry.item.id, "tag": entry.item.tag, "spoken": entry.item.spoken,
                "expected": entry.item.expected, "output": entry.output.text,
                "passed": verdict.passed, "meaningScore": verdict.meaningScore, "reasoning": verdict.reasoning,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "kind": "judge", "backend": backendName, "model": model,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "arguments": Array(CommandLine.arguments.dropFirst()),
            "strategy": args.strategy.rawValue, "total": verdicts.count, "cases": entries,
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    private static func writeAgreementReport(
        _ agreement: JudgeAgreementReport, claudeModel: String, codexModel: String, path: String, args: Arguments
    ) throws {
        let entries: [[String: Any]] = agreement.entries.map { entry in
            [
                "id": entry.caseID, "agree": entry.agree,
                "claudePassed": entry.claudeVerdict.passed, "claudeScore": entry.claudeVerdict.meaningScore,
                "claudeReasoning": entry.claudeVerdict.reasoning,
                "codexPassed": entry.codexVerdict.passed, "codexScore": entry.codexVerdict.meaningScore,
                "codexReasoning": entry.codexVerdict.reasoning,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "kind": "judge-agreement", "claudeModel": claudeModel, "codexModel": codexModel,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "arguments": Array(CommandLine.arguments.dropFirst()),
            "strategy": args.strategy.rawValue, "total": agreement.entries.count,
            "agreementRate": agreement.agreementRate, "disagreementCount": agreement.disagreements.count,
            "cases": entries,
        ]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func command(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EvalError.missing("Cannot record git provenance") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
