import Foundation
import MurmurCore

/// One recording in progress: its journal, its sides, capture health and the bookkeeping that turns a stall into a
/// gap on the right side's clock. Owned by `NoteRecorder`; gone when the recording stops.
@MainActor
final class CaptureSession {
    enum Failure: Error { case noNote }

    let noteId: Int64
    let journal: CaptureJournalWriter
    let mic: any NoteAudioSource
    private(set) var callSource: (any NoteAudioSource)?
    var health: CaptureHealth
    private let began = ContinuousClock.now

    /// Samples each side delivered, and the gap seconds recorded for it, so a stalled side's missing time is known.
    private(set) var delivered: [CaptureStream: Int] = [.mic: 0]
    private(set) var gapSeconds: [CaptureStream: Double] = [.mic: 0]
    private(set) var sideStartedAt: [CaptureStream: Double] = [.mic: 0]
    var rebuilds = 0
    var lastRebuild: [CaptureStream: Double] = [:]
    /// Every health change in this recording, for the log and the harness.
    var events: [CaptureHealth.Event] = []
    var systemVerdictReached = false
    var lastPersistedDuration = 0.0
    /// When the last journal tick ran; a jump much longer than a tick is the Mac having slept.
    var lastTickAt = 0.0
    static let sleepJump: Double = 5
    private(set) var isCancelled = false

    /// Journal writes, strictly in tick order.
    private(set) var writes: Task<Void, Never>?
    /// Live recognitions of sealed segments, strictly in order.
    var recognitions: Task<Void, Never>?

    /// The most rebuilds one recording makes, both sides together, and the shortest wait between two of one side.
    static let maxRebuilds = 8
    static let rebuildCooldown: Double = 10
    /// A stalled side's shortfall below this is buffering, not a gap.
    static let minimumGap: Double = 1.5

    init(noteId: Int64, journal: CaptureJournalWriter, mic: any NoteAudioSource) {
        self.noteId = noteId
        self.journal = journal
        self.mic = mic
        health = CaptureHealth(streams: [.mic], startedAt: 0)
    }

    func elapsed() -> Double {
        let parts = (ContinuousClock.now - began).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// The call side came up `now` seconds into the recording; its clock starts there.
    func attachCall(_ source: any NoteAudioSource, at now: Double) {
        callSource = source
        delivered[.system] = 0
        gapSeconds[.system] = 0
        sideStartedAt[.system] = now
        var health = CaptureHealth(streams: [.mic, .system], startedAt: 0)
        health.restarted(.system, at: now)
        self.health = health
    }

    /// Counts a tick's delivery and feeds capture health.
    func account(mic samples: [Float], call: [Float]?, at now: Double) {
        observe(.mic, samples, at: now)
        if let call, callSource != nil { observe(.system, call, at: now) }
    }

    private func observe(_ stream: CaptureStream, _ samples: [Float], at now: Double) {
        delivered[stream, default: 0] += samples.count
        let allZero = !samples.isEmpty && samples.allSatisfy { $0 == 0 }
        health.observe(stream, samples: samples.count, allZero: allZero, rms: StreamingResampler.rms(samples), at: now)
    }

    /// How far a side's audio trails the wall clock, net of the gaps already recorded.
    func shortfall(_ stream: CaptureStream, at now: Double) -> Double {
        let heard = Double(delivered[stream] ?? 0) / AudioCapture.sampleRate + (gapSeconds[stream] ?? 0)
        return now - (sideStartedAt[stream] ?? 0) - heard
    }

    /// Records the side's shortfall as a gap (a stall it has come back from, or that lasted to the stop).
    func recordGap(_ stream: CaptureStream, at now: Double, reason: CaptureSegment.GapReason, then: @escaping @MainActor ([CaptureJournalWriter.Sealed]) -> Void) {
        let missing = shortfall(stream, at: now)
        guard missing >= Self.minimumGap else { return }
        gapSeconds[stream, default: 0] += missing
        let journal = self.journal
        chain {
            guard let sealed = try? await journal.gap(stream, seconds: missing, reason: reason) else { return }
            then(sealed)
        }
    }

    func source(_ stream: CaptureStream) -> (any NoteAudioSource)? { stream == .system ? callSource : mic }

    /// Queues journal work after everything queued before it.
    func chain(_ work: @escaping @MainActor () async -> Void) {
        let previous = writes
        writes = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func waitForWrites() async { await writes?.value }

    func stopSources() async {
        await mic.stop()
        await callSource?.stop()
    }

    func cancel() {
        isCancelled = true
        recognitions?.cancel()
    }
}
