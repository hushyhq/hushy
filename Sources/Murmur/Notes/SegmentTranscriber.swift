import Foundation
import MurmurCore
import os

/// Recognises one sealed journal segment and records the result in one transaction (`Store.insertSegmentTurn`),
/// for the recorder while it records and for the finalize runner afterwards. Silence is a gap, never a failure
/// (notes audit B1); a recognition that throws counts an attempt, and at the third the segment is a failed gap
/// while the note goes on.
struct SegmentTranscriber: Sendable {
    let pipeline: DictationPipeline
    let store: Store
    let vocabulary: VocabularyContext
    let clean: @Sendable (String) -> String

    enum Outcome: Sendable, Equatable {
        case turn(NoteTurn.Stream, text: String)
        case silence
        case noWords
        case failed
        /// Another run already recorded this segment, or the note is gone.
        case skipped
    }

    private static let log = Logger(subsystem: "app.hushy", category: "notes")

    func transcribe(_ segment: CaptureSegment, samples: [Float]) async -> Outcome {
        guard let id = segment.id else { return .skipped }
        do {
            guard SpeechGate.evaluate(samples).hasSpeech else {
                return try store.markSegmentTranscribed(id: id, gapReason: .silence) ? .silence : .skipped
            }
            let result = try await pipeline.transcribeRawWithTimings(samples, vocabulary: vocabulary)
            let text = clean(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return try store.markSegmentTranscribed(id: id, gapReason: nil) ? .noWords : .skipped
            }
            let words = Self.words(result.timings, text: result.text, segment: segment)
            let stream = NoteTurn.Stream(rawValue: segment.stream.rawValue) ?? .unknown
            return try store.insertSegmentTurn(segmentId: id, text: text, words: words) ? .turn(stream, text: text) : .skipped
        } catch {
            Self.log.error("segment \(segment.seq) \(segment.stream.rawValue, privacy: .public) failed: \(error.localizedDescription)")
            let state = try? store.recordSegmentFailure(id: id, errorCode: "asr", maxAttempts: FinalizePlan.maxSegmentAttempts)
            return state == .failed ? .failed : .skipped
        }
    }

    /// The segment's words on the note clock. Without word times (a vocabulary rewrite drops them, notes audit B11)
    /// the raw words are spread evenly over the segment, so the assembled transcript never loses them.
    static func words(_ timings: [MurmurCore.WordTiming]?, text: String, segment: CaptureSegment) -> [NoteTurn.Word] {
        if let timings, !timings.isEmpty {
            return timings.map { NoteTurn.Word(w: $0.word, start: $0.start + segment.t0, end: $0.end + segment.t0, conf: 1) }
        }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let step = max(segment.duration, 0.1) / Double(tokens.count)
        return tokens.enumerated().map { index, word in
            let start = segment.t0 + Double(index) * step
            return NoteTurn.Word(w: word, start: start, end: start + step * 0.9, conf: 0, flags: NoteTurn.Word.boosted)
        }
    }
}
