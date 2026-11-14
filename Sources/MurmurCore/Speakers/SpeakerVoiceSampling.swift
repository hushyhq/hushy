import Foundation

/// A stretch of a note's audio, in note-relative seconds.
public struct SpeechRange: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public var duration: Double { end - start }

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Picks which parts of a note's audio to learn one speaker's voice from: the speaker's own turns,
/// with anything another speaker said over them cut out, the ragged edges trimmed, the very short
/// turns dropped, and the longest remaining turns kept up to a cap. Pure, so it is tested without audio.
public enum SpeakerVoiceSampling {
    /// Less clean speech than this is not enough to describe a voice; the caller declines.
    public static let minimumTotalSeconds: Double = 10
    /// A turn shorter than this (after trimming) says too little about the voice to be worth an embedding.
    public static let minimumTurnSeconds: Double = 1.5
    /// One turn contributes at most this much, so a single long monologue does not set the voice.
    public static let maximumTurnSeconds: Double = 15
    /// Enough to describe a voice; more only costs time.
    public static let maximumTotalSeconds: Double = 45
    /// Word timings are a little loose; shave this off each end of a turn.
    public static let edgeMarginSeconds: Double = 0.15

    public enum Selection: Equatable, Sendable {
        /// Ranges to embed, in time order, and their total length.
        case ready(ranges: [SpeechRange], totalSeconds: Double)
        /// Not enough clean speech; `availableSeconds` is what there was.
        case tooLittle(availableSeconds: Double)
    }

    /// One line the UI shows when a speaker is declined for too little speech.
    public static let tooLittleMessage = "Not enough clear speech from this person in this note to learn their voice."

    public static func select(own: [SpeechRange], others: [SpeechRange]) -> Selection {
        let blockers = merged(others)
        let pieces = own.flatMap { cleanPieces(of: $0, avoiding: blockers) }
        let available = pieces.reduce(0) { $0 + $1.duration }
        guard available >= minimumTotalSeconds else { return .tooLittle(availableSeconds: available) }

        var chosen: [SpeechRange] = []
        var total = 0.0
        let longestFirst = pieces.sorted { $0.duration != $1.duration ? $0.duration > $1.duration : $0.start < $1.start }
        for piece in longestFirst where total + piece.duration <= maximumTotalSeconds + 1e-9 {
            chosen.append(piece)
            total += piece.duration
        }
        return .ready(ranges: chosen.sorted { $0.start < $1.start }, totalSeconds: total)
    }

    /// `range` minus the blocked stretches, each remaining piece trimmed, capped and kept only if long enough.
    private static func cleanPieces(of range: SpeechRange, avoiding blockers: [SpeechRange]) -> [SpeechRange] {
        var pieces: [SpeechRange] = []
        var cursor = range.start
        for blocker in blockers where blocker.end > cursor && blocker.start < range.end {
            if blocker.start > cursor { pieces.append(SpeechRange(start: cursor, end: blocker.start)) }
            cursor = max(cursor, blocker.end)
        }
        if cursor < range.end { pieces.append(SpeechRange(start: cursor, end: range.end)) }
        return pieces.compactMap { piece in
            let start = piece.start + edgeMarginSeconds
            let end = min(piece.end - edgeMarginSeconds, start + maximumTurnSeconds)
            let trimmed = SpeechRange(start: start, end: end)
            return trimmed.duration >= minimumTurnSeconds ? trimmed : nil
        }
    }

    private static func merged(_ ranges: [SpeechRange]) -> [SpeechRange] {
        var result: [SpeechRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.end > range.start {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = SpeechRange(start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }
}
