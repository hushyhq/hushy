import Foundation

/// Pure helpers for keeping the microphone and system-audio chunk timelines aligned when a note
/// records both streams (see `.claude/DECISIONS.md`'s system-audio entry and
/// `docs/research/speaker-labeling.md`). The two streams are captured by independent engines
/// (`AVAudioEngine` for the mic, a Core Audio process tap or ScreenCaptureKit stream for system
/// audio) that can start a few milliseconds apart and can briefly drop buffers independently
/// (a device change on one side shouldn't corrupt the other), so chunk *counts* between the two
/// streams are not guaranteed to match exactly — this type computes what a caller (`NoteRecorder`)
/// needs to reconcile them without assuming they always will.
public enum ChunkAlignment {
    /// One stream's per-chunk sample count, used to compute that chunk's note-relative start
    /// offset the same way `NoteRecorder.chunkStartOffsets` already does for the mic-only case.
    public struct ChunkInfo: Sendable, Equatable {
        public let index: Int
        public let sampleCount: Int

        public init(index: Int, sampleCount: Int) {
            self.index = index
            self.sampleCount = sampleCount
        }
    }

    /// Note-relative start offset (seconds) for each chunk in `chunks`, in the same order,
    /// derived from a running sum of sample counts — identical math to what `NoteRecorder`
    /// already does for the mic stream, extracted here so both streams can share it and so it's
    /// unit-testable without spinning up a recorder.
    public static func startOffsets(chunks: [ChunkInfo], sampleRate: Double) -> [Int: Double] {
        var offsets: [Int: Double] = [:]
        var runningSamples = 0
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            offsets[chunk.index] = Double(runningSamples) / sampleRate
            runningSamples += chunk.sampleCount
        }
        return offsets
    }

    /// Given the mic stream's total captured duration and the system stream's, returns the
    /// amount (seconds) the shorter stream should be treated as "silent" for at its tail so both
    /// streams cover the same note-relative timeline when interleaving. A small mismatch is
    /// normal (one engine's watchdog restart, a final partial buffer) and should not be treated
    /// as an error; a large one likely means the system-audio side stopped capturing entirely
    /// (e.g. permission revoked mid-note) and callers may want to log that distinctly.
    public static func tailGap(micDurationSeconds: Double, systemDurationSeconds: Double) -> Double {
        abs(micDurationSeconds - systemDurationSeconds)
    }

    /// Threshold above which a mic/system duration mismatch is considered "the system stream
    /// effectively stopped," rather than ordinary jitter — used to decide whether to log a
    /// warning and fall back to mic-only interleaving for the untracked tail.
    public static let significantGapSeconds: Double = 2.0

    /// Whether two chunk sequences (by index) are "in step" — same count, same indices present
    /// — which is the common case. When `false`, a caller should fall back to aligning by
    /// note-relative time offsets (via `startOffsets`) rather than assuming chunk `i` from one
    /// stream corresponds to chunk `i` from the other.
    public static func chunksInStep(mic: [ChunkInfo], system: [ChunkInfo]) -> Bool {
        Set(mic.map(\.index)) == Set(system.map(\.index))
    }
}
