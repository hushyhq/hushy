import Foundation
import Testing

@testable import murmur_eval

@Suite("JudgeCache")
struct JudgeCacheTests {
    private func makeTempCacheDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func keyIsStableForSameInputsAndDiffersForDifferentPrompts() {
        let cache = JudgeCache(directory: FileManager.default.temporaryDirectory)
        let keyA1 = cache.key(backend: "claude-cli", model: "sonnet", prompt: "prompt A")
        let keyA2 = cache.key(backend: "claude-cli", model: "sonnet", prompt: "prompt A")
        let keyB = cache.key(backend: "claude-cli", model: "sonnet", prompt: "prompt B")
        #expect(keyA1 == keyA2)
        #expect(keyA1 != keyB)
    }

    @Test func keyDiffersByBackendAndModelEvenForSamePrompt() {
        let cache = JudgeCache(directory: FileManager.default.temporaryDirectory)
        let claudeKey = cache.key(backend: "claude-cli", model: "sonnet", prompt: "same prompt")
        let codexKey = cache.key(backend: "codex-cli", model: "sonnet", prompt: "same prompt")
        let otherModelKey = cache.key(backend: "claude-cli", model: "haiku", prompt: "same prompt")
        #expect(claudeKey != codexKey)
        #expect(claudeKey != otherModelKey)
    }

    @Test func storeThenLoadRoundTripsTheVerdict() throws {
        let dir = try makeTempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = JudgeCache(directory: dir)
        let key = cache.key(backend: "codex-cli", model: "gpt-6-astra", prompt: "p")
        let verdict = JudgeVerdict(passed: true, meaningScore: 3.5, reasoning: "looks good")

        #expect(cache.load(key) == nil)
        try cache.store(verdict, for: key)
        let loaded = try #require(cache.load(key))
        #expect(loaded == verdict)
    }

    @Test func loadReturnsNilForMissingKeyWithoutThrowing() throws {
        let dir = try makeTempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = JudgeCache(directory: dir)
        #expect(cache.load("does-not-exist") == nil)
    }

    @Test func loadReturnsNilForCorruptedCacheFileRatherThanThrowing() throws {
        let dir = try makeTempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = JudgeCache(directory: dir)
        let key = "corrupt-key"
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(key).json"))
        #expect(cache.load(key) == nil)
    }

    @Test func storeCreatesTheCacheDirectoryIfMissing() throws {
        let base = try makeTempCacheDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = base.appendingPathComponent("nested/judge-cache", isDirectory: true)
        let cache = JudgeCache(directory: nested)
        let key = cache.key(backend: "claude-cli", model: "sonnet", prompt: "p")
        try cache.store(JudgeVerdict(passed: false, meaningScore: 1, reasoning: "r"), for: key)
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }
}
