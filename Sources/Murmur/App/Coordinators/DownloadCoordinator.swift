import Foundation
import MurmurCore
import Observation
import os

/// What the coordinator needs from the speech side, as a protocol so its policy (network gate,
/// backoff, queue order, notification) is testable with a fake that never downloads.
@MainActor
protocol SpeechModelDownloading: AnyObject {
    /// The required model is already on disk (loading it needs no network).
    var isRequiredModelCached: Bool { get }
    /// Downloads (resuming) + verifies + loads the required model.
    func prepareRequired() async throws
    /// Stops the in-flight download, keeping partial bytes.
    func pauseRequired() async
    var isVocabularyModelCached: Bool { get }
    func prefetchVocabularyModel() async throws
}

/// Owns every model download for its whole life: starts the required speech model the moment
/// the app launches (before any permission prompt — only the network is needed), measures
/// throughput passively, keeps a smoothed ETA, pauses and asks on metered networks, waits out
/// offline spells and retries transient failures with backoff, then runs optional assets
/// (vocabulary model now; the MLX cleanup model and profession packs when their registry
/// entries land) strictly after the required one. See `.claude/DECISIONS.md` (2026-09-27,
/// "Onboarding downloads").
@MainActor
@Observable
final class DownloadCoordinator {
    static let speechAssetID = "speech-model"
    static let vocabularyAssetID = "vocabulary-model"
    /// A loaded-from-disk or compiling model is seconds away, not a wait.
    static let loadingSeconds: TimeInterval = 5

    private(set) var queue: AssetQueue
    private(set) var conditions: NetworkConditions?
    /// A big download is paused on a metered network until the user says so.
    private(set) var needsMeteredConsent = false
    /// The user chose "Wait for Wi-Fi" on the metered-network question.
    private(set) var waitingForUnmetered = false
    /// The required download is waiting for the network to come back.
    private(set) var waitingForNetwork = false
    /// The first measured throughput bucket (funnel).
    private(set) var speedBucket: SpeedBucket?
    /// Set when onboarding ends before the model is ready: one notification when it is.
    private(set) var willNotifyWhenReady = false

    @ObservationIgnored let status: SpeechModelStatus
    @ObservationIgnored private let speech: any SpeechModelDownloading
    @ObservationIgnored private let clock: any DownloadClock
    @ObservationIgnored private let backoff: RetryBackoff
    @ObservationIgnored private let notifier: any ReadyNotifying
    @ObservationIgnored var onSpeedMeasured: ((SpeedBucket) -> Void)?
    /// Fetches `.files` assets (the MLX cleanup model): `ManagedAssetInstaller` in the app, a fake
    /// in tests. Reports cumulative bytes on disk for the asset.
    @ObservationIgnored var fetchManagedAsset: (@Sendable (DownloadableAsset, @escaping @Sendable (Int64) -> Void) async throws -> Void)?
    /// An optional asset finished downloading (the cleanup model: switch to it now).
    @ObservationIgnored var onAssetReady: ((String) -> Void)?
    /// Optional assets the user paused; only the user resumes them.
    private(set) var userPaused: Set<String> = []
    /// Optional assets waiting on a metered network for "Download anyway".
    private(set) var meteredPaused: Set<String> = []
    /// Optional assets from Hushy's model host waiting for the person to sign in (`resumeAfterSignIn`).
    private(set) var signInPaused: Set<String> = []
    /// Optional assets waiting out the host's download limit; each tries again by itself.
    private(set) var limitPaused: Set<String> = []
    @ObservationIgnored private var limitRetries: [String: Task<Void, Never>] = [:]
    /// Passive throughput per optional asset, for its ETA.
    @ObservationIgnored private var meters: [String: ThroughputMeter] = [:]
    @ObservationIgnored private var approvedOnMetered = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeAssetID: String?
    /// Identifies the current run so a paused run's late failure can't clobber its successor.
    @ObservationIgnored private var runToken = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var didNotify = false
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "downloads")

    init(
        status: SpeechModelStatus, speech: any SpeechModelDownloading, requiredBytes: Int64,
        clock: any DownloadClock = SystemDownloadClock(), backoff: RetryBackoff = RetryBackoff(),
        notifier: any ReadyNotifying = SilentNotifier()
    ) {
        self.status = status
        self.speech = speech
        self.clock = clock
        self.backoff = backoff
        self.notifier = notifier
        queue = AssetQueue(assets: [DownloadCoordinator.speechAsset(bytes: requiredBytes)])
    }

    static func speechAsset(bytes: Int64) -> DownloadableAsset {
        DownloadableAsset(
            id: speechAssetID, title: "Speech model", kind: .speechModel, importance: .required,
            expectedBytes: bytes, source: .external)
    }

    static let vocabularyAsset = DownloadableAsset(
        id: vocabularyAssetID, title: "Vocabulary model", kind: .vocabularyModel, importance: .optional,
        expectedBytes: 98_000_000, source: .external)

    // MARK: Live numbers

    /// The required model's ETA as onboarding pacing sees it.
    var eta: DownloadETA {
        switch status.state {
        case .ready, .downloadingVocabulary: return .ready
        case .loading: return .seconds(Self.loadingSeconds)
        case .failed:
            return status.failure?.isOffline == true || waitingForNetwork ? .waiting(.offline) : .waiting(.failed)
        case .paused:
            return needsMeteredConsent || waitingForUnmetered ? .waiting(.meteredNetwork) : .waiting(.offline)
        case .idle:
            if needsMeteredConsent { return .waiting(.meteredNetwork) }
            if waitingForNetwork || conditions?.isReachable == false { return .waiting(.offline) }
            return .estimating
        case .downloading:
            if conditions?.isReachable == false { return .waiting(.offline) }
            return status.download?.estimatedSecondsRemaining.map(DownloadETA.seconds) ?? .estimating
        }
    }

    /// Seconds until every queued asset is done (required + automatic optional ones).
    var allAssetsSecondsRemaining: TimeInterval? {
        queue.allSecondsRemaining(bytesPerSecond: status.bytesPerSecond)
    }

    // MARK: Lifecycle

    /// Called at launch. Waits up to a second for the first network report so a metered
    /// network is known before a byte is spent; a cached model loads immediately.
    func start() {
        guard !started else { return }
        started = true
        if speech.isRequiredModelCached || conditions != nil {
            startNext()
            return
        }
        retryTask = Task { [weak self] in
            try? await self?.clock.sleep(for: 1)
            guard let self, !Task.isCancelled else { return }
            if self.activeAssetID == nil { self.startNext() }
        }
    }

    func networkChanged(_ newConditions: NetworkConditions) {
        let previous = conditions
        conditions = newConditions
        if !newConditions.isMetered { waitingForUnmetered = false }
        guard started else { return }
        if activeAssetID == Self.speechAssetID, status.isDownloadingPrimary {
            let decision = DownloadGate.decide(
                conditions: newConditions, remainingBytes: queue.requiredRemainingBytes, approvedOnMetered: approvedOnMetered)
            switch decision {
            case .proceed: break
            case .askFirst:
                needsMeteredConsent = !waitingForUnmetered
                pauseActive()
            case .waitForNetwork:
                waitingForNetwork = true
                pauseActive()
            }
            return
        }
        let cameBack = newConditions.isReachable && previous?.isReachable != true
        if cameBack {
            retryCount = 0
            requeuePausedOptional()
        }
        if activeAssetID == nil { startNext() }
    }

    /// "Download anyway" on the metered-network question (this session only).
    func approveMeteredDownload() {
        approvedOnMetered = true
        needsMeteredConsent = false
        waitingForUnmetered = false
        requeuePausedOptional()
        startNext()
    }

    /// "Wait for Wi-Fi": stay paused until the path is neither expensive nor constrained.
    func deferUntilUnmetered() {
        needsMeteredConsent = false
        waitingForUnmetered = true
    }

    /// Retry buttons (onboarding, Home readiness, dictate status row).
    func retryNow() {
        retryTask?.cancel()
        retryCount = 0
        waitingForNetwork = false
        if activeAssetID == nil { startNext() }
    }

    /// Onboarding finished (or was skipped past "Try it") before the model was ready.
    func notifyWhenReady() {
        guard !status.isReady, !didNotify else { return }
        willNotifyWhenReady = true
        notifier.prepare()
    }

    /// The Dictionary gained its first words: fetch the vocabulary model after the speech one.
    func dictionaryChanged(hasTerms: Bool) {
        guard hasTerms, !speech.isVocabularyModelCached, queue[Self.vocabularyAssetID] == nil else { return }
        queue = queue.adding(Self.vocabularyAsset)
        if started, activeAssetID == nil { startNext() }
    }

    /// Once a second while bytes are flowing (see `SpeechModelStatus.tick`).
    func tick(now: Date = Date()) {
        status.tick(now: now)
        if let download = status.download {
            queue = queue.updating(Self.speechAssetID, receivedBytes: download.estimatedBytes)
        }
        guard speedBucket == nil, status.meter.observedSeconds >= 5, let rate = status.bytesPerSecond else { return }
        let bucket = SpeedBucket.from(bytesPerSecond: rate)
        speedBucket = bucket
        onSpeedMeasured?(bucket)
    }

    /// Snapshot rendering only: pins the network flags (the status is pinned separately).
    func pinForSnapshot(needsMeteredConsent: Bool = false, waitingForNetwork: Bool = false, conditions: NetworkConditions? = nil) {
        self.needsMeteredConsent = needsMeteredConsent
        self.waitingForNetwork = waitingForNetwork
        self.conditions = conditions
        waitingForUnmetered = false
    }

    // MARK: Optional assets (the cleanup model)

    /// Puts an accept-to-start asset in the queue as an offer (no bytes move yet).
    func offer(_ asset: DownloadableAsset) {
        queue = queue.adding(asset)
    }

    /// The user wants this asset: queue it (from offered, paused or failed) and start when the
    /// required model is ready and nothing else is downloading.
    func accept(_ asset: DownloadableAsset) {
        if queue[asset.id] == nil { queue = queue.adding(asset) }
        userPaused.remove(asset.id)
        meteredPaused.remove(asset.id)
        signInPaused.remove(asset.id)
        clearLimitPause(asset.id)
        if let entry = queue[asset.id], entry.state != .downloading, entry.state != .ready {
            queue = queue.updating(asset.id, state: .queued)
        }
        if started, activeAssetID == nil { startNext() }
    }

    /// Uninstall: stops the download in flight and starts no other.
    func stopAll() {
        started = false
        retryTask?.cancel()
        retryTask = nil
        pauseActive()
    }

    /// Stops an optional asset's download, keeping its partial bytes for a resume.
    func pause(_ assetID: String) {
        userPaused.insert(assetID)
        if activeAssetID == assetID {
            pauseActive()
            startNext()
        } else if queue[assetID]?.state == .queued {
            queue = queue.updating(assetID, state: .paused)
        }
    }

    /// Cancels and forgets an asset (the user deleted it or picked another model). Its files are
    /// the caller's to remove.
    func remove(_ assetID: String) {
        if activeAssetID == assetID {
            runToken += 1
            activeTask?.cancel()
            activeTask = nil
            activeAssetID = nil
            stopTicker()
        }
        userPaused.remove(assetID)
        meteredPaused.remove(assetID)
        signInPaused.remove(assetID)
        clearLimitPause(assetID)
        meters[assetID] = nil
        queue = queue.removing(assetID)
        if started, activeAssetID == nil { startNext() }
    }

    /// Seconds left for one optional asset at its measured rate; nil before there is a rate.
    func secondsRemaining(for assetID: String) -> TimeInterval? {
        guard let entry = queue[assetID], let rate = meters[assetID]?.bytesPerSecond, rate > 1 else { return nil }
        return min(Double(entry.remainingBytes) / rate, ThroughputMeter.maximumSeconds)
    }

    private func managedProgress(_ assetID: String, bytes: Int64) {
        guard activeAssetID == assetID else { return }
        queue = queue.updating(assetID, receivedBytes: bytes)
        meters[assetID] = (meters[assetID] ?? ThroughputMeter()).observing(totalBytes: bytes, at: clock.now())
    }

    /// The person signed in: downloads that were waiting for an account go back in line.
    func resumeAfterSignIn() {
        guard !signInPaused.isEmpty else { return }
        for id in signInPaused where queue[id]?.state == .paused {
            queue = queue.updating(id, state: .queued)
        }
        log.notice("signed in: \(self.signInPaused.count, privacy: .public) model download(s) resume")
        signInPaused.removeAll()
        if started, activeAssetID == nil { startNext() }
    }

    /// Optional assets paused by the network (not by the user, the account or a limit) go back in line.
    private func requeuePausedOptional() {
        for entry in queue.entries where entry.asset.importance != .required && entry.state == .paused {
            let id = entry.asset.id
            guard !userPaused.contains(id), !signInPaused.contains(id), !limitPaused.contains(id) else { continue }
            meteredPaused.remove(entry.asset.id)
            queue = queue.updating(entry.asset.id, state: .queued)
        }
    }

    // MARK: Running the queue

    private func startNext() {
        guard activeAssetID == nil else { return }
        let required = queue[Self.speechAssetID]
        if let required, required.state != .ready {
            run(required.asset)
        } else if let next = queue.nextToStart {
            run(next)
        }
    }

    private func run(_ asset: DownloadableAsset) {
        let isRequired = asset.id == Self.speechAssetID
        let needsNetwork = isRequired ? !speech.isRequiredModelCached : true
        if needsNetwork, let conditions {
            let remaining = queue[asset.id]?.remainingBytes ?? asset.expectedBytes
            switch DownloadGate.decide(conditions: conditions, remainingBytes: remaining, approvedOnMetered: approvedOnMetered) {
            case .proceed: break
            case .waitForNetwork:
                waitingForNetwork = true
                queue = queue.updating(asset.id, state: .paused)
                if isRequired, speedBucket == nil { onSpeedMeasured?(.offline) }
                return
            case .askFirst:
                if isRequired { needsMeteredConsent = !waitingForUnmetered } else { meteredPaused.insert(asset.id) }
                queue = queue.updating(asset.id, state: .paused)
                if isRequired { status.markPaused() }
                return
            }
        }
        waitingForNetwork = false
        activeAssetID = asset.id
        runToken += 1
        let token = runToken
        queue = queue.updating(asset.id, state: .downloading)
        startTicker()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.fetch(asset)
                guard token == self.runToken else { return }
                self.finished(asset)
            } catch {
                guard token == self.runToken else { return }
                self.failed(asset, error: error)
            }
        }
    }

    private func fetch(_ asset: DownloadableAsset) async throws {
        switch asset.id {
        case Self.speechAssetID: try await speech.prepareRequired()
        case Self.vocabularyAssetID: try await speech.prefetchVocabularyModel()
        default:
            // Managed `.files` assets (the MLX cleanup model, M4) go through `AssetDownloader`.
            guard case .files = asset.source, let fetchManagedAsset else {
                log.error("no fetcher for asset \(asset.id, privacy: .public)")
                return
            }
            let id = asset.id
            try await fetchManagedAsset(asset) { [weak self] bytes in
                Task { @MainActor in self?.managedProgress(id, bytes: bytes) }
            }
        }
    }

    private func finished(_ asset: DownloadableAsset) {
        activeTask = nil
        activeAssetID = nil
        retryCount = 0
        queue = queue.updating(asset.id, state: .ready)
        meters[asset.id] = nil
        stopTicker()
        if asset.id != Self.speechAssetID { onAssetReady?(asset.id) }
        if asset.id == Self.speechAssetID, willNotifyWhenReady, !didNotify {
            didNotify = true
            willNotifyWhenReady = false
            notifier.notifyReady()
        }
        startNext()
    }

    private func failed(_ asset: DownloadableAsset, error: Error) {
        activeTask = nil
        activeAssetID = nil
        stopTicker()
        // Paused on purpose (metered/offline): the pause path already set the state.
        if queue[asset.id]?.state == .paused { return }
        if pauseForAccount(asset, error: error) { return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            // Caught the tail of an earlier pause: just go again.
            queue = queue.updating(asset.id, state: .queued)
            Task { [weak self] in self?.startNext() }
            return
        }
        let offline = SpeechModelStatus.isOffline(error) || conditions?.isReachable == false
        if offline {
            waitingForNetwork = true
            queue = queue.updating(asset.id, state: .paused)
        }
        retryCount += 1
        guard let delay = backoff.delay(beforeRetry: retryCount) else {
            queue = queue.updating(asset.id, state: .failed(error.localizedDescription))
            log.error("download of \(asset.id, privacy: .public) gave up after \(self.retryCount - 1) retries")
            return
        }
        queue = queue.updating(asset.id, state: offline ? .paused : .queued)
        log.notice("download of \(asset.id, privacy: .public) failed; retrying in \(delay, format: .fixed(precision: 1)) s")
        retryTask = Task { [weak self] in
            try? await self?.clock.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if self.activeAssetID == nil { self.startNext() }
        }
    }

    /// Hushy's model host refused for a reason a retry cannot fix now: nobody is signed in (wait for
    /// `resumeAfterSignIn`), or its download limit (wait the time it gave, then go again). The bytes
    /// already on disk are kept either way. False for every other error.
    private func pauseForAccount(_ asset: DownloadableAsset, error: Error) -> Bool {
        guard let error = error as? AssetDownloadError else { return false }
        switch error {
        case .signInRequired:
            signInPaused.insert(asset.id)
            queue = queue.updating(asset.id, state: .paused)
            log.notice("download of \(asset.id, privacy: .public) waits for sign-in")
        case .rateLimited(let retryAfter):
            let wait = min(max(retryAfter, Self.shortestLimitWait), Self.longestLimitWait)
            limitPaused.insert(asset.id)
            queue = queue.updating(asset.id, state: .paused)
            log.notice("download of \(asset.id, privacy: .public) reached the download limit; again in \(wait, format: .fixed(precision: 0)) s")
            let id = asset.id
            limitRetries[id]?.cancel()
            limitRetries[id] = Task { [weak self] in
                try? await self?.clock.sleep(for: wait)
                guard let self, !Task.isCancelled, self.limitPaused.contains(id) else { return }
                self.clearLimitPause(id)
                if self.queue[id]?.state == .paused, !self.userPaused.contains(id) { self.queue = self.queue.updating(id, state: .queued) }
                if self.started, self.activeAssetID == nil { self.startNext() }
            }
        default:
            return false
        }
        startNext()
        return true
    }

    /// A limit pause waits at least a minute and at most six hours (the daily limit resets at midnight UTC).
    static let shortestLimitWait: TimeInterval = 60
    static let longestLimitWait: TimeInterval = 6 * 60 * 60

    private func clearLimitPause(_ id: String) {
        limitPaused.remove(id)
        limitRetries[id]?.cancel()
        limitRetries[id] = nil
    }

    private func pauseActive() {
        guard let id = activeAssetID else { return }
        queue = queue.updating(id, state: .paused)
        runToken += 1
        if id == Self.speechAssetID {
            // The engine cancels its load task and reports `.paused` itself.
            let speech = self.speech
            Task { await speech.pauseRequired() }
        } else {
            activeTask?.cancel()
        }
        activeTask = nil
        activeAssetID = nil
        stopTicker()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
