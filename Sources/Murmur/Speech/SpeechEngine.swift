import FluidAudio
import Foundation
import MurmurCore
import Observation
import os

/// On-device speech recognition on the Apple Neural Engine via FluidAudio. Loads Parakeet
/// Ultra (the v3 family, 25 languages) for both language modes; in "English only" mode a
/// language-drift guard (`AsrDriftGuard`, MurmurCore) checks every whole-utterance result and,
/// when Ultra's language ID has drifted (non-English language or non-Latin script), re-transcribes
/// the same audio with Parakeet v2 — which has no language-ID step and cannot drift — and uses
/// that instead. On Macs above the small-memory tier, v2 starts loading in the background once
/// Ultra is ready; a first drift still loads it on demand if warming has not finished, but waits at most
/// the wait `FallbackWaitPolicy` allows and otherwise keeps Ultra's result. Each fallback is logged as
/// `asr.drift_fallback` (a running count and reason, never content). See .claude/DECISIONS.md
/// (2026-09-26, "English default moves to Ultra with a drift guard") for the rationale and the
/// acceptance numbers.
///
/// Vocabulary boosting (names, jargon, acronyms from the user's Dictionary) runs as a second
/// pass after the primary TDT transcription: a small CTC 110M model ("Approach 2 / Separate CTC
/// Encoder" in FluidAudio's CustomVocabulary.md, the approach that works with any TDT model
/// including v2/Ultra) re-scores the transcript against the vocabulary and swaps in a term when
/// the acoustic evidence favors it. The CTC model's CoreML compile takes ~13 s the first time
/// it loads, so `BoostingSessionCache` warms it in the background as soon as the speech model is
/// ready and the CTC files are on disk (never downloading for that), and a dictation waits at
/// most `boostingWaitBound` for it: past that it goes out unboosted while the load carries on.
actor SpeechEngine: Transcriber {
    /// Kept only for the settings-row fallback label before a model has ever loaded; the model
    /// actually in use is `currentVersion`, driven by the caller's language mode.
    static let defaultModelVersion: AsrModelVersion = .ultra
    /// The English-only model the drift guard re-transcribes with. Never the primary model.
    static let driftFallbackVersion: AsrModelVersion = .v2

    enum EngineError: LocalizedError {
        case notReady
        /// The audio holds values that are not numbers: a faulty read of the microphone, which
        /// the recogniser would answer with words nobody said.
        case unreadableAudio

        var errorDescription: String? {
            switch self {
            case .notReady: "The speech model is still loading."
            case .unreadableAudio: "The microphone's audio could not be read."
            }
        }
    }

    private var manager: AsrManager?
    /// Whether `AsrDriftGuard` runs on whole-utterance results (English-only mode). Set by
    /// `prepare(version:driftGuard:)`; ignored when the primary model is already v2.
    private var driftGuardEnabled = false
    /// Parakeet v2's shared speculative/on-demand load.
    private let fallbackLoader: FallbackModelLoader<AsrManager>
    /// Running `asr.drift_fallback` count for this session, for the log line and for evals.
    private(set) var driftFallbackCount = 0
    /// The loaded weights, kept beside `manager`. They were shared with a while-speaking recogniser until
    /// 2026-10-12; nothing reads them now.
    private var loadedModels: AsrModels?
    private var loadTask: Task<Void, Error>?
    private(set) var currentVersion: AsrModelVersion?
    private let status: SpeechModelStatus
    private let log = Logger(subsystem: "app.hushy", category: "vocab-boosting")
    private let asrLog = Logger(subsystem: "app.hushy", category: "asr")

    /// How long one dictation waits for a boosting session that isn't built yet, when the CTC
    /// models are already loaded (so only the ~11 ms session rebuild for new terms is pending;
    /// 500 ms is ~40x that). When the models are not loaded the wait is zero: that load is
    /// ~13 s and must never sit inside a dictation (numbers: the custom-vocabulary
    /// handbook page).
    static let boostingWaitBound: Duration = .milliseconds(500)

    /// The CTC models (kept loaded) and the session built from them for one vocabulary; a
    /// Dictionary edit rebuilds only the session, never boosts stale terms.
    private let boosting: BoostingSessionCache<CtcModels, BoostingPasses>
    /// The vocabulary the app wants warm (Dictionary + built-ins), set by `AppModel`.
    private var warmVocabulary: VocabularyContext?

    /// Post-download checksum verification (see `SpeechModelIntegrity`).
    private let integrity: SpeechModelIntegrity
    /// The version the in-flight `loadTask` is loading (nil when none is).
    private var loadingVersion: AsrModelVersion?
    /// Bumped per load attempt so a cancelled attempt that is still unwinding can't overwrite
    /// the status of the attempt that replaced it.
    private var loadGeneration = 0
    /// Keeps the wake warm-up out of a transcription's way (see `rewarm`).
    private var warmupGate = WarmupGate()

    init(status: SpeechModelStatus, integrity: SpeechModelIntegrity = .live) {
        self.status = status
        self.integrity = integrity
        self.fallbackLoader = FallbackModelLoader(
            load: { try await Self.loadFallbackManager() },
            onWarmupEvent: { event in
                let log = Logger(subsystem: "app.hushy", category: "asr")
                switch event {
                case .started:
                    log.notice("asr.fallback_warmup started")
                case .finished(let milliseconds):
                    log.notice("asr.fallback_warmup finished duration_ms=\(milliseconds, format: .fixed(precision: 1))")
                }
            })
        self.boosting = BoostingSessionCache(
            loadModels: { await Self.loadCtcModels(status: status) },
            buildSession: { models, vocabulary in await Self.buildBoostingSession(models: models, vocabulary: vocabulary) })
    }

    /// Downloads (first run only) and loads the model for `version`. Safe to call repeatedly;
    /// if `version` is already loaded (or loading), this returns/awaits that work instead of
    /// starting a redundant download. Switching versions (the language setting changed)
    /// replaces the loaded model but never deletes the previous version's cache — the user may
    /// switch back, and disk space for one extra model is a fair trade against re-downloading.
    ///
    /// `driftGuard` turns the English-only language-drift guard on for this model (see the type
    /// comment); it takes effect immediately even when `version` is already loaded, so flipping
    /// the language setting between two modes that share a model never needs a reload.
    func prepare(version: AsrModelVersion, driftGuard: Bool = false) async throws {
        driftGuardEnabled = driftGuard && version != Self.driftFallbackVersion
        if !driftGuardEnabled { await fallbackLoader.stopWarmup() }
        if currentVersion == version, manager != nil {
            await warmFallbackIfEligible()
            return
        }
        if let loadTask, loadingVersion == version { return try await loadTask.value }
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { try await self.load(version: version, generation: generation) }
        loadTask = task
        loadingVersion = version
        do {
            try await task.value
            if loadGeneration == generation { loadTask = nil; loadingVersion = nil }
        } catch {
            if loadGeneration == generation { loadTask = nil; loadingVersion = nil }
            throw error
        }
    }

    /// Stops an in-flight download (metered network, or the network went away). FluidAudio
    /// keeps the bytes it wrote in `<file>.partial` with their HTTP validator, so the next
    /// `prepare` resumes with a range request instead of starting over. No-op once the model is
    /// on disk and loading.
    func pauseDownload() async {
        guard let loadTask, loadingVersion != nil, await status.isDownloadingPrimary else { return }
        loadGeneration += 1
        loadTask.cancel()
        self.loadTask = nil
        loadingVersion = nil
        await status.markPaused()
    }

    var isModelCached: Bool {
        guard let version = currentVersion ?? loadingVersion else { return false }
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    static func isCached(_ version: AsrModelVersion) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    private func load(version: AsrModelVersion, generation: Int) async throws {
        let directory = AsrModels.defaultCacheDirectory(for: version)
        let cached = AsrModels.modelsExist(at: directory, version: version)
        // A model on disk whose checksum check is still owed is checked before it is loaded.
        await status.beginLoad(cached: cached, expectedBytes: Self.expectedDownloadBytes(for: version),
                               checksFirst: cached && integrity.isPending(version))
        do {
            let status = self.status
            let progress: ProgressHandler = { progress in Task { await status.report(progress) } }
            if !cached || integrity.isPending(version) {
                integrity.markPending(version)
                try await downloadVerified(version: version, directory: directory, progress: progress)
            }
            let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: progress)
            // The model's parts are in memory; what is left is setting it up and one silent pass.
            await status.beginWarmUp()
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            // Warm the Neural Engine so the first real dictation is as fast as the rest.
            var state = TdtDecoderState.make()
            _ = try? await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            guard generation == loadGeneration else { throw CancellationError() }
            manager = asr
            loadedModels = models
            currentVersion = version
            await status.markReady()
            Self.removeSupersededModels()
            warmBoostingIfReady()
            await warmFallbackIfEligible()
        } catch {
            // A pause (or a superseding attempt) is not a failure: `pauseDownload` already
            // reported it, and the partial bytes are kept for the resume.
            guard generation == loadGeneration, !Task.isCancelled, !(error is CancellationError) else { throw error }
            await status.markFailed(error)
            throw error
        }
    }

    /// Runs a second of silence through the loaded model, as `load` does, so the first dictation after the Mac
    /// wakes from sleep finds the Neural Engine warm. Does nothing when no model is loaded, a transcription is
    /// running or a warm-up already is. A transcription that starts meanwhile cancels the warm-up; the model checks
    /// for cancellation between its Core ML stages, so what the transcription can still wait for is the one stage
    /// already running on a one-second clip. Never throws: a failed warm-up costs nothing a dictation would not.
    func rewarm() async {
        guard let manager else { return }
        let silence = [Float](repeating: 0, count: 16_000)
        guard let warmup = warmupGate.startWarmup({
            var state = TdtDecoderState.make()
            _ = try? await manager.transcribe(silence, decoderState: &state)
        }) else { return }
        await warmup.value
        warmupGate.warmupEnded(warmup)
    }

    /// Downloads (resuming any partial files) and then checks every file against the checksums
    /// the host publishes. A corrupted model folder is deleted and fetched once more; a second
    /// mismatch fails loudly rather than loading a model that could transcribe garbage. When
    /// the checksum listing itself can't be fetched, the model is used (FluidAudio has already
    /// checked sizes) and verification stays pending for the next launch.
    private func downloadVerified(version: AsrModelVersion, directory: URL, progress: @escaping ProgressHandler) async throws {
        for attempt in 1...2 {
            _ = try await AsrModels.download(version: version, progressHandler: progress)
            switch await integrity.verify(version: version, directory: directory) {
            case .verified(let count):
                integrity.clearPending(version)
                asrLog.notice("speech model verified: \(count) files match their published checksums")
                return
            case .unverified(let reason):
                asrLog.error("speech model not verified yet (\(reason, privacy: .public)); will retry next launch")
                return
            case .corrupted(let paths):
                asrLog.error("speech model checksum mismatch in \(paths.count) file(s), attempt \(attempt)")
                SpeechModelIntegrity.removeCorrupted(paths, in: directory)
                if attempt == 2 { throw SpeechModelIntegrity.IntegrityError.corrupted }
            }
        }
    }

    /// Downloads the vocabulary-boosting model ahead of first use (queued after the speech
    /// model when the Dictionary has words), so the first dictation that needs it doesn't wait
    /// on ~98 MB. Doesn't touch `status`: the speech model stays "ready" throughout.
    func prefetchVocabularyModel() async throws {
        guard !CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m)) else { return }
        try await CtcModels.download(variant: .ctc110m)
        warmBoostingIfReady()
    }

    /// Tells the engine which vocabulary to keep warm (Dictionary + built-in terms) and starts
    /// warming it when possible. Called at launch and on every Dictionary edit.
    func setBoostingVocabulary(_ vocabulary: VocabularyContext) {
        warmVocabulary = vocabulary
        warmBoostingIfReady()
    }

    /// Starts building the boosting session in the background once the speech model is ready,
    /// the CTC files are already on disk and a vocabulary is known. Never downloads and never
    /// waits: with nothing on disk this does nothing (a dictation or the queued asset download
    /// brings the files, and calls this again).
    /// Builds the boosting session for one dictation's own vocabulary (Dictionary, built-ins and the terms read
    /// from the focused app) while the person is still speaking, so the pass after the key release finds it in place.
    /// Returns at once; the build runs on this actor's cache, never on the main thread. Does nothing without a loaded
    /// speech model, the CTC files on disk or any terms, so the release pass then behaves exactly as it did. A
    /// release that comes before the build is done joins it (`BoostingSessionCache.session` waits at most the same
    /// bound as before), and a vocabulary that differs from the one the release asks for is simply not used.
    func warmBoosting(for vocabulary: VocabularyContext) {
        guard manager != nil, !vocabulary.isEmpty, Self.isVocabularyModelCached else { return }
        let cache = boosting
        Task { await cache.warm(vocabulary) }
    }

    private func warmBoostingIfReady() {
        guard manager != nil, let warmVocabulary, !warmVocabulary.isEmpty, Self.isVocabularyModelCached else { return }
        let cache = boosting
        Task { await cache.warm(warmVocabulary) }
    }

    private func warmFallbackIfEligible() async {
        guard FallbackWarmupPolicy.shouldWarm(
            guardEnabled: driftGuardEnabled, primaryReady: manager != nil,
            physicalMemoryGB: MachineProfile.current().physicalMemoryGB) else { return }
        await fallbackLoader.warm()
    }

    static var isVocabularyModelCached: Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }

    /// Measured on-disk size of each model's files once downloaded (`du -sk` of FluidAudio's
    /// cache folder, decimal bytes), used only to turn FluidAudio's byte-weighted fraction into
    /// "N MB of about M MB" text — see `ModelDownloadProgress`. Update when a model is re-cut.
    static func expectedDownloadBytes(for version: AsrModelVersion) -> Int64 {
        switch version {
        case .v2: 465_000_000
        case .ultra: 632_000_000
        case .v3: 490_000_000
        default: 600_000_000
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples, vocabulary: .empty)
    }

    func transcribe(_ samples: [Float], vocabulary: VocabularyContext) async throws -> String {
        try await transcribeWithConfidence(samples, vocabulary: vocabulary).text
    }

    /// Confidence-aware entry point: `DictationPipeline`/`DictationController` use this so
    /// `SmartCleaner` can mark low-confidence words for the on-device model. Word confidences
    /// are computed from the *base* ASR pass's `tokenTimings` (before vocabulary boosting, which
    /// has no per-token confidence of its own) — a boosted word keeps the confidence its
    /// unboosted piece(s) had, which is a reasonable proxy since boosting only swaps text the
    /// acoustic evidence already supported.
    func transcribeWithConfidence(_ samples: [Float], vocabulary: VocabularyContext) async throws -> TranscriptionResult {
        // The last check before any recogniser, whoever recorded the audio.
        guard samples.allSatisfy(\.isFinite) else { throw EngineError.unreadableAudio }
        guard let manager else { throw EngineError.notReady }
        warmupGate.workStarted()
        await fallbackLoader.workStarted()
        defer {
            warmupGate.workFinished()
            let loader = fallbackLoader
            Task { await loader.workFinished() }
        }
        // Parakeet needs at least ~1 s of context; pad very short clips with silence.
        let minimum = 16_000
        let padded = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        // A boosting session already built for this vocabulary starts its CTC pass now, alongside the primary pass: it
        // reads only the audio, and the two overlap on the Neural Engine (2026-11-07, 90 paired takes: this stage p50
        // 218 → 151 ms, text identical). A session not built yet is looked up after the primary pass, as before.
        let ready = vocabulary.isEmpty ? nil : await boosting.readySession(for: vocabulary)
        let earlySpot = ready.map { passes in Task { await passes.spot(padded) } }
        var state = TdtDecoderState.make()
        var result: ASRResult
        do { result = try await manager.transcribe(padded, decoderState: &state) } catch { earlySpot?.cancel(); throw error }
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryText = text
        // English-only drift guard: same audio, re-transcribed with v2 when Ultra's output is
        // not English. Confidences/timings below are then v2's, which keeps them aligned with
        // the text actually used.
        if driftGuardEnabled, case .fallback(let reason) = AsrDriftGuard.decision(for: text),
           let recovered = await driftFallback(reason: reason, primary: result, samples: padded) {
            result = recovered
            text = recovered.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        noteRepeats(primary: primaryText, used: text)
        let confidences = result.tokenTimings.map(Self.wordConfidences)
        // Word-level timings (Phase 0 of docs/research/speaker-labeling.md): FluidAudio already
        // computes these per-token; carry them out instead of discarding them once confidence
        // is derived, so diarization can later align words to speaker turns by midpoint.
        let timings = result.tokenTimings.map(Self.wordTimings)

        guard !vocabulary.isEmpty, !text.isEmpty, let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            earlySpot?.cancel()
            return TranscriptionResult(text: text, confidences: confidences, timings: timings)
        }

        let boostStart = Date()
        let passes: BoostingPasses
        let readiness: BoostingReadiness
        if let ready {
            (passes, readiness) = (ready, .warm)
        } else {
            let bound = await boosting.loadedModels == nil ? Duration.zero : Self.boostingWaitBound
            let found = await boosting.session(for: vocabulary, waitingUpTo: bound)
            guard let session = found.session else {
                log.info("vocabulary boosting skipped, \(found.readiness.logMarker, privacy: .public) (terms: \(vocabulary.terms.count))")
                return TranscriptionResult(text: text, confidences: confidences, timings: timings)
            }
            (passes, readiness) = (session, found.readiness)
        }
        let spot = if let earlySpot { await earlySpot.value } else { await passes.spot(padded) }
        let rescored = spot.flatMap { passes.rescoredText(text, tokenTimings: tokenTimings, spot: $0) }
        let boostMs = Date().timeIntervalSince(boostStart) * 1000
        log.info("vocabulary boosting \(readiness.logMarker, privacy: .public)\(earlySpot == nil ? "" : " alongside", privacy: .public), took \(boostMs, format: .fixed(precision: 1)) ms after the primary pass (terms: \(vocabulary.terms.count))")

        guard let rescored else { return TranscriptionResult(text: text, confidences: confidences, timings: timings) }
        let boostedText = vocabulary.guarded(original: text, boosted: rescored.trimmingCharacters(in: .whitespacesAndNewlines))
        let beforeBoost = RepeatTrace(text), afterBoost = RepeatTrace(boostedText)
        if RepeatTrace.added(from: beforeBoost, to: afterBoost) {
            log.notice("\(RepeatTrace.line(stage: "boost", from: beforeBoost, to: afterBoost), privacy: .public)")
        }
        // The spotter also reports terms it only detected, with the text unchanged: nothing moved, so
        // the confidences and word timings still line up. Dropping them here left every note chunk
        // without timings, so diarization never started (mock-mic, 2026-10-05).
        if boostedText == text { return TranscriptionResult(text: text, confidences: confidences, timings: timings) }
        // Boosting can change word count/order (a term swapped in for a mis-heard phrase), so
        // confidences/timings computed against the pre-boost text no longer line up positionally
        // with `boostedText`; `SmartCleaner`'s own raw-to-draft realignment (`ConfidenceSpans`)
        // only handles the rules stage, not this. Rather than attach confidences/timings that
        // would silently misalign, drop them for the (rare — vocabulary is usually empty)
        // boosted case.
        return TranscriptionResult(text: boostedText, confidences: nil, timings: nil, unboosted: text)
    }

    /// The pill's live draft (`LiveDraftSession`): the primary model over a few seconds of audio, and nothing else.
    /// No drift guard, no vocabulary boosting and no repeat log, so a draft stays one short pass; its text is only
    /// ever shown in the pill, never pasted. It counts as real work, so a wake warm-up stays out of its way.
    func draftTranscript(_ samples: [Float]) async throws -> String {
        guard samples.allSatisfy(\.isFinite) else { throw EngineError.unreadableAudio }
        guard let manager else { throw EngineError.notReady }
        warmupGate.workStarted()
        defer { warmupGate.workFinished() }
        let minimum = 16_000
        let padded = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make()
        return try await manager.transcribe(padded, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counts only, to name the stage that wrote a repeated ending: the first recogniser's own text, or the second one's.
    private func noteRepeats(primary: String, used: String) {
        let first = RepeatTrace(primary)
        if first.isLoopedRecogniserText {
            log.notice("\(RepeatTrace.looped(stage: "recogniser", first), privacy: .public)")
        }
        let second = RepeatTrace(used)
        if used != primary, RepeatTrace.added(from: first, to: second) {
            log.notice("\(RepeatTrace.line(stage: "drift-fallback", from: first, to: second), privacy: .public)")
        }
    }

    /// Re-transcribes `samples` with Parakeet v2 after `AsrDriftGuard` flagged the primary
    /// result, and returns v2's result when it is the one to use. Returns nil (never throws) when
    /// the primary result stands: v2's text was not accepted, v2 could not be loaded or failed on
    /// this clip, or v2 was not loaded within the wait `FallbackWaitPolicy` gives its load. In the
    /// last case the load carries on for the next dictation; a dictation is never held for a long
    /// model load. Logs `asr.drift_fallback` with a count, the reason and a state word only, never
    /// transcript content.
    private func driftFallback(reason: AsrDriftGuard.Reason, primary: ASRResult, samples: [Float]) async -> ASRResult? {
        let loadRunningFor = await fallbackLoader.loadRunningFor
        let bound = FallbackWaitPolicy.bound(loadRunningFor: loadRunningFor)
        let answer = await DriftFallbackStep.run(
            primary: primary, loader: fallbackLoader, waitingUpTo: bound,
            transcribe: { fallback in
                var state = TdtDecoderState.make()
                return try await fallback.transcribe(samples, decoderState: &state)
            },
            accepts: { primary, fallback in
                AsrDriftGuard.acceptsFallback(
                    primary: primary.text.trimmingCharacters(in: .whitespacesAndNewlines), fallback: fallback.text)
            })
        switch answer.outcome {
        case .used, .rejected:
            driftFallbackCount += 1
            asrLog.notice("asr.drift_fallback count=\(self.driftFallbackCount) reason=\(reason.rawValue, privacy: .public)")
        case .notReady:
            let waited = CaptureTiming.milliseconds(bound)
            let running = loadRunningFor.map { String(CaptureTiming.milliseconds($0)) } ?? "not_started"
            asrLog.notice(
                "asr.drift_fallback skipped cause=\(answer.outcome.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) waited_ms=\(waited, privacy: .public) load_running_ms=\(running, privacy: .public)")
        case .failed:
            asrLog.error("asr.drift_fallback failed (reason=\(reason.rawValue, privacy: .public)): \(answer.failure ?? "")")
        }
        return answer.outcome == .used ? answer.result : nil
    }

    /// The slow step is the download and compile. Past it the load always finishes, so a cancel
    /// that arrives late (the guard turned off) does not throw a loaded model away.
    private static func loadFallbackManager() async throws -> AsrManager {
        try await FallbackLoadSteps.run(
            slow: { try await AsrModels.downloadAndLoad(version: driftFallbackVersion) },
            finish: { models in
                let asr = AsrManager(config: .default)
                try await asr.loadModels(models)
                var state = TdtDecoderState.make()
                _ = try? await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
                return asr
            })
    }

    /// Aggregates FluidAudio's per-token confidences into per-word confidences using the
    /// framework's own SentencePiece word-boundary helpers, so grouping stays identical to how
    /// FluidAudio's own `buildWordTimings` groups the same tokens. See `WordConfidenceAggregator`
    /// for why `min` (not mean) is used to combine a word's piece confidences.
    static func wordConfidences(from tokenTimings: [TokenTiming]) -> [WordConfidence] {
        let usable = tokenTimings.filter { !$0.token.isEmpty && $0.token != "<blank>" && $0.token != "<pad>" }
        return WordConfidenceAggregator.aggregate(
            pieces: usable.map(\.token), confidences: usable.map(\.confidence),
            isWordStart: isWordBoundary, stripBoundary: stripWordBoundaryPrefix)
    }

    /// Aggregates FluidAudio's per-token start/end times into per-word timings using the exact
    /// same word-boundary grouping as `wordConfidences`, so a word's confidence and timing
    /// always refer to the same span of pieces. Clip-relative seconds — the caller (`NoteRecorder`)
    /// is responsible for adding each chunk's offset to get note-relative timestamps.
    static func wordTimings(from tokenTimings: [TokenTiming]) -> [MurmurCore.WordTiming] {
        let usable = tokenTimings.filter { !$0.token.isEmpty && $0.token != "<blank>" && $0.token != "<pad>" }
        return WordTimingAggregator.aggregate(
            pieces: usable.map(\.token), startTimes: usable.map(\.startTime), endTimes: usable.map(\.endTime),
            isWordStart: isWordBoundary, stripBoundary: stripWordBoundaryPrefix)
    }

    var isReady: Bool { manager != nil }

    /// Downloads the CTC files when missing (a dictation needing them, not a warm-up), then loads
    /// them. Nil (never throws) on any failure: boosting is best-effort and must never break
    /// transcription (matches `VocabularyBoostingSession.rescore`'s absorb-and-log contract).
    private static func loadCtcModels(status: SpeechModelStatus) async -> CtcModels? {
        do {
            let cached = CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
            if !cached { await status.downloadingVocabularyModel(0) }
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            if !cached { await status.downloadingVocabularyModel(nil) }
            return models
        } catch {
            NSLog("Hushy: vocabulary boosting model load failed: \(error.localizedDescription)")
            await status.downloadingVocabularyModel(nil)
            return nil
        }
    }

    private static func buildBoostingSession(models: CtcModels, vocabulary: VocabularyContext) async -> BoostingPasses? {
        let terms = vocabulary.terms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) }
        // Dictionary vocabularies are small (a handful of names/terms) — exactly the
        // profile FluidAudio's CustomVocabulary.md warns overfires with the acoustic
        // spotter-rescue on: `murmur-eval vocab` measured ~70-93% false insertions on a
        // LibriSpeech distractor set with it left on. Disabling it costs some recall on
        // heavily-mangled names but is the safer default; see .claude/HANDOVER.md.
        let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
        do {
            let session = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: models, config: config)
            return try await BoostingPasses(session: session, models: models, config: config)
        } catch {
            NSLog("Hushy: vocabulary boosting session failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Earlier builds used Parakeet v3, superseded by Ultra; that ~470 MB copy is dead weight
    /// regardless of whether the current session is running v2 or Ultra, so it is always safe
    /// to remove. v2 and Ultra caches are never removed this way — the language setting can
    /// switch between them, and each switch should not force a re-download.
    private static func removeSupersededModels() {
        let old = AsrModels.defaultCacheDirectory(for: .v3)
        if FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
