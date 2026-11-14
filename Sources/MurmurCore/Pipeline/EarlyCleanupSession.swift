import Foundation
import Synchronization

/// Hears a dictation while it is still being spoken and has its closed sentence groups cleaned, so that less is left
/// to do after the key release.
///
/// Every so often (`EarlyPassSchedule`) the recogniser takes one pass over the whole recording so far: the same pass,
/// with the same loudness normalisation, that runs over the whole recording after the release, so the two transcripts
/// agree wherever the speech was already complete. The transcript's closed groups (`EarlyCleanupQueue`: all but the
/// last) are cleaned one at a time through `DictationPipeline.cleanEarly`, under the options the release will use.
///
/// It only ever saves time. The release still runs its own pass and cleans that transcript in its own groups; a group
/// cleaned here is reused only where its text is exactly the same (`SmartCleaner.cleanEarly`). So nothing here has
/// to be right: a pass that mishears, a group that later changes, a session that never runs, all end in the text the
/// release would have produced anyway.
public actor EarlyCleanupSession {
    /// One pass over loudness-normalised 16 kHz audio: the call the release makes for the whole recording.
    public typealias Recognise = @Sendable (_ samples: [Float]) async throws -> String

    private let pipeline: DictationPipeline
    private let settings: PipelineSettings
    private let detectsLanguage: Bool
    private let recognise: Recognise
    private let sampleRate: Double
    /// False when these settings ask no model (As spoken, a code context): then there is nothing to clean ahead.
    private let isUseful: Bool
    private var schedule: EarlyPassSchedule
    private var queue: EarlyCleanupQueue
    private var samples: [Float] = []
    /// The cleaner's token for this dictation, once a pass has heard something.
    private var token: Int?
    /// Set from outside the actor, so the key release takes effect at once and not when the actor is next free.
    private let closed = Mutex(false)
    private var isClosed: Bool { closed.withLock { $0 } }
    private var isCleaning = false
    private var latest: PipelineSettings
    /// Passes (each with the cleaning that follows it) started and not yet finished.
    private var running = 0

    /// Groups handed to the model so far.
    public var groupsStarted: Int { queue.started.count }
    /// Recogniser passes started so far.
    public var passes: Int { schedule.passes }

    public init(
        pipeline: DictationPipeline, settings: PipelineSettings, detectsLanguage: Bool,
        schedule: EarlyPassSchedule = EarlyPassSchedule(), sightings: Int = 1, sampleRate: Double = 16_000,
        recognise: @escaping Recognise
    ) {
        self.pipeline = pipeline
        self.settings = settings
        self.detectsLanguage = detectsLanguage
        self.recognise = recognise
        self.sampleRate = sampleRate
        self.schedule = schedule
        self.queue = EarlyCleanupQueue(sightings: sightings)
        self.latest = settings
        let (_, options) = DictationPipeline.cleanerInputs(settings)
        self.isUseful = SmartCleaner.strategy(for: options.level) != .rules && !options.isCodeContext
    }

    /// More of the recording. Starts a pass over all of it when one is due.
    public func add(_ fresh: [Float]) {
        guard !isClosed, isUseful else { return }
        samples.append(contentsOf: fresh)
        guard schedule.start(at: Double(samples.count) / sampleRate) else { return }
        let snapshot = samples
        running += 1
        Task {
            await self.pass(over: snapshot)
            self.running -= 1
        }
    }

    /// The key is up: no further pass, no further group. Takes effect at once, from any thread. A pass or a model
    /// call already running is left to finish; nothing new starts.
    public nonisolated func close() {
        closed.withLock { $0 = true }
    }

    /// The dictation is over (delivered, failed or thrown away): what was cleaned ahead for it is dropped.
    public func end() async {
        close()
        samples = []
        guard let token else { return }
        self.token = nil
        await pipeline.endEarlyCleaning(token)
    }

    /// Returns once no pass and no cleaning started so far is still running (the tests wait on this).
    public func settle() async {
        while running > 0 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    private func pass(over snapshot: [Float]) async {
        let heard = (try? await recognise(LoudnessNormalizer.normalize(snapshot)))?.trimmingCharacters(in: .whitespacesAndNewlines)
        schedule.finished()
        guard !isClosed, let heard, !heard.isEmpty else { return }
        if token == nil {
            let opened = await pipeline.openEarlyCleaning()
            // The key may have come up while the cleaner was being opened.
            guard !isClosed else {
                await pipeline.endEarlyCleaning(opened)
                return
            }
            token = opened
        }
        latest = settings.detectingLanguage(in: heard, enabled: detectsLanguage).settings
        queue.heard(pipeline.earlyTranscript(heard, settings: latest))
        await cleanWaitingGroups()
    }

    /// One group at a time, oldest first. A pass that lands while this runs only adds to the queue.
    private func cleanWaitingGroups() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        while !isClosed, let group = queue.next() {
            await pipeline.cleanEarly(group: group, settings: latest)
        }
    }
}

extension PipelineSettings {
    /// The settings one transcript is cleaned under: these, with the language found in the transcript when detection
    /// is on. One place, so cleaning ahead of the release and the release itself decide it the same way.
    public func detectingLanguage(in raw: String, enabled: Bool) -> (settings: PipelineSettings, language: DetectedLanguage?) {
        let language = enabled ? LanguageDetector.detect(raw) : nil
        var copy = self
        copy.cleanupOptions.detectedLanguage = language?.code
        return (copy, language)
    }
}
