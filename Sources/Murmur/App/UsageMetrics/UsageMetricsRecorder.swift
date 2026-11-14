import Foundation
import MurmurCore
import os

/// The app's one door to usage numbers: counts and timings, never words.
///
/// Every call site hands over a closed-vocabulary event (`MetricEvent`) and returns at once. The
/// switch and the data epoch are read from `AppSettings.usageGate`, which the settings object flips
/// in the same call that changes the setting. Everything that touches the disk goes through one
/// ordered queue, and each operation carries the epoch it was created in: after the switch has gone
/// off, that epoch is never current again, so an event from before the off is dropped by the
/// service instead of being written, and the folder of the old epoch is simply never read. Deleting
/// old folders is tidying, done at launch and right after an off. A failure anywhere is logged
/// without content and never reaches the caller, so metrics cannot slow, block or change a
/// dictation, a voice action or a meeting.
///
/// Recording happens only while the person has been shown the switch (`usageNumbersNoticeSeen`)
/// and has turned it on (`shareUsageNumbers`, off by default). Nothing is uploaded unless a build configured an
/// endpoint (`MetricsEndpoint`); without one the uploader never calls the network and batches wait
/// in the bounded local queue.
@MainActor
final class UsageMetricsRecorder {
    private enum Operation: Sendable {
        case record(MetricEvent, Date, epoch: Int)
        case recordOnDay(MetricEvent, MetricsDay, epoch: Int)
        case tidy
        case barrier(@Sendable () -> Void)
    }

    private static let loopInterval: Duration = .seconds(6 * 3_600)
    private static let firstLoopDelay: Duration = .seconds(90)

    private let settings: AppSettings
    private let service: UsageMetricsService?
    private let uploader: MetricsUploader?
    /// Held for the life of the process: a second process cannot take it and gets an inert recorder.
    private let storeLock: MetricsStoreLock?
    private let operations: AsyncStream<Operation>.Continuation
    private let log = Logger(subsystem: "app.hushy", category: "usage-metrics")
    private var pending = PendingDictationMetrics(calendar: .autoupdatingCurrent)
    private var loopTask: Task<Void, Never>?
    /// Set by `stopForUninstall`: the queue is closed, so a barrier yielded to it would never run.
    private var isStoppedForUninstall = false

    /// Test seam: runs right after a preview has been read and before it is returned, so a test can
    /// cycle the switch at exactly that point. Nil in the app.
    var afterPreviewReadHook: (() -> Void)?

    /// True when this build has an endpoint, so "See what's sent" can say whether anything leaves the Mac.
    let isUploadConfigured: Bool

    /// - Parameters:
    ///   - directory: where the journal and queue live; nil makes the recorder inert (snapshot and
    ///     disposable runs), so nothing is ever written.
    ///   - endpoint: from `MetricsEndpoint.configured()`; nil means no network call, ever.
    init(
        settings: AppSettings, directory: URL?, endpoint: URL?, transport: MetricsTransport? = nil,
        appBuild: Int = UsageMetricsRecorder.bundleBuild(), takesStoreLock: Bool = true
    ) {
        self.settings = settings
        isUploadConfigured = directory != nil && endpoint != nil
        let (stream, continuation) = AsyncStream.makeStream(of: Operation.self)
        operations = continuation
        let lock = takesStoreLock ? directory.flatMap { MetricsStoreLock(root: $0) } : nil
        storeLock = lock
        guard let directory, lock != nil || !takesStoreLock, let store = Self.readyStore(settings: settings, directory: directory) else {
            service = nil
            uploader = nil
            continuation.finish()
            return
        }
        let created = UsageMetricsService(
            store: store, appBuild: appBuild,
            firstRunDay: try? MetricsDay(date: settings.firstRunAt, calendar: .autoupdatingCurrent),
            environment: MetricsEnvironment.current(), gate: settings.usageGate)
        service = created
        uploader = MetricsUploader(
            store: store, transport: endpoint == nil ? InertMetricsTransport() : (transport ?? URLSessionMetricsTransport()),
            endpoint: endpoint, gate: settings.usageGate)
        Task.detached(priority: .utility) {
            for await operation in stream {
                switch operation {
                case .record(let event, let date, let epoch): await created.record(event, at: date, epoch: epoch)
                case .recordOnDay(let event, let day, let epoch): await created.record(event, onDay: day, epoch: epoch)
                case .tidy: created.collectGarbage()
                case .barrier(let done): done()
                }
            }
        }
        settings.onUsageSwitchChange = { [weak self] isOn in self?.switchChanged(isOn) }
        settings.onUsageNoticeSeen = { [weak self] in self?.noticeBecameSeen() }
    }

    /// The metrics folder, once it is known to be safe to use; nil keeps the recorder inert for this
    /// run (a later launch tries again). Where the folders on disk came from is checked before
    /// anything can be recorded: if no epoch was saved, or it is lower than a folder that exists
    /// (defaults reset or restored), the epoch starts above all of them, and everything older is
    /// deleted right now. A folder that exists but cannot be listed, or a clean-up that fails, is
    /// not "nothing there": it fails closed.
    private static func readyStore(settings: AppSettings, directory: URL) -> MetricsDataStore? {
        let store = MetricsDataStore(root: directory)
        guard case .readable(let highest) = store.scan() else { return nil }
        settings.reconcileUsageEpoch(highestFolder: highest)
        guard store.collectGarbage(keeping: settings.usageGate.epoch) == 0 else { return nil }
        return store
    }

    var isCollecting: Bool { settings.isSharingUsageNumbers && service != nil }

    /// Home shows its one-time notice to an install that finished setup before this existed.
    var needsNotice: Bool { service != nil && settings.hasCompletedOnboarding && !settings.usageNumbersNoticeSeen }

    // MARK: - Lifecycle

    /// Starts the daily close-and-upload loop and tidies away the folders of earlier epochs
    /// (whatever an off, or an earlier run, left behind). Safe to call once at launch.
    func start() {
        guard service != nil, loopTask == nil else { return }
        operations.yield(.tidy)
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.firstLoopDelay)
            while !Task.isCancelled {
                await self?.runDailyJobs()
                try? await Task.sleep(for: Self.loopInterval)
            }
        }
    }

    /// The switch changed (the gate and its epoch already reflect it). Off: forget what is waiting
    /// for an edit verdict and tidy the folders of earlier epochs. Nothing depends on the tidying
    /// being done or succeeding: the old epoch is unreachable already.
    private func switchChanged(_ isOn: Bool) {
        guard !isOn else { return }
        pending.discardAll()
        operations.yield(.tidy)
    }

    /// First sight of the notice on a fresh install: the setup steps already reached are counted once.
    private func noticeBecameSeen() {
        guard !settings.hasCompletedOnboarding else { return }
        for (event, date) in settings.onboardingFunnel.timestamps { recordFunnel(event, at: date) }
    }

    // MARK: - Recording

    /// Records one event, off the main actor, and returns immediately. Does nothing while off.
    func record(_ event: MetricEvent, at date: Date = Date()) {
        let epoch = settings.usageGate.epoch
        guard settings.usageGate.allows(epoch: epoch), service != nil else { return }
        operations.yield(.record(event, date, epoch: epoch))
    }

    func recordDictation(_ input: DictationMetricInput) {
        guard settings.usageGate.isOn else { return }
        do {
            record(.dictation(try input.event()))
        } catch {
            log.error("usage metrics: dictation event rejected (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    func recordFunnel(_ event: OnboardingFunnel.Event, at date: Date = Date()) {
        record(.funnel(FunnelStep(event)), at: date)
    }

    // MARK: - Dictations waiting for the edit verdict

    /// Holds a pasted dictation until the edit watcher reports or its window closes. Nil when off.
    func holdDictation(_ input: DictationMetricInput) -> UUID? {
        guard settings.usageGate.isOn, service != nil, !isStoppedForUninstall else { return nil }
        let token = pending.hold(input, at: Date(), epoch: settings.usageGate.epoch)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PendingDictationMetrics.window + 1))
            self?.releaseExpired()
        }
        return token
    }

    func resolveDictation(
        _ token: UUID, verdict: DictationEditObservation.Verdict, coverage: DictationEditObservation.Coverage,
        size: MetricsEditSize = .none
    ) {
        let observation = DictationFeedback.EditObservation(rawValue: verdict.rawValue) ?? .unknown
        let reason = DictationFeedback.EditCoverage(rawValue: coverage.rawValue) ?? .notAttempted
        if let released = pending.resolve(token, observation: observation, coverage: reason, size: size, at: Date()) { record(released) }
    }

    private func releaseExpired() { pending.expire(at: Date()).forEach(record) }

    /// A released dictation is written to the day it was held on, in the epoch it was held in.
    private func record(_ released: PendingDictationMetrics.Released) {
        guard settings.usageGate.allows(epoch: released.epoch), service != nil else { return }
        operations.yield(.recordOnDay(.dictation(released.event), released.day, epoch: released.epoch))
    }

    /// The app is quitting: whatever is still waiting is recorded as not checked, and the queue is
    /// given a moment to reach the disk.
    func flushForQuit() {
        guard service != nil, !isStoppedForUninstall else { return }   // inert: nothing queued, and a barrier would never run
        pending.drain().forEach(record)
        let done = DispatchSemaphore(value: 0)
        operations.yield(.barrier { done.signal() })
        _ = done.wait(timeout: .now() + 1)
    }

    /// Uninstall: ends the daily loop, lets what is already queued be written, then takes
    /// nothing more, so the metrics folder is not written again after it has been removed.
    ///
    /// - Parameter isStillWanted: asked at the last moment, before the queue is closed for good.
    ///   The waiting above can outlast the uninstall's patience; if the uninstall was abandoned
    ///   meanwhile the answer is false, the queue stays open and the daily loop starts again.
    func stopForUninstall(isStillWanted: () -> Bool = { true }) async {
        let loop = loopTask
        loopTask = nil
        loop?.cancel()
        await loop?.value
        pending.discardAll()
        guard service != nil, !isStoppedForUninstall else { return }
        await flush()
        guard isStillWanted() else {
            start()
            return
        }
        isStoppedForUninstall = true
        operations.finish()
    }

    /// Waits until everything queued so far has been handled (tests, and before reading back).
    func flush() async {
        // An inert recorder (no folder, or another process holds it) has a finished stream: a barrier
        // yielded to it would never run and this would wait forever. Nothing is queued, so nothing to wait for.
        guard service != nil, !isStoppedForUninstall else { return }
        await withCheckedContinuation { continuation in operations.yield(.barrier { continuation.resume() }) }
    }

    // MARK: - "See what's sent"

    /// Today's numbers in plain sentences, or empty when nothing has been recorded today (or sharing is off).
    func todaysLines() async -> [String] {
        guard let batch = await todaysBatch() else { return [] }
        return MetricsDisclosure.lines(for: batch, isPreview: true)
    }

    /// The same numbers grouped into titled sections, every field the batch holds.
    func todaysSections() async -> [MetricsDisclosure.Section] {
        guard let batch = await todaysBatch() else { return [] }
        return MetricsDisclosure.sections(for: batch, isPreview: true)
    }

    private func todaysBatch() async -> DailyMetricsBatch? {
        let epoch = settings.usageGate.epoch
        guard settings.usageGate.allows(epoch: epoch), let service else { return nil }
        await flush()
        let batch = await service.previewToday(now: Date())
        afterPreviewReadHook?()
        // Off (and maybe on again) while this was being read: the answer belongs to an old epoch.
        return settings.usageGate.allows(epoch: epoch) ? batch : nil
    }

    // MARK: - Daily

    /// Closes elapsed days into the local queue, then offers the queue to the uploader, which does
    /// nothing unless the switch is on, an endpoint is configured and no deletion is pending.
    @discardableResult
    func runDailyJobs(now: Date = Date()) async -> MetricsUploader.Report? {
        guard let service, let uploader, !isStoppedForUninstall else { return nil }
        // A dictation still waiting from an earlier day is written to that day (as not checked)
        // before the day is closed, so it can never slip onto the next one.
        pending.drainBefore(now).forEach(record)
        await flush()
        _ = await service.closeDays(now: now)
        return await uploader.uploadIfDue(now: now)
    }

    nonisolated static func bundleBuild() -> Int {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 1
    }
}
