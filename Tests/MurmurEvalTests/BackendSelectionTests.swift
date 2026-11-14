import Foundation
import Testing

@testable import murmur_eval
@testable import MurmurCore

/// `--backend` picks the cleanup model for every command except `judge`, where `--backend` is the
/// judge and `--lm-backend` is the cleanup model.
@Suite("murmur-eval backend selection")
struct BackendSelectionTests {
    private func model(_ arguments: [String]) throws -> any LanguageModel {
        try Arguments(ArraySlice(arguments)).languageModel()
    }

    @Test func defaultsToApple() throws {
        #expect(try model(["cleanup"]).identifier == "apple-fm")
        #expect(try model(["cleanup", "--backend", "none"]).identifier == "none")
    }

    @Test func judgeBackendDoesNotSelectTheCleanupModel() throws {
        #expect(try model(["judge", "--backend", "codex"]).identifier == "apple-fm")
        #expect(try model(["judge", "--backend", "jev", "--lm-backend", "none"]).identifier == "none")
    }

    @Test func localNeedsAnInstalledRegistryModel() {
        #expect(throws: (any Error).self) { try model(["cleanup", "--backend", "local", "--local-model", "no-such-model"]) }
        #expect(throws: (any Error).self) {
            try model(["cleanup", "--backend", "local", "--local-model", "qwen3.5-0.8b-4bit", "--mlx-model", "/nonexistent"])
        }
    }

    @Test func mlxWithoutAModelDirectoryIsAnError() {
        guard ProcessInfo.processInfo.environment["HUSHY_MLX_MODEL_DIR"] == nil else { return }
        #expect(throws: (any Error).self) { try model(["cleanup", "--backend", "mlx"]) }
        #expect(throws: (any Error).self) { try model(["cleanup", "--backend", "mlx", "--mlx-model", "/nonexistent"]) }
    }
}
