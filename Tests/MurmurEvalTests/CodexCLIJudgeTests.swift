import Foundation
import Testing

@testable import murmur_eval

@Suite("CodexCLIJudge")
struct CodexCLIJudgeTests {
    @Test func buildsExpectedArgumentsWithReadOnlySandboxAndSendsPromptOnlyViaStdin() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeCodex(
            in: dir, messageText: #"{"passed": true, "meaning_score": 4, "reasoning": "ok"}"#)

        let judge = CodexCLIJudge(model: "gpt-6-astra", executableURL: fake, cache: nil, timeout: 10)
        let verdict = try await judge.judge(input: "call mom tomorrow", output: "Call Mom tomorrow.", reference: "Call Mom tomorrow.", rubric: nil)

        #expect(verdict.passed == true)
        #expect(verdict.meaningScore == 4)

        let argv = CLIJudgeFakeScripts.readLines(dir.appendingPathComponent("argv.log").path)
        #expect(argv == ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "-m", "gpt-6-astra", "-c", "model_reasoning_effort=\"low\"", "--json", "-"])
        for arg in argv {
            #expect(!arg.contains("call mom tomorrow"))
        }
        let stdinText = CLIJudgeFakeScripts.readFile(dir.appendingPathComponent("stdin.log").path)
        #expect(stdinText.contains("call mom tomorrow"))
    }

    @Test func usesLunaAsTheDefaultJudgeModel() {
        // Product direction (2026-09-26): judge with Codex's smaller, cheaper Luna model.
        let judge = CodexCLIJudge()
        #expect(judge.model == "gpt-6-luna")
        #expect(judge.name == "codex-cli")
    }

    @Test func usesReadOnlySandboxNeverWorkspaceWriteOrDangerFullAccess() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeCodex(
            in: dir, messageText: #"{"passed": true, "meaning_score": 4, "reasoning": "ok"}"#)
        let judge = CodexCLIJudge(model: "gpt-6-astra", executableURL: fake, cache: nil, timeout: 10)
        _ = try await judge.judge(input: "x", output: "y", reference: "z", rubric: nil)
        let argv = CLIJudgeFakeScripts.readLines(dir.appendingPathComponent("argv.log").path)
        #expect(argv.contains("read-only"))
        #expect(!argv.contains("workspace-write"))
        #expect(!argv.contains("danger-full-access"))
    }

    @Test func killsAndReportsTimeoutForAHangingProcess() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeHangingProcess(in: dir)

        let judge = CodexCLIJudge(model: "gpt-6-astra", executableURL: fake, cache: nil, timeout: 1)
        let clock = SuspendingClock()
        let start = clock.now
        await #expect(throws: CLIJudgeError.timedOut("codex-cli")) {
            _ = try await judge.judge(input: "x", output: "y", reference: "z", rubric: nil)
        }
        // The call waits for the process to exit after killing it, so only a process that survived the
        // kill could take the fake's full sleep. Half of it cannot be reached by a slow machine, and
        // SuspendingClock does not count time the Mac spent asleep.
        #expect(clock.now - start < .seconds(CLIJudgeFakeScripts.hangSeconds / 2))
        // And the fake's own process is really gone, not just abandoned.
        #expect(await CLIJudgeFakeScripts.hangingProcessIsGone(in: dir))
    }

    @Test func cacheHitSkipsInvokingTheCLIEntirely() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = JudgeCache(directory: cacheDir)
        let nonexistent = dir.appendingPathComponent("does-not-exist")

        let judge = CodexCLIJudge(model: "gpt-6-astra", executableURL: nonexistent, cache: cache, timeout: 5)
        let prompt = JudgePrompt.prompt(input: "in", output: "out", reference: "ref", rubric: nil)
        let key = cache.key(backend: judge.name, model: judge.model, prompt: prompt)
        let preseeded = JudgeVerdict(passed: false, meaningScore: 0.5, reasoning: "cached")
        try cache.store(preseeded, for: key)

        let verdict = try await judge.judge(input: "in", output: "out", reference: "ref", rubric: nil)
        #expect(verdict == preseeded)
    }

    @Test func parsesOnlyAgentMessageItemsIgnoringOtherEventTypes() async throws {
        // Simulates a codex --json stream with noise events mixed in around the real message,
        // proving the parser only extracts item.completed/agent_message text.
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptPath = dir.appendingPathComponent("fake-codex-noisy")
        let messageText = #"{"passed": true, "meaning_score": 2, "reasoning": "partial"}"#
        let base64Message = Data(messageText.utf8).base64EncodedString()
        let script = """
            #!/bin/sh
            cat > /dev/null
            echo '{"type":"thread.started","thread_id":"t"}'
            echo '{"type":"item.completed","item":{"id":"i0","type":"error","message":"ignored"}}'
            MESSAGE=$(echo "\(base64Message)" | base64 -D)
            python3 -c 'import json,sys; print(json.dumps({"type": "item.completed", "item": {"id": "i1", "type": "agent_message", "text": sys.argv[1]}}))' "$MESSAGE"
            echo '{"type":"turn.completed","usage":{}}'
            """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let judge = CodexCLIJudge(model: "gpt-6-astra", executableURL: scriptPath, cache: nil, timeout: 10)
        let verdict = try await judge.judge(input: "x", output: "y", reference: "z", rubric: nil)
        #expect(verdict.passed == true)
        #expect(verdict.meaningScore == 2)
    }
}
