import Foundation
import Synchronization

/// The pill's live words: while a dictation is spoken, about once a second the recogniser reads the last few seconds
/// of it (`LiveDraftSchedule`) and the words it hears go to the pill.
///
/// It is only a draft for the eye. Its words never reach the text that is pasted, cleaned or saved: that always comes
/// from the pass over the whole recording after the key release, and the early-cleaning passes are untouched. It
/// yields to all of them (`RecogniserLane`): a draft is skipped while any of them runs, and none starts once the key
/// is up (`close`). Its words stay in memory: they are handed to `onDraft` and never logged; `Stats` is counts and
/// milliseconds only.
public actor LiveDraftSession {
    /// One recogniser pass over loudness-normalised 16 kHz audio, for a draft only.
    public typealias Recognise = @Sendable (_ samples: [Float]) async throws -> String

    /// Counts and timings for the log line at the release. Never a word.
    public struct Stats: Sendable, Equatable {
        public var passes = 0
        public var skippedBusy = 0
        public var skippedSilent = 0
        public var failures = 0
        public var totalPassMs = 0.0
        public var longestPassMs = 0.0

        public var meanPassMs: Double { passes == 0 ? 0 : totalPassMs / Double(passes) }
    }

    /// Below this peak a window is digital silence (a Bluetooth headset sends zeros until its link is up): no pass.
    static let silencePeak: Float = 0.000_1

    private let lane: RecogniserLane
    private let recognise: Recognise
    private let onDraft: @Sendable (String) -> Void
    private let sampleRate: Double
    private let passDeadline: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var schedule: LiveDraftSchedule
    private var tail: [Float] = []
    private var captured = 0
    private var inFlight: Task<Void, Never>?
    /// A pass passed its deadline: the recogniser is stalled, so no more drafts are started for this recording.
    private var recogniserStalled = false
    private let closed = Mutex(false)
    private var isClosed: Bool { closed.withLock { $0 } }
    public private(set) var stats = Stats()
    /// The latest draft text for this recording (never logged; used once at key release).
    public private(set) var latestDraft: String?

    public init(
        lane: RecogniserLane, schedule: LiveDraftSchedule = LiveDraftSchedule(), sampleRate: Double = 16_000,
        passDeadline: Duration = .seconds(5),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        recognise: @escaping Recognise, onDraft: @escaping @Sendable (String) -> Void
    ) {
        self.lane = lane
        self.schedule = schedule
        self.sampleRate = sampleRate
        self.passDeadline = passDeadline
        self.now = now
        self.recognise = recognise
        self.onDraft = onDraft
    }

    /// More of the recording. Keeps only the window, and starts a draft when one is due and the last has finished.
    public func add(_ fresh: [Float]) {
        guard !isClosed, !recogniserStalled, !fresh.isEmpty else { return }
        captured += fresh.count
        tail.append(contentsOf: fresh)
        let limit = schedule.windowSamples(sampleRate: sampleRate)
        if tail.count > limit { tail.removeFirst(tail.count - limit) }
        let seconds = Double(captured) / sampleRate
        guard schedule.isDue(at: seconds), inFlight == nil else { return }
        schedule.started(at: seconds)
        guard tail.contains(where: { abs($0) >= Self.silencePeak }) else {
            stats.skippedSilent += 1
            return
        }
        let snapshot = tail
        let clipped = captured > tail.count
        inFlight = Task { await self.pass(over: snapshot, clipped: clipped) }
    }

    /// The key is up (or the recording is gone): no draft starts from this instant, from any thread, and a draft
    /// already running is not shown.
    public nonisolated func close() {
        closed.withLock { $0 = true }
    }

    /// Closes, waits for a draft still running, lets the audio go, and returns the counts for the log.
    public func finish() async -> Stats {
        close()
        await inFlight?.value
        tail = []
        return stats
    }

    /// Returns once no draft is running (the tests wait on this).
    public func settle() async {
        await inFlight?.value
    }

    private func pass(over snapshot: [Float], clipped: Bool) async {
        defer { inFlight = nil }
        guard !isClosed else { return }
        guard await lane.claimDraft() else {
            stats.skippedBusy += 1
            return
        }
        let start = now()
        let heard: String?
        do {
            let recognise = self.recognise
            heard = try await Deadline.race(passDeadline) { try await recognise(LoudnessNormalizer.normalize(snapshot)) }
        } catch {
            heard = nil
            stats.failures += 1
            if error is DeadlineExpired { recogniserStalled = true }
        }
        await lane.releaseDraft()
        note(passTook: now() - start)
        guard !isClosed, let heard, let text = LiveDraftText.usable(heard, windowClipped: clipped) else { return }
        latestDraft = text
        onDraft(text)
    }

    private func note(passTook elapsed: Duration) {
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        stats.passes += 1
        stats.totalPassMs += ms
        stats.longestPassMs = max(stats.longestPassMs, ms)
    }
}
