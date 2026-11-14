import Foundation

/// Judge backend that shells out to the locally installed, already-logged-in `codex` CLI to
/// grade dictation-cleanup cases for dev evals only. Never used at runtime by the shipping app.
///
/// Invocation: `codex exec --sandbox read-only --skip-git-repo-check -m <model> --json -` in an
/// empty temp directory, with the prompt piped on stdin (`-` tells `codex exec` to read the
/// prompt from stdin per `codex exec --help`: "If not provided as an argument (or if `-` is
/// used), instructions are read from stdin"). `--sandbox read-only` is the most restrictive
/// sandbox `codex exec --help` offers (`read-only|workspace-write|danger-full-access`) — the
/// judge only needs to read the prompt and produce text, never write or execute anything.
/// `--skip-git-repo-check` is required because the scratch directory is not a git repository.
/// `--json` streams newline-delimited JSON events; the verdict text comes from the
/// `item.completed` event whose `item.type == "agent_message"`.
///
/// Default model: `gpt-6-luna` at low reasoning effort (product direction 2026-09-26: a smaller,
/// cheaper judge is good enough and stretches the ChatGPT plan's Codex usage limit). This is the default judge backend per product direction: judging
/// quality matters more than speed, so a small/mini model is avoided, and a model id not
/// available on this Codex login (e.g. a bare "gpt-5-mini") was confirmed to hard-fail with
/// "not supported when using Codex with a ChatGPT account" — so the backend uses whatever
/// capable model is actually available to the caller's login rather than hardcoding one that
/// may not resolve. `-c model=…` is documented as available for a small/cheap model when a caller
/// wants speed over quality; `-m/--model` is used here directly per `codex exec --help`.
struct CodexCLIJudge: CLIJudgeBackend {
    let name = "codex-cli"
    let model: String
    let executableURL: URL
    let cache: JudgeCache?
    let timeout: TimeInterval

    init(
        model: String = "gpt-6-luna",
        executableURL: URL = CodexCLIJudge.defaultExecutableURL,
        cache: JudgeCache? = JudgeCache(),
        timeout: TimeInterval = 60
    ) {
        self.model = model
        self.executableURL = executableURL
        self.cache = cache
        self.timeout = timeout
    }

    static let defaultExecutableURL = URL(fileURLWithPath: "/usr/bin/env")

    /// One line of `codex exec --json` output. Only the two event shapes the judge needs are
    /// modeled; every other event type (`thread.started`, `turn.started`, …) is ignored.
    private struct CodexEvent: Decodable {
        let type: String
        let item: Item?
        let error: ErrorPayload?

        struct Item: Decodable {
            let type: String
            let text: String?
        }
        struct ErrorPayload: Decodable {
            let message: String?
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

    /// Sends an arbitrary prompt through the same `codex exec` plumbing (read-only sandbox,
    /// scratch directory, stdin-only prompt, timeout) and returns the model's text without
    /// parsing it as a `JudgeVerdict`. Used by callers whose response schema differs from the
    /// single-case verdict — e.g. `HeadToHeadJudge`, which grades two blinded pairs per call.
    /// Not cached here: those callers own their own cache keyed by their own prompt shape.
    func completeText(prompt: String) async throws -> String {
        try await invoke(prompt: prompt)
    }

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

    /// Runs one `codex exec` call and returns the concatenated text of every `agent_message`
    /// item in its `--json` event stream (in practice there is exactly one for this prompt
    /// shape, but concatenating is robust to a model that emits the answer in two chunks).
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

            let stdoutText = String(data: result.stdout, encoding: .utf8) ?? ""
            let messages = parseAgentMessages(fromJSONLines: stdoutText)

            guard result.terminationStatus == 0 else {
                let stderrText = String(data: result.stderr, encoding: .utf8) ?? ""
                let combined = stderrText + stdoutText
                if combined.localizedCaseInsensitiveContains("not logged in")
                    || combined.localizedCaseInsensitiveContains("sign in")
                    || combined.localizedCaseInsensitiveContains("authenticate") {
                    throw CLIJudgeError.cliNotLoggedIn(name)
                }
                throw CLIJudgeError.processFailed(name, exitCode: result.terminationStatus, stderr: stderrText)
            }

            guard !messages.isEmpty else {
                // Fall back to raw stdout so a differently-shaped (or fake, in tests) CLI output
                // still has a chance of containing a parseable JSON object.
                return stdoutText
            }
            return messages.joined(separator: "\n")
        }
    }

    private func parseAgentMessages(fromJSONLines text: String) -> [String] {
        var messages: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONDecoder().decode(CodexEvent.self, from: data)
            else { continue }
            if event.type == "item.completed", event.item?.type == "agent_message", let text = event.item?.text {
                messages.append(text)
            }
        }
        return messages
    }

    /// Arguments when invoking via `/usr/bin/env codex ...` (the default executable), vs. a
    /// direct path to the CLI (or a fake test script) where `env` isn't in the picture. The
    /// prompt is passed as `-` (read from stdin) rather than as an argv string, per the rule
    /// that the prompt must never appear directly in argv.
    private func resolvedArguments() -> [String] {
        let codexArguments = [
            "exec", "--sandbox", "read-only", "--skip-git-repo-check", "-m", model,
            "-c", "model_reasoning_effort=\"low\"", "--json", "-",
        ]
        if executableURL.path == "/usr/bin/env" {
            return ["codex"] + codexArguments
        }
        return codexArguments
    }
}
