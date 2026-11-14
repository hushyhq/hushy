import Foundation

/// The standing speed figure for the on-device model: how many tokens it has emitted a fixed time
/// after the call starts (`windowMilliseconds`). Counts tokens that end up in the answer, so the
/// end-of-sequence token is not one.
/// A token counts once it is available: a speculative pass is timestamped when the pass ends, so
/// the tokens of a pass that crosses the window count as after it.
public enum EarlyTokens {
    /// How long after the call starts the count is taken.
    public static let windowMilliseconds: Double = 250

    /// The early count as a rate, in tokens a second from the call's start. It is taken over the window, or
    /// over the whole call when the answer finished inside the window, so a short answer does not read as a slow one.
    public static func perSecond(
        tokens: Int, totalMilliseconds: Double, windowMilliseconds: Double = EarlyTokens.windowMilliseconds
    ) -> Double {
        let span = min(windowMilliseconds, totalMilliseconds)
        guard span > 0 else { return 0 }
        return Double(tokens) * 1_000 / span
    }

    /// Tokens emitted together at one moment: one forward pass can emit several (speculation
    /// accepts a draft; the grammar adds forced tokens after a sampled one).
    struct Emission: Equatable, Sendable {
        /// Milliseconds from the call's start to this emission.
        var offsetMilliseconds: Double
        /// Tokens the model chose.
        var sampled: Int
        /// Tokens the grammar forced.
        var forced: Int
    }

    struct Count: Equatable, Sendable {
        /// Sampled and forced tokens together.
        var total = 0
        /// Sampled tokens alone.
        var sampled = 0
    }

    /// The tokens emitted at or before `windowMilliseconds` (a token exactly at the limit counts).
    static func count(_ emissions: [Emission], windowMilliseconds: Double = EarlyTokens.windowMilliseconds) -> Count {
        var count = Count()
        for emission in emissions where emission.offsetMilliseconds <= windowMilliseconds {
            count.sampled += emission.sampled
            count.total += emission.sampled + emission.forced
        }
        return count
    }
}

/// Collects emission times for one call. It reads the clock only until the first emission past the
/// window, then stops, so decoding pays nothing after the window closes.
struct EarlyTokenRecorder {
    private let start: ContinuousClock.Instant
    private let windowMilliseconds: Double
    private var emissions: [EarlyTokens.Emission] = []
    private var isClosed = false

    init(start: ContinuousClock.Instant, windowMilliseconds: Double = EarlyTokens.windowMilliseconds) {
        self.start = start
        self.windowMilliseconds = windowMilliseconds
    }

    mutating func record(sampled: Int, forced: Int) {
        guard !isClosed else { return }
        let offset = MLXEngine.milliseconds(from: start, to: .now)
        guard offset <= windowMilliseconds else {
            isClosed = true
            return
        }
        emissions.append(.init(offsetMilliseconds: offset, sampled: sampled, forced: forced))
    }

    var count: EarlyTokens.Count { EarlyTokens.count(emissions, windowMilliseconds: windowMilliseconds) }
}
