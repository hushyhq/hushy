import Foundation
import Testing

@testable import murmur_eval

@Suite("ClaudeCLIJudge")
struct ClaudeCLIJudgeTests {
    @Test func buildsExpectedArgumentsAndSendsPromptOnlyViaStdin() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeClaude(
            in: dir, resultText: #"{"passed": true, "meaning_score": 4, "reasoning": "ok"}"#)

        let judge = ClaudeCLIJudge(model: "sonnet", executableURL: fake, cache: nil, timeout: 10)
        let verdict = try await judge.judge(input: "call mom tomorrow", output: "Call Mom tomorrow.", reference: "Call Mom tomorrow.", rubric: nil)

        #expect(verdict.passed == true)
        #expect(verdict.meaningScore == 4)

        let argv = CLIJudgeFakeScripts.readLines(dir.appendingPathComponent("argv.log").path)
        #expect(argv == ["-p", "--model", "sonnet", "--output-format", "json", "--tools", "", "--strict-mcp-config"])
        // The prompt must never appear as a CLI argument — only on stdin.
        for arg in argv {
            #expect(!arg.contains("call mom tomorrow"))
        }
        let stdinText = CLIJudgeFakeScripts.readFile(dir.appendingPathComponent("stdin.log").path)
        #expect(stdinText.contains("call mom tomorrow"))
    }

    @Test func usesSonnetAsTheDefaultModel() {
        let judge = ClaudeCLIJudge()
        #expect(judge.model == "sonnet")
    }

    @Test func retriesOnceAfterBadJSONAndSucceedsOnSecondAttempt() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeClaudeBadThenGood(
            in: dir, badText: "sorry, I can't help with that",
            goodText: #"{"passed": false, "meaning_score": 1, "reasoning": "dropped detail"}"#)

        let judge = ClaudeCLIJudge(model: "sonnet", executableURL: fake, cache: nil, timeout: 10)
        let verdict = try await judge.judge(input: "x", output: "y", reference: "z", rubric: nil)

        #expect(verdict.passed == false)
        #expect(verdict.meaningScore == 1)
        // Two invocations happened: the counter file was incremented twice.
        let counter = CLIJudgeFakeScripts.readFile(dir.appendingPathComponent("counter").path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(counter == "2")
    }

    @Test func throwsUnparseableAfterRetryWhenBothAttemptsFail() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeClaude(in: dir, resultText: "not json at all, still not json")

        let judge = ClaudeCLIJudge(model: "sonnet", executableURL: fake, cache: nil, timeout: 10)
        await #expect(throws: CLIJudgeError.unparseableAfterRetry("claude-cli")) {
            _ = try await judge.judge(input: "x", output: "y", reference: "z", rubric: nil)
        }
    }

    @Test func killsAndReportsTimeoutForAHangingProcess() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeHangingProcess(in: dir)

        let judge = ClaudeCLIJudge(model: "sonnet", executableURL: fake, cache: nil, timeout: 1)
        let clock = SuspendingClock()
        let start = clock.now
        await #expect(throws: CLIJudgeError.timedOut("claude-cli")) {
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
        // No fake script needed for the cache-hit path: point executableURL at a nonexistent
        // path so the test would fail loudly if the CLI were invoked at all.
        let nonexistent = dir.appendingPathComponent("does-not-exist")

        let judge = ClaudeCLIJudge(model: "sonnet", executableURL: nonexistent, cache: cache, timeout: 5)
        let prompt = JudgePrompt.prompt(input: "in", output: "out", reference: "ref", rubric: nil)
        let key = cache.key(backend: judge.name, model: judge.model, prompt: prompt)
        let preseeded = JudgeVerdict(passed: true, meaningScore: 4, reasoning: "cached")
        try cache.store(preseeded, for: key)

        let verdict = try await judge.judge(input: "in", output: "out", reference: "ref", rubric: nil)
        #expect(verdict == preseeded)
    }

    @Test func successfulCallPopulatesTheCacheForNextTime() async throws {
        let dir = try CLIJudgeFakeScripts.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try CLIJudgeFakeScripts.makeFakeClaude(
            in: dir, resultText: #"{"passed": true, "meaning_score": 3.5, "reasoning": "fine"}"#)
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = JudgeCache(directory: cacheDir)

        let judge = ClaudeCLIJudge(model: "sonnet", executableURL: fake, cache: cache, timeout: 10)
        _ = try await judge.judge(input: "in", output: "out", reference: "ref", rubric: nil)

        let prompt = JudgePrompt.prompt(input: "in", output: "out", reference: "ref", rubric: nil)
        let key = cache.key(backend: judge.name, model: judge.model, prompt: prompt)
        let cached = try #require(cache.load(key))
        #expect(cached.passed == true)
        #expect(cached.meaningScore == 3.5)
    }
}
