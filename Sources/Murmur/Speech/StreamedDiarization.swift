import CryptoKit
import FluidAudio
import Foundation
import MurmurCore

/// A streaming diarizer: audio in, per-frame speaker probabilities out, its speaker state kept between calls.
protocol StreamingDiarizerSession: AnyObject {
    /// Feeds samples (16 kHz mono) and returns the frames they completed: `speakers` probabilities per frame.
    func feed(_ samples: [Float]) throws -> (probabilities: [Float], frames: Int)
    /// Pads and runs the tail.
    func finish() throws -> (probabilities: [Float], frames: Int)
}

/// Diarizes one side window by window (`CaptureSegmentAudio.windows`) instead of one pass over the whole side:
/// the whole side is never in memory (an hour is 230 MB of samples and 184 MB of mel features in one pass), and
/// before every window it calls `yield`, which waits while a dictation is in progress. The session keeps its
/// speaker state across the wait, so a pause loses or repeats nothing: every sample is fed once, in order.
enum StreamedDiarization {
    struct Result: Equatable {
        var probabilities: [Float] = []
        var frames = 0
        var samples = 0
        var windows = 0
    }

    static func run(
        _ windows: AsyncThrowingStream<[Float], any Error>, session: some StreamingDiarizerSession,
        yield: @Sendable () async -> Void, isolation: isolated (any Actor)? = #isolation
    ) async throws -> Result {
        var result = Result()
        for try await window in windows {
            await yield()
            try Task.checkCancellation()
            let out = try session.feed(window)
            result.probabilities += out.probabilities
            result.frames += out.frames
            result.samples += window.count
            result.windows += 1
        }
        let tail = try session.finish()
        result.probabilities += tail.probabilities
        result.frames += tail.frames
        return result
    }
}

/// FluidAudio's Nemotron 3 through its streaming entry points, which are frame-exact with `processComplete`.
final class NemotronStreamingSession: StreamingDiarizerSession {
    private let diarizer: Nemotron3Diarizer

    init(diarizer: Nemotron3Diarizer) {
        self.diarizer = diarizer
        diarizer.reset()
    }

    func feed(_ samples: [Float]) throws -> (probabilities: [Float], frames: Int) {
        diarizer.appendAudio(samples)
        return Self.flatten(try diarizer.processBufferedAudio())
    }

    func finish() throws -> (probabilities: [Float], frames: Int) {
        Self.flatten(try diarizer.finishStream())
    }

    private static func flatten(_ results: [Nemotron3ChunkResult]) -> (probabilities: [Float], frames: Int) {
        (results.flatMap(\.probabilities), results.reduce(0) { $0 + $1.frameCount })
    }
}

/// One side of a note's audio, as the assembler reads it: window by window for diarization, a short range for voice
/// matching, the whole side only for the legacy diarizer (a fallback that needs it in one piece).
struct SideAudio: Sendable {
    let hasAudio: @Sendable (CaptureStream) -> Bool
    let windows: @Sendable (CaptureStream) -> AsyncThrowingStream<[Float], any Error>
    let range: @Sendable (CaptureStream, _ from: Double, _ to: Double) throws -> [Float]
    let whole: @Sendable (CaptureStream) throws -> [Float]

    /// A note's capture journal.
    static func journal(
        _ journal: CaptureJournal, folder: URL?, key: SymmetricKey?, readLegacy: @escaping CaptureJournalAdopter.LegacyReader
    ) -> SideAudio {
        guard let folder else { return .silent }
        return SideAudio(
            hasAudio: { journal.sealedSeconds($0) > 0 },
            windows: { CaptureSegmentAudio.windows(journal, stream: $0, folder: folder, key: key, readLegacy: readLegacy) },
            range: { try CaptureSegmentAudio.range(journal, stream: $0, from: $1, to: $2, folder: folder, key: key, readLegacy: readLegacy) },
            whole: { try CaptureSegmentAudio.timeline(journal, stream: $0, folder: folder, key: key, readLegacy: readLegacy) })
    }

    static let silent = SideAudio(
        hasAudio: { _ in false }, windows: { _ in AsyncThrowingStream { $0.finish() } }, range: { _, _, _ in [] }, whole: { _ in [] })

    /// The same samples for every side (tests).
    static func constant(_ samples: [Float], window: Int = 160_000) -> SideAudio {
        SideAudio(
            hasAudio: { _ in !samples.isEmpty },
            windows: { _ in
                AsyncThrowingStream { continuation in
                    var offset = 0
                    while offset < samples.count {
                        continuation.yield(Array(samples[offset..<min(samples.count, offset + window)]))
                        offset += window
                    }
                    continuation.finish()
                }
            },
            range: { _, from, to in
                let rate = SpeakerDiarizerConstants.sampleRate
                let lo = max(0, Int(from * rate)), hi = min(samples.count, Int(to * rate))
                return lo < hi ? Array(samples[lo..<hi]) : []
            },
            whole: { _ in samples })
    }
}
