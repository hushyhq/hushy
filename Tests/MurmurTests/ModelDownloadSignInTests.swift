import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The speech model is already on disk, so only the cleanup model moves.
@MainActor
private final class CachedSpeech: SpeechModelDownloading {
    let status: SpeechModelStatus
    let isRequiredModelCached = true
    let isVocabularyModelCached = true
    init(status: SpeechModelStatus) { self.status = status }
    func prepareRequired() async throws {
        status.beginLoad(cached: true, expectedBytes: 1)
        status.markReady()
    }
    func pauseRequired() async {}
    func prefetchVocabularyModel() async throws {}
}

private final class RecordingClock: DownloadClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var sleeps: [TimeInterval] { lock.withLock { recorded } }
    func now() -> Date { Date() }
    func sleep(for seconds: TimeInterval) async throws { lock.withLock { recorded.append(seconds) } }
}

/// Each call to the fetcher takes the next scripted error, or succeeds when the script is empty.
private final class ScriptedFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Error]
    private(set) var calls = 0
    init(_ script: [Error]) { self.script = script }
    func next() throws {
        let error: Error? = lock.withLock {
            calls += 1
            return script.isEmpty ? nil : script.removeFirst()
        }
        if let error { throw error }
    }
}

@Suite("Model download: sign-in and download limit")
@MainActor
struct ModelDownloadSignInTests {
    private let entry = ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent)!

    private func make(_ fetch: ScriptedFetch) -> (DownloadCoordinator, RecordingClock) {
        let status = SpeechModelStatus()
        let clock = RecordingClock()
        let coordinator = DownloadCoordinator(
            status: status, speech: CachedSpeech(status: status), requiredBytes: 1, clock: clock,
            backoff: RetryBackoff(initialDelay: 2, multiplier: 2, maximumDelay: 60, maximumAttempts: 3, jitter: 0))
        coordinator.fetchManagedAsset = { _, _ in try fetch.next() }
        return (coordinator, clock)
    }

    private func settle() async {
        for _ in 0..<60 { await Task.yield() }
    }

    @Test("signed out: the model waits (no retries) and goes on by itself after sign-in")
    func waitsForSignIn() async {
        let fetch = ScriptedFetch([AssetDownloadError.signInRequired])
        let (coordinator, clock) = make(fetch)
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        coordinator.accept(entry.asset)
        await settle()
        #expect(coordinator.queue[entry.asset.id]?.state == .paused)
        #expect(coordinator.signInPaused.contains(entry.asset.id))
        #expect(fetch.calls == 1)
        #expect(clock.sleeps.isEmpty)
        // Coming back online does not retry: only a sign-in can fix it.
        coordinator.networkChanged(.offline)
        coordinator.networkChanged(.unmetered)
        await settle()
        #expect(fetch.calls == 1)

        coordinator.resumeAfterSignIn()
        await settle()
        #expect(fetch.calls == 2)
        #expect(coordinator.queue[entry.asset.id]?.state == .ready)
        #expect(coordinator.signInPaused.isEmpty)
    }

    @Test("the download limit pauses the model and tries again after the wait the server gave")
    func waitsOutTheLimit() async {
        let fetch = ScriptedFetch([AssetDownloadError.rateLimited(retryAfter: 3_600)])
        let (coordinator, clock) = make(fetch)
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        coordinator.accept(entry.asset)
        await settle()
        #expect(clock.sleeps.contains(3_600))
        #expect(fetch.calls == 2)
        #expect(coordinator.queue[entry.asset.id]?.state == .ready)
        #expect(coordinator.limitPaused.isEmpty)
    }

    @Test("a wait is never shorter than a minute nor longer than six hours")
    func limitWaitIsClamped() async {
        let fetch = ScriptedFetch([AssetDownloadError.rateLimited(retryAfter: 5), AssetDownloadError.rateLimited(retryAfter: 900_000)])
        let (coordinator, clock) = make(fetch)
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        coordinator.accept(entry.asset)
        await settle()
        #expect(clock.sleeps.contains(DownloadCoordinator.shortestLimitWait))
        #expect(clock.sleeps.contains(DownloadCoordinator.longestLimitWait))
        #expect(coordinator.queue[entry.asset.id]?.state == .ready)
    }

    @Test("the pill and the status note say what to do")
    func copy() {
        let total = entry.downloadBytes
        #expect(CleanupModelController.waitingLine(for: .paused(received: 10, total: total, reason: .signedOut))
            == "Sign in to download Hushy's writing model")
        #expect(CleanupModelController.waitingLine(for: .paused(received: 10, total: total, reason: .downloadLimit))
            == "Hushy's model download continues later")
        #expect(CleanupModelController.waitingLine(for: .paused(received: 10, total: total, reason: .offline))
            == "Hushy's model download is paused")
    }
}
