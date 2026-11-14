import Foundation

/// Judge backend that shells out to the locally installed, already-logged-in `claude` CLI
/// (Claude Code) to grade dictation-cleanup cases for dev evals only. Never used at runtime by
/// the shipping app — this is strictly a `murmur-eval judge` backend.
///
/// Invocation: `claude -p --model <model> --output-format json --tools "" --strict-mcp-config`
/// in an empty temp directory, with the prompt on stdin (never in argv, never through a shell).
/// `--tools ""` disables every built-in tool (Bash, Read, Edit, …) and `--strict-mcp-config`
/// with no `--mcp-config` means zero MCP servers either — the model can only read the prompt and
/// answer, exactly the shape a stateless grader needs. Flags verified against `claude --help`
/// (v2.1.282): `--tools <tools...>` ("" disables all tools), `--strict-mcp-config` ("Only use
/// MCP servers from --mcp-config, ignoring all other MCP configurations"), `-p/--print`,
/// `--output-format json`.
///
/// Defaults to `sonnet`: judging dev-eval quality cares more about grading accuracy than speed,
/// and `haiku` was found to be noticeably less reliable at strictly following the JSON-only
/// instruction in manual testing, which would burn the one allowed retry more often.
struct ClaudeCLIJudge: CLIJudgeBackend {
    let name = "claude-cli"
    let model: String
    let executableURL: URL
    let cache: JudgeCache?
    let timeout: TimeInterval

    init(
        model: String = "sonnet",
        executableURL: URL = ClaudeCLIJudge.defaultExecutableURL,
        cache: JudgeCache? = JudgeCache(),
        timeout: TimeInterval = 60
    ) {
        self.model = model
        self.executableURL = executableURL
        self.cache = cache
        self.timeout = timeout
    }

    static let defaultExecutableURL = URL(fileURLWithPath: "/usr/bin/env")

    /// Result envelope for `claude -p --output-format json`: the field that matters here is
    /// `result`, the model's final text. Other fields (cost, session id, etc.) are ignored.
    private struct ClaudeJSONResult: Decodable {
        let result: String?
        let isError: Bool?
        let subtype: String?

        enum CodingKeys: String, CodingKey {
            case result, isError = "is_error", subtype
        }
    }

    func judge(input: String, output: String, reference: String, rubric: String?) async throws -> JudgeVerdict {
        let prompt = JudgePrompt.prompt(input: input, output: output, reference: reference, rubric: rubric)
        let cacheKey = cache?.key(backend: name, model: model, prompt: prompt)
        if let cacheKey, let cached = cache?.load(cacheKey) {
            return cached
        }

        let verdict = try await runWithRetry(prompt: prompt)
        if let cacheKey {
            try? cache?.store(verdict, for: cacheKey)
        }
        return verdict
    }

    /// Free-text completion through the same sandboxed invocation (no tools, no MCP, prompt on
    /// stdin) — `murmur-eval finetune llm` uses it to generate synthetic training data.
    func completeText(prompt: String) async throws -> String {
        try await invoke(prompt: prompt)
    }

    /// One attempt, then exactly one retry (with a follow-up instruction reiterating the
    /// JSON-only requirement) if the first response didn't parse as a `JudgeVerdict`.
    private func runWithRetry(prompt: String) async throws -> JudgeVerdict {
        let firstText = try await invoke(prompt: prompt)
        if let verdict = try? JudgePrompt.parse(firstText) {
            return verdict
        }
        let retryPrompt = prompt + "\n\nYour previous response was not valid JSON. Respond again with ONLY the JSON object, no other text."
        let secondText = try await invoke(prompt: retryPrompt)
        do {
            return try JudgePrompt.parse(secondText)
        } catch {
            throw CLIJudgeError.unparseableAfterRetry(name)
        }
    }

    /// Runs one `claude -p` call and returns its raw text output (the `result` field of the
    /// JSON envelope). `executableURL` defaults to `/usr/bin/env` with `claude` as the first
    /// argument so the invocation resolves through `PATH` like a normal shell would — but
    /// through `Process`'s argv, never an actual shell. Tests inject a fake script by pointing
    /// `executableURL` at it directly (bypassing the `env claude` resolution).
    private func invoke(prompt: String) async throws -> String {
        try await JudgeScratchDirectory.withScratchDirectory { scratchDir in
            let arguments = resolvedArguments()
            let result = try await CLIProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: scratchDir,
                stdin: Data(prompt.utf8),
                timeout: timeout)

            if result.timedOut {
                throw CLIJudgeError.timedOut(name)
            }
            guard result.terminationStatus == 0 else {
                let stderrText = String(data: result.stderr, encoding: .utf8) ?? ""
                if stderrText.localizedCaseInsensitiveContains("not logged in")
                    || stderrText.localizedCaseInsensitiveContains("please run") {
                    throw CLIJudgeError.cliNotLoggedIn(name)
                }
                throw CLIJudgeError.processFailed(name, exitCode: result.terminationStatus, stderr: stderrText)
            }

            let stdoutText = String(data: result.stdout, encoding: .utf8) ?? ""
            guard let envelope = try? JSONDecoder().decode(ClaudeJSONResult.self, from: result.stdout),
                  let text = envelope.result
            else {
                // Fall back to raw stdout in case a fake/older CLI didn't wrap in the JSON
                // envelope; `JudgePrompt.parse` will still find the embedded JSON object.
                return stdoutText
            }
            return text
        }
    }

    /// Arguments when invoking via `/usr/bin/env claude ...` (the default executable), vs. a
    /// direct path to the CLI (or a fake test script) where `env` isn't in the picture.
    private func resolvedArguments() -> [String] {
        let claudeArguments = [
            "-p", "--model", model, "--output-format", "json", "--tools", "", "--strict-mcp-config",
        ]
        if executableURL.path == "/usr/bin/env" {
            return ["claude"] + claudeArguments
        }
        return claudeArguments
    }
}
