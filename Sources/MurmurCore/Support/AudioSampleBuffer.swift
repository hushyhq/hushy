import Foundation

/// A growable, chunked buffer for the audio tap's producer/consumer path, replacing an
/// unbounded `[Float]` `append(contentsOf:)` under a lock (see performance-plan.md §3 item 8).
///
/// The naive approach — one `[Float]` that grows for the whole recording, with `drain()`
/// removing a prefix — has two costs that get worse the longer a dictation runs:
///   1. `append(contentsOf:)` on an array without a reserved capacity re-copies the whole
///      backing store on every growth, ~doubling: a 10-minute hands-free note (~9.6M samples)
///      pays for that repeatedly.
///   2. `removeFirst(_:)` (what `drain()` used) is O(n) in the remaining count — it shifts
///      every remaining element down, so drains on a long recording cost more each time.
///
/// `AudioSampleBuffer` fixes both by storing samples as a deque of fixed-size chunks:
/// - Appending fills the current tail chunk and starts a new one when it's full — no
///   whole-buffer copy, ever.
/// - `drain()` hands back only the chunks produced since the last drain and clears them from
///   the deque in O(chunks drained), not O(remaining samples).
/// - `allSamples()` (for full-recording retention — saving the WAV, computing final metering)
///   flattens all chunks once, which is unavoidable but only happens once, at `stop()`.
///
/// Not thread-safe by itself — callers (see `AudioCapture`) hold their own lock around the
/// single producer (the tap callback) and single consumer (the main-actor drain/stop path),
/// matching the "single serial task" requirement for the streaming ASR consumer.
public struct AudioSampleBuffer: Sendable {
    /// Samples per chunk. 16,000 = 1 second at the app's working sample rate — big enough that
    /// chunk-management overhead is negligible relative to a tap callback's few hundred/thousand
    /// samples, small enough that a drain never has to flatten more than ~1 s of "current chunk"
    /// tail.
    public static let defaultChunkSize = 16_000

    private let chunkSize: Int
    /// Completed or in-progress chunks not yet handed out by `drain()`. The last chunk may be
    /// partially filled (its `count` can be less than `chunkSize`).
    private var pendingChunks: [[Float]] = []
    /// The chunk currently being appended to.
    private var current: [Float]
    /// Total samples ever appended (including ones already drained), for `totalCount`.
    private var appended = 0
    /// Total samples ever drained or retained, so `allSamples()` can reserve capacity exactly.
    private var retainedCount = 0
    /// All chunks ever produced, kept for `allSamples()` (full-recording retention for saving
    /// audio) even after `drain()` has handed their contents to a consumer. Cleared only by
    /// `reset()`.
    private var retainedChunks: [[Float]] = []
    /// Off for a note or meeting recording (notes audit B5): drained samples are not kept, so memory
    /// stays at what has not been drained yet (about 2 s), and `allSamples()` is only that tail.
    /// Dictation keeps the whole take for its WAV and metering.
    public let retainsFullRecording: Bool

    public init(chunkSize: Int = AudioSampleBuffer.defaultChunkSize, retainsFullRecording: Bool = true) {
        self.chunkSize = max(1, chunkSize)
        self.retainsFullRecording = retainsFullRecording
        self.current = []
        self.current.reserveCapacity(self.chunkSize)
    }

    /// Appends new samples, splitting across chunk boundaries as needed. O(samples.count),
    /// with no whole-buffer copy regardless of how much has been appended before.
    public mutating func append(contentsOf samples: some Collection<Float>) {
        guard !samples.isEmpty else { return }
        appended += samples.count
        var remaining = samples[samples.startIndex...]
        while !remaining.isEmpty {
            let space = chunkSize - current.count
            let take = min(space, remaining.count)
            current.append(contentsOf: remaining.prefix(take))
            remaining = remaining.dropFirst(take)
            if current.count == chunkSize {
                pendingChunks.append(current)
                if retainsFullRecording {
                    retainedChunks.append(current)
                    retainedCount += current.count
                }
                current = []
                current.reserveCapacity(chunkSize)
            }
        }
    }

    /// Returns and clears samples produced since the previous `drain()` (or since init), without
    /// touching full-recording retention. O(number of chunks drained), not O(total samples) —
    /// the cost that made the old `[Float]` + `removeFirst` approach slow on long recordings.
    ///
    /// The in-progress `current` chunk is included and flushed into `retainedChunks` so a drain
    /// mid-chunk doesn't lose those samples from `allSamples()`, then reset to empty — matching
    /// the old `drain()`'s "everything captured so far, then start fresh" contract.
    public mutating func drain() -> [Float] {
        var chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: true)
        if !current.isEmpty {
            chunks.append(current)
            if retainsFullRecording {
                retainedChunks.append(current)
                retainedCount += current.count
            }
            current = []
            current.reserveCapacity(chunkSize)
        }
        guard !chunks.isEmpty else { return [] }
        if chunks.count == 1 { return chunks[0] }
        var flat: [Float] = []
        flat.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks { flat.append(contentsOf: chunk) }
        return flat
    }

    /// All samples ever appended, in order, flattened once. Used for full-recording retention
    /// (saving the WAV at `stop()`), not on the hot per-callback path.
    /// Without full retention, the samples not drained yet.
    public func allSamples() -> [Float] {
        let kept = retainsFullRecording ? retainedChunks : pendingChunks
        var flat: [Float] = []
        flat.reserveCapacity(kept.reduce(0) { $0 + $1.count } + current.count)
        for chunk in kept { flat.append(contentsOf: chunk) }
        if !current.isEmpty { flat.append(contentsOf: current) }
        return flat
    }

    /// Samples held in memory right now.
    public var heldCount: Int {
        (retainsFullRecording ? retainedCount : pendingChunks.reduce(0) { $0 + $1.count }) + current.count
    }

    /// Total samples ever appended, including ones already drained — O(1).
    public var totalCount: Int { appended }

    /// True when nothing has been appended yet.
    public var isEmpty: Bool { appended == 0 }
}
