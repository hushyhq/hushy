import Foundation
import MurmurCore
import Testing
@testable import HushyModelsMLX

@Suite("MLX load lifecycle", .timeLimit(.minutes(1)))
struct MLXLoadLifecycleTests {
    private actor Loader {
        private(set) var calls = 0
        private var pending: [Int: CheckedContinuation<MLXEngine.Handoff, Never>] = [:]
        private var started: [Int: CheckedContinuation<Void, Never>] = [:]

        func load(_ directory: URL) async -> MLXEngine.Handoff {
            calls += 1
            let call = calls
            return await withCheckedContinuation { continuation in
                pending[call] = continuation
                started.removeValue(forKey: call)?.resume()
            }
        }

        func waitForCall(_ call: Int) async {
            if pending[call] != nil { return }
            await withCheckedContinuation { started[call] = $0 }
        }

        func fail(_ call: Int, reason: String) {
            let error = NSError(domain: "invented-loader", code: call, userInfo: [NSLocalizedDescriptionKey: reason])
            pending.removeValue(forKey: call)?.resume(returning: .init(result: .failure(error), milliseconds: 1))
        }
    }

    private func request(_ engine: MLXEngine) -> Task<String, Never> {
        Task {
            do {
                try await engine.loadForMeasurement()
                return "loaded"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return String(describing: error)
            }
        }
    }

    @Test("unload cancels existing waiters without starting another load")
    func unloadWhileLoading() async throws {
        let loader = Loader()
        let engine = MLXEngine(settings: .init(directory: URL(fileURLWithPath: "/unused")), loadModel: { await loader.load($0) })
        let waiter = request(engine)
        await loader.waitForCall(1)
        let task = await engine.loadTask
        let completion = try #require(task)
        await engine.unload()
        await loader.fail(1, reason: "obsolete")
        await completion.value
        #expect(await waiter.value == "cancelled")
        #expect(await loader.calls == 1)
        #expect(await engine.isLoaded == false)
        #expect(await engine.isLoading == false)
    }

    @Test("an obsolete load cannot fail its replacement")
    func obsoleteCompletion() async throws {
        let loader = Loader()
        let engine = MLXEngine(settings: .init(directory: URL(fileURLWithPath: "/unused")), loadModel: { await loader.load($0) })
        let first = request(engine)
        await loader.waitForCall(1)
        let task = await engine.loadTask
        let oldCompletion = try #require(task)
        await engine.unload()
        let second = request(engine)
        await loader.waitForCall(2)
        await loader.fail(1, reason: "obsolete")
        await oldCompletion.value
        #expect(await engine.isLoading, "the obsolete failure cannot change the replacement's state")
        await loader.fail(2, reason: "replacement")
        #expect(await first.value == "cancelled")
        let failure = await second.value
        #expect(failure.contains("replacement"))
        #expect(!failure.contains("obsolete"))
        #expect(await loader.calls == 2)
    }

    @Test("a failed load is tried again on the next request, not kept for the rest of the process")
    func failedLoadIsRetried() async throws {
        let loader = Loader()
        let engine = MLXEngine(settings: .init(directory: URL(fileURLWithPath: "/unused")), loadModel: { await loader.load($0) })
        let first = request(engine)
        await loader.waitForCall(1)
        await loader.fail(1, reason: "Insufficient Memory at wake")
        #expect(await first.value.contains("Insufficient Memory"))
        let second = request(engine)
        var waited = 0
        while await loader.calls < 2, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(await loader.calls == 2, "the second request loads again")
        await loader.fail(2, reason: "again")
        #expect(await second.value.contains("again"))
    }

    private actor CountingLoader {
        private(set) var calls = 0
        func load(_ directory: URL) -> MLXEngine.Handoff {
            calls += 1
            return .init(result: .failure(SealedModelLoader.Failure.keyUnavailable("sign in to Hushy")), milliseconds: 1)
        }
    }

    @Test("a sealed model without a key is busy, not broken: it is not asked again at once, and it is asked again after the wait")
    func keyIsTemporary() async throws {
        let loader = CountingLoader()
        var settings = MLXEngine.Settings(directory: URL(fileURLWithPath: "/unused"))
        settings.keyRetryDelay = .milliseconds(150)
        let engine = MLXEngine(settings: settings, loadModel: { await loader.load($0) })
        func attempt() async -> String {
            do { try await engine.loadForMeasurement(); return "loaded" } catch { return String(describing: error) }
        }
        let first = await attempt()
        #expect(first.contains("busy") && first.contains("model key is not available"), "\(first)")
        #expect(await attempt() == first, "inside the wait the same answer comes back without a load")
        #expect(await loader.calls == 1)
        #expect(await engine.isLoaded == false)
        try await Task.sleep(for: .milliseconds(250))
        _ = await attempt()
        #expect(await loader.calls == 2, "after the wait the key is asked for again")
    }

    @Test("a missing key never counts against the model's health; a broken file does")
    func keyDoesNotDisable() {
        let keyless = LanguageModelError.busy("\(SealedModelLoader.keyUnavailablePrefix) (sign in to Hushy).")
        #expect(MLXLanguageModel.classify(keyless) == keyless)
        #expect(SealedModelLoader.Failure.keyUnavailable("x").localizedDescription.hasPrefix(SealedModelLoader.keyUnavailablePrefix))
    }
}
