import FluidAudio
import Foundation
import MurmurCore
import Observation
import os

/// Observable model status for the UI (download progress, errors).
///
/// FluidAudio reports one `DownloadProgress` stream per `ModelHub.loadModels` call, and
/// `AsrModels.downloadAndLoad` makes several such calls (one per model file, then again to
/// load). The first call downloads the repo's whole required set, running 0 →
/// `fluidAudioDownloadPhaseWeight` while bytes arrive, then on to 1.0 while CoreML compiles;
/// later calls find the cache warm and emit the download phase as already complete with
/// `totalFiles == 0`. `report(_:)` folds that into the two states users understand: downloading
/// (byte-weighted, with bytes/ETA) and loading.
///
/// Throughput is measured passively from those same byte counts (`ThroughputMeter`) and the
/// time left is smoothed (`ETASmoother`) so the line never jumps; `tick(now:)` (called once a
/// second by `DownloadCoordinator`) keeps both honest through a stall, when FluidAudio sends no
/// callbacks at all. The byte count shown never goes backwards within an attempt.
@MainActor
@Observable
final class SpeechModelStatus {
    /// `ModelHub.loadModels` splits each operation's fraction 50/50 between downloading and
    /// compiling (`ProgressReporter(downloadPhaseWeight: 0.5)` in FluidAudio). Dividing the
    /// download-phase fraction by this gives the real 0…1 share of bytes received.
    private static let fluidAudioDownloadPhaseWeight = 0.5

    /// Why the last load failed, split into the one case with its own remedy (offline).
    struct Failure: Equatable {
        let isOffline: Bool
        let message: String

        var userMessage: String {
            isOffline
                ? "You're offline. The speech model (a one-time download) needs an internet connection — connect and try again."
                : message
        }
    }

    /// Live download detail while `state` is `.downloading` (or `.paused` with bytes kept).
    private(set) var download: ModelDownloadProgress?
    /// Set when `state` is `.failed`, cleared by the next attempt.
    private(set) var failure: Failure?
    /// When the model last became ready in this process (the onboarding funnel reads it).
    private(set) var readyAt: Date?
    /// When the current download's bytes started / finished arriving (funnel).
    private(set) var downloadStartedAt: Date?
    private(set) var downloadFinishedAt: Date?
    /// Whether the last load had to download (false: loaded from FluidAudio's cache).
    private(set) var lastLoadDownloaded = false
    /// How far the load of a model that is on disk has got: its stage, and what this Mac's
    /// earlier launches say about how long it takes (`SpeechLoadProgress`). Nil outside a load.
    private(set) var loadProgress: SpeechLoadProgress?
    /// Where load times are remembered. Nil (tests, tools) remembers nothing and reads nothing;
    /// the app sets it once at launch.
    @ObservationIgnored let loadTimes: SpeechLoadTimesStore?
    @ObservationIgnored private(set) var meter = ThroughputMeter()
    @ObservationIgnored private var smoother = ETASmoother()
    @ObservationIgnored private var expectedBytes: Int64 = 0
    @ObservationIgnored private var cached = false
    @ObservationIgnored private var fraction: Double = 0
    @ObservationIgnored private var files: (completed: Int, total: Int) = (0, 0)

    /// Measured download throughput (bytes/s) once warmed up.
    var bytesPerSecond: Double? { meter.bytesPerSecond }

    /// Called by `SpeechEngine` before a download/load attempt starts. A resumed attempt keeps
    /// the meter (the connection hasn't changed) but restarts the smoother from fresh numbers.
    func beginLoad(cached: Bool, expectedBytes: Int64, checksFirst: Bool = false, now: Date = Date()) {
        if expectedBytes != self.expectedBytes {
            // A different model (the language setting changed): its bytes start from zero.
            fraction = 0
            meter = ThroughputMeter()
        }
        self.cached = cached
        self.expectedBytes = expectedBytes
        failure = nil
        lastLoadDownloaded = !cached
        loadProgress = nil
        if cached {
            download = nil
            beginStages(checksFirst ? .checking : .loading, now: now)
            state = .loading
            return
        }
        if downloadStartedAt == nil { downloadStartedAt = now }
        smoother = ETASmoother()
        download = ModelDownloadProgress(fraction: fraction, expectedBytes: expectedBytes)
        state = .downloading(fraction)
    }

    /// Folds a FluidAudio progress tick into `state`/`download` (see the type comment).
    func report(_ progress: DownloadProgress, now: Date = Date()) {
        switch progress.phase {
        case .listing:
            if !cached { state = .downloading(fraction) }
        case .downloading(let completedFiles, let totalFiles):
            // `totalFiles == 0` is FluidAudio's "already cached" emission for a later
            // per-file load call; it carries no bytes and must not flip a loading model back
            // to "downloading".
            guard totalFiles > 0, !cached else { return }
            let reported = min(progress.fractionCompleted / Self.fluidAudioDownloadPhaseWeight, 1)
            fraction = max(fraction, reported)
            files = (completedFiles, totalFiles)
            meter = meter.observing(totalBytes: receivedBytes, at: now)
            publish(now: now)
        case .compiling(let modelName):
            if !cached, downloadFinishedAt == nil { downloadFinishedAt = now }
            download = nil
            // Core ML has started on a part of the model: the load is in its loading stage.
            if loadProgress == nil { beginStages(.loading, now: now) }
            loadProgress?.enter(.loading, at: now)
            if !modelName.isEmpty { loadProgress?.partStarted() }
            state = .loading
        }
    }

    /// The model is in memory and the engine is warming it up; ready comes next.
    func beginWarmUp(now: Date = Date()) {
        loadProgress?.enter(.warming, at: now)
    }

    private func beginStages(_ stage: SpeechLoadStage, now: Date) {
        let times = loadTimes?.read()
        let first = times.map { $0.isFirstLaunch(of: loadTimes?.build ?? "") } ?? false
        loadProgress = SpeechLoadProgress(
            stage: stage, startedAt: now, usual: times?.usual(firstOfBuild: first), isFirstLaunchOfBuild: first)
    }

    /// Once a second while downloading: samples the byte count (so a stall pulls the rate
    /// down) and lets the shown time left count down.
    func tick(now: Date = Date()) {
        guard case .downloading = state else { return }
        meter = meter.observing(totalBytes: receivedBytes, at: now)
        publish(now: now)
    }

    private var receivedBytes: Int64 { Int64((Double(expectedBytes) * fraction).rounded()) }

    private func publish(now: Date) {
        let raw = meter.secondsRemaining(forBytes: max(0, expectedBytes - receivedBytes))
        smoother = smoother.observing(rawSeconds: raw, at: now)
        download = ModelDownloadProgress(
            fraction: fraction, expectedBytes: expectedBytes,
            completedFiles: files.completed, totalFiles: files.total,
            estimatedSecondsRemaining: smoother.seconds)
        state = .downloading(fraction)
    }

    func markReady(now: Date = Date()) {
        // How long each stage took goes into this Mac's load times, for the next launch's estimate.
        if let progress = loadProgress, let loadTimes {
            do {
                try loadTimes.add(progress.durations(endingAt: now), firstOfBuild: progress.isFirstLaunchOfBuild)
            } catch {
                Logger(subsystem: "app.hushy", category: "speech-model").error("load times not saved: \(error.localizedDescription)")
            }
        }
        loadProgress = nil
        download = nil
        fraction = 0
        failure = nil
        readyAt = now
        if lastLoadDownloaded, downloadFinishedAt == nil { downloadFinishedAt = readyAt }
        state = .ready
    }

    /// The download was stopped on purpose (metered network, or the network went away and the
    /// coordinator will resume it). Partial bytes stay on disk; the bar keeps its place.
    func markPaused() {
        failure = nil
        loadProgress = nil
        if let download {
            self.download = ModelDownloadProgress(
                fraction: download.fraction, expectedBytes: download.expectedBytes,
                completedFiles: download.completedFiles, totalFiles: download.totalFiles)
        }
        state = .paused
    }

    func markFailed(_ error: Error) {
        let offline = Self.isOffline(error)
        loadProgress = nil
        failure = Failure(isOffline: offline, message: error.localizedDescription)
        // Keep the byte count (without an ETA) so a retry visibly continues where it stopped.
        if let download {
            self.download = ModelDownloadProgress(fraction: download.fraction, expectedBytes: download.expectedBytes)
        }
        state = .failed(offline ? "You're offline" : error.localizedDescription)
    }

    /// Snapshot rendering only: pins a state (and its download detail) without a real engine.
    func pinForSnapshot(_ newState: State, download: ModelDownloadProgress? = nil, failure: Failure? = nil,
                        loadProgress: SpeechLoadProgress? = nil) {
        state = newState
        self.loadProgress = loadProgress
        self.download = download
        self.failure = failure
    }

    /// True when the error chain contains a URLError that means "no usable network", at any
    /// depth (FluidAudio wraps the URLSession error in `DownloadError.downloadFailed`).
    static func isOffline(_ error: Error) -> Bool {
        if case DownloadError.networkDisabled = error { return true }
        if case DownloadError.downloadFailed(_, let underlying) = error { return isOffline(underlying) }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error, isOffline(underlying) { return true }
        return nsError.underlyingErrors.contains(where: isOffline)
    }

    enum State: Equatable {
        case idle
        case downloading(Double)
        /// Stopped with partial bytes kept: waiting for the network or for the user's OK on a
        /// metered connection (see `DownloadCoordinator`).
        case paused
        case loading
        case ready
        case failed(String)
        /// The vocabulary-boosting CTC model is downloading, shown alongside (never instead of)
        /// the primary speech model's own state — see `downloadingVocabularyModel(_:)`.
        case downloadingVocabulary(Double)
    }

    private(set) var state: State = .idle

    nonisolated init(loadTimes: SpeechLoadTimesStore? = nil) {
        self.loadTimes = loadTimes
    }

    func update(_ newState: State) {
        state = newState
    }

    /// Shows vocabulary-model download progress without disturbing whatever the primary speech
    /// model's state already was; clears back to that state (not necessarily `.ready`) when
    /// finished, so a vocabulary download that finishes before the primary model does not
    /// falsely report the whole engine ready.
    func downloadingVocabularyModel(_ progress: Double?) {
        guard let progress else {
            if case .downloadingVocabulary = state { state = previousState }
            return
        }
        if case .downloadingVocabulary = state {} else { previousState = state }
        state = .downloadingVocabulary(progress)
    }

    private var previousState: State = .idle

    var isReady: Bool { state == .ready }

    /// The primary model's bytes are arriving (pausable); false once it is compiling/loading.
    var isDownloadingPrimary: Bool {
        if case .downloading = state { return true }
        return false
    }

    /// What the pill says when a key press finds the speech model still loading into memory (every
    /// launch, for as long as that takes: seconds on a quiet Mac, longer on a busy one). Home's
    /// card says the same thing in a sentence (`DictationHeroCopy`); a test keeps the two in step.
    nonisolated static let loadingLine = SpeechLoadStage.loading.line

    var label: String {
        switch state {
        case .idle: "Speech model not loaded yet"
        case .downloading:
            // Short: this is also the pill's message when fn is pressed too early.
            download?.estimatedSecondsRemaining.map { "Speech model · about \(ModelDownloadProgress.formatRemaining($0)) left" }
                ?? "Downloading speech model"
        case .paused: "Speech model download paused"
        case .loading: loadProgress?.stage.line ?? Self.loadingLine
        case .ready: "Ready"
        case .failed(let message): "Model error: \(message)"
        case .downloadingVocabulary(let progress): "Downloading vocabulary model \(Int(progress * 100))%"
        }
    }
}
