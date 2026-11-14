import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Scripted speech side: each `prepareRequired` takes the next behaviour. Never downloads.
@MainActor
private final class FakeSpeech: SpeechModelDownloading {
    enum Behaviour { case succeed, fail(Error), hang }

    let status: SpeechModelStatus
    var isRequiredModelCached = false
    var isVocabularyModelCached = false
    var script: [Behaviour] = []
    private(set) var prepareCalls = 0
    private(set) var pauseCalls = 0
    private(set) var vocabularyCalls = 0
    private var hanging: CheckedContinuation<Void, Error>?

    init(status: SpeechModelStatus) { self.status = status }

    func prepareRequired() async throws {
        prepareCalls += 1
        status.beginLoad(cached: isRequiredModelCached, expectedBytes: 632_000_000)
        switch script.isEmpty ? .succeed : script.removeFirst() {
        case .succeed:
            status.markReady()
        case .fail(let error):
            status.markFailed(error)
            throw error
        case .hang:
            try await withCheckedThrowingContinuation { hanging = $0 }
        }
    }

    func pauseRequired() async {
        pauseCalls += 1
        status.markPaused()
        hanging?.resume(throwing: CancellationError())
        hanging = nil
    }

    func prefetchVocabularyModel() async throws { vocabularyCalls += 1 }
}

private final class ImmediateClock: DownloadClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var sleeps: [TimeInterval] { lock.withLock { recorded } }
    func now() -> Date { Date() }
    func sleep(for seconds: TimeInterval) async throws { lock.withLock { recorded.append(seconds) } }
}

@Suite("Download coordinator")
@MainActor
struct DownloadCoordinatorTests {
    private let hotspot = NetworkConditions(isReachable: true, isExpensive: true)
    private let lowData = NetworkConditions(isReachable: true, isConstrained: true)

    private func make(_ configure: (FakeSpeech) -> Void = { _ in }) -> (DownloadCoordinator, FakeSpeech, ImmediateClock, SilentNotifier) {
        let status = SpeechModelStatus()
        let speech = FakeSpeech(status: status)
        configure(speech)
        let clock = ImmediateClock()
        let notifier = SilentNotifier()
        let coordinator = DownloadCoordinator(
            status: status, speech: speech, requiredBytes: 632_000_000, clock: clock,
            backoff: RetryBackoff(initialDelay: 2, multiplier: 2, maximumDelay: 60, maximumAttempts: 3, jitter: 0),
            notifier: notifier)
        return (coordinator, speech, clock, notifier)
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test("starts at launch on an unmetered network, before any permission")
    func startsImmediately() async {
        let (coordinator, speech, _, _) = make()
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        #expect(speech.prepareCalls == 1)
        #expect(coordinator.eta == .ready)
        #expect(coordinator.queue[DownloadCoordinator.speechAssetID]?.state == .ready)
    }

    @Test("waits briefly for the first network report, then starts")
    func startsWithoutNetworkReport() async {
        let (coordinator, speech, clock, _) = make()
        coordinator.start()
        await settle()
        #expect(clock.sleeps == [1])
        #expect(speech.prepareCalls == 1)
    }

    @Test("a metered network asks before the first byte; approving starts it", arguments: [true, false])
    func meteredAsks(expensive: Bool) async {
        let (coordinator, speech, _, _) = make()
        coordinator.networkChanged(expensive ? hotspot : lowData)
        coordinator.start()
        await settle()
        #expect(speech.prepareCalls == 0)
        #expect(coordinator.needsMeteredConsent)
        #expect(coordinator.eta == .waiting(.meteredNetwork))
        coordinator.approveMeteredDownload()
        await settle()
        #expect(speech.prepareCalls == 1)
        #expect(coordinator.eta == .ready)
    }

    @Test("\"Wait for Wi-Fi\" resumes by itself on an unmetered network")
    func waitsForWiFi() async {
        let (coordinator, speech, _, _) = make()
        coordinator.networkChanged(hotspot)
        coordinator.start()
        coordinator.deferUntilUnmetered()
        await settle()
        #expect(!coordinator.needsMeteredConsent)
        #expect(coordinator.eta == .waiting(.meteredNetwork))
        coordinator.networkChanged(.unmetered)
        await settle()
        #expect(speech.prepareCalls == 1)
    }

    @Test("switching to a hotspot mid-download pauses (keeping bytes) and asks")
    func pausesMidDownload() async {
        let (coordinator, speech, _, _) = make { $0.script = [.hang, .succeed] }
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        #expect(coordinator.status.isDownloadingPrimary)
        coordinator.networkChanged(hotspot)
        await settle()
        #expect(speech.pauseCalls == 1)
        #expect(coordinator.needsMeteredConsent)
        #expect(coordinator.status.state == .paused)
        coordinator.approveMeteredDownload()
        await settle()
        #expect(speech.prepareCalls == 2)
        #expect(coordinator.status.isReady)
    }

    @Test("offline: waits (no fake progress), records the offline bucket, resumes when back")
    func offlineThenBack() async {
        let (coordinator, speech, _, _) = make()
        var buckets: [SpeedBucket] = []
        coordinator.onSpeedMeasured = { buckets.append($0) }
        coordinator.networkChanged(.offline)
        coordinator.start()
        await settle()
        #expect(speech.prepareCalls == 0)
        #expect(coordinator.eta == .waiting(.offline))
        #expect(buckets == [.offline])
        coordinator.networkChanged(.unmetered)
        await settle()
        #expect(speech.prepareCalls == 1)
        #expect(coordinator.eta == .ready)
    }

    @Test("losing the network mid-download pauses and resumes on reconnect")
    func dropMidDownload() async {
        let (coordinator, speech, _, _) = make { $0.script = [.hang, .succeed] }
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        coordinator.networkChanged(.offline)
        await settle()
        #expect(speech.pauseCalls == 1)
        #expect(coordinator.eta == .waiting(.offline))
        coordinator.networkChanged(.unmetered)
        await settle()
        #expect(speech.prepareCalls == 2)
        #expect(coordinator.status.isReady)
    }

    @Test("transient failures retry with backoff; the budget ends in a visible failure")
    func backoff() async {
        let (coordinator, speech, clock, _) = make {
            $0.script = [.fail(URLError(.badServerResponse)), .fail(URLError(.badServerResponse)),
                         .fail(URLError(.badServerResponse)), .fail(URLError(.badServerResponse))]
        }
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        #expect(clock.sleeps == [2, 4, 8])
        #expect(speech.prepareCalls == 4)
        if case .failed = coordinator.queue[DownloadCoordinator.speechAssetID]?.state {} else {
            Issue.record("expected the asset to end failed")
        }
        #expect(coordinator.eta == .waiting(.failed))
        coordinator.retryNow()
        await settle()
        #expect(speech.prepareCalls == 5)
        #expect(coordinator.status.isReady)
    }

    @Test("a model already on disk loads even offline")
    func cachedOffline() async {
        let (coordinator, speech, _, _) = make { $0.isRequiredModelCached = true }
        coordinator.networkChanged(.offline)
        coordinator.start()
        await settle()
        #expect(speech.prepareCalls == 1)
        #expect(coordinator.status.isReady)
    }

    @Test("one notification when the model lands after onboarding ended")
    func notifiesOnce() async {
        let (coordinator, _, _, notifier) = make { $0.script = [.hang] }
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        coordinator.notifyWhenReady()
        coordinator.notifyWhenReady()
        #expect(notifier.prepared)
        #expect(notifier.sentCount == 0)
        coordinator.networkChanged(.offline)  // pause
        await settle()
        coordinator.networkChanged(.unmetered)  // resume → succeeds
        await settle()
        #expect(notifier.sentCount == 1)
    }

    @Test("no notification when the model was ready in time")
    func noNotificationWhenReady() async {
        let (coordinator, _, _, notifier) = make()
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        coordinator.notifyWhenReady()
        #expect(!notifier.prepared)
        #expect(notifier.sentCount == 0)
    }

    @Test("an uninstall stops the download in flight, and nothing starts another")
    func stopAllStopsForGood() async {
        let (coordinator, speech, clock, _) = make { $0.script = [.hang, .succeed] }
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        #expect(coordinator.status.isDownloadingPrimary)

        coordinator.stopAll()
        await settle()
        coordinator.networkChanged(.offline)
        coordinator.networkChanged(.unmetered)
        coordinator.dictionaryChanged(hasTerms: true)
        await settle()

        #expect(speech.pauseCalls == 1)
        #expect(speech.prepareCalls == 1)
        #expect(speech.vocabularyCalls == 0)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("optional assets wait for the required model, then run")
    func optionalAfterRequired() async {
        let (coordinator, speech, _, _) = make { $0.script = [.hang, .succeed] }
        coordinator.networkChanged(.unmetered)
        coordinator.start()
        await settle()
        coordinator.dictionaryChanged(hasTerms: true)
        await settle()
        #expect(speech.vocabularyCalls == 0)
        #expect(coordinator.queue[DownloadCoordinator.vocabularyAssetID]?.state == .queued)
        coordinator.networkChanged(.offline)
        await settle()
        coordinator.networkChanged(.unmetered)
        await settle()
        #expect(speech.vocabularyCalls == 1)
        #expect(coordinator.queue[DownloadCoordinator.vocabularyAssetID]?.state == .ready)
    }
}
