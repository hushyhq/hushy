import Foundation
import Testing
@testable import MurmurCore

/// The step after the drift guard flags a result, with a fake fallback load, a fake recogniser
/// (text in, text out) and a clock moved by hand. Results are plain strings here.
@Suite("Drift fallback step: a flagged dictation never waits for a model load", .timeLimit(.minutes(1)))
struct DriftFallbackStepTests {
    /// Counts the fallback recogniser's runs.
    private actor Recogniser {
        private(set) var runs = 0
        func transcribe(model: Int) -> String {
            runs += 1
            return "english from model \(model)"
        }
    }

    private static let bound: Duration = .seconds(2)

    private func run(_ loader: FallbackModelLoader<Int>, _ recogniser: Recogniser, accepts: Bool = true)
        async -> DriftFallbackStep.Answer<String> {
        await DriftFallbackStep.run(
            primary: "drifted", loader: loader, waitingUpTo: Self.bound,
            transcribe: { model in await recogniser.transcribe(model: model) },
            accepts: { primary, fallback in
                #expect(primary == "drifted")
                #expect(fallback.hasPrefix("english"))
                return accepts
            })
    }

    @Test("the fallback is ready: its result is used, at once, as before")
    func readyAndAccepted() async throws {
        let fake = FakeFallback()
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        await fake.release()
        _ = try await loader.get()

        let recogniser = Recogniser()
        let answer = await run(loader, recogniser)
        #expect(answer.outcome == .used)
        #expect(answer.result == "english from model 1")
        #expect(answer.outcome.ranFallback)
        #expect(await recogniser.runs == 1)
        #expect(await clock.requested.isEmpty, "a ready fallback involves no wait at all")
    }

    @Test("the fallback is ready and its text is not accepted: the first result stands, and the run is still counted")
    func readyAndRejected() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader.fake(fake, clock: HandClock())
        await fake.release()
        _ = try await loader.get()

        let recogniser = Recogniser()
        let answer = await run(loader, recogniser, accepts: false)
        #expect(answer.outcome == .rejected)
        #expect(answer.result == "drifted")
        #expect(answer.outcome.ranFallback)
        #expect(await recogniser.runs == 1)
    }

    @Test("a slow fallback: the dictation leaves on the bound with the first result, and the log's word says why")
    func slowFallback() async throws {
        let fake = FakeFallback()
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        await loader.warm()
        await fake.waitUntilStarted()

        let recogniser = Recogniser()
        let dictation = Task { await run(loader, recogniser) }
        await clock.waitForSleeper()
        await clock.fire()
        let answer = await dictation.value
        #expect(answer.outcome == .notReady)
        #expect(answer.outcome.rawValue == "not_ready", "the public word in the log")
        #expect(answer.result == "drifted", "the first recogniser's result, as it is")
        #expect(!answer.outcome.ranFallback)
        #expect(await recogniser.runs == 0)
        #expect(await clock.requested == [Self.bound])
        #expect(await !fake.sawCancel, "the load keeps going")

        // The load finishes; the next flagged dictation gets the fallback.
        await fake.release()
        _ = try await loader.get()
        let next = await run(loader, recogniser)
        #expect(next.outcome == .used)
        #expect(next.result == "english from model 1")
        #expect(await fake.loads == 1)
        await clock.fire()
    }

    @Test("the fallback finishes loading inside the bound: it is used")
    func loadedInsideTheBound() async throws {
        let fake = FakeFallback()
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        await loader.warm()
        await fake.waitUntilStarted()

        let recogniser = Recogniser()
        let dictation = Task { await run(loader, recogniser) }
        await clock.waitForSleeper()
        await fake.release()
        let answer = await dictation.value
        #expect(answer.outcome == .used)
        #expect(answer.result == "english from model 1")
        await clock.fire()
    }

    @Test("the fallback cannot be loaded: the first result stands and the failure is named")
    func loadFails() async {
        let fake = FakeFallback(failure: CocoaError(.fileNoSuchFile))
        let clock = HandClock()
        let loader = FallbackModelLoader.fake(fake, clock: clock)
        await fake.release()
        let recogniser = Recogniser()
        let answer = await run(loader, recogniser)
        #expect(answer.outcome == .failed)
        #expect(answer.result == "drifted")
        #expect(answer.failure?.isEmpty == false)
        #expect(await recogniser.runs == 0)
        await clock.fire()
    }

    @Test("the fallback recogniser fails on this audio: the first result stands")
    func transcriptionFails() async throws {
        let fake = FakeFallback()
        let loader = FallbackModelLoader.fake(fake, clock: HandClock())
        await fake.release()
        _ = try await loader.get()
        let answer = await DriftFallbackStep.run(
            primary: "drifted", loader: loader, waitingUpTo: Self.bound,
            transcribe: { _ -> String in throw CocoaError(.fileReadCorruptFile) },
            accepts: { _, _ in true })
        #expect(answer.outcome == .failed)
        #expect(answer.result == "drifted")
    }

    @Test("the log's words are a closed set of states")
    func words() {
        #expect([DriftFallbackOutcome.used, .rejected, .notReady, .failed].map(\.rawValue)
                == ["used", "rejected", "not_ready", "failed"])
    }
}
