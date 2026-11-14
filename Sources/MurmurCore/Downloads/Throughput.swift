import Foundation

/// Passive throughput: bytes per second measured from the download's own byte count, never
/// from a separate speed test (which would spend the user's bandwidth to learn nothing the
/// download itself doesn't already say).
///
/// An exponentially weighted moving average with a *time* constant rather than a per-sample
/// weight, so irregular sampling (a stalled connection that delivers nothing for 5 s, then a
/// burst) weighs each interval by how long it lasted. The caller samples on a steady tick
/// (`DownloadCoordinator` does once a second) with the latest cumulative byte count, so a
/// stall shows up as zero-byte intervals that pull the rate down instead of freezing the ETA.
/// Value type: every observation returns a new meter.
public struct ThroughputMeter: Equatable, Sendable {
    /// Seconds for an old interval's weight to fall to 1/e. ~8 s: steady enough that one slow
    /// second doesn't swing the ETA, quick enough to follow a real change of network.
    public let timeConstant: TimeInterval
    /// Observed time before the rate is reported (the first second of a TCP connection is
    /// slow-start, not the connection's speed).
    public let warmUp: TimeInterval
    /// Intervals shorter than this are merged into the next one (bursty callbacks).
    public let minimumInterval: TimeInterval

    public private(set) var smoothedBytesPerSecond: Double?
    public private(set) var observedSeconds: TimeInterval = 0
    private var lastBytes: Int64?
    private var lastTime: Date?

    public init(timeConstant: TimeInterval = 8, warmUp: TimeInterval = 2, minimumInterval: TimeInterval = 0.25) {
        self.timeConstant = timeConstant
        self.warmUp = warmUp
        self.minimumInterval = minimumInterval
    }

    /// The measured rate once `warmUp` seconds have been observed; nil before.
    public var bytesPerSecond: Double? {
        guard observedSeconds >= warmUp else { return nil }
        return smoothedBytesPerSecond
    }

    /// Records the cumulative byte count at `time`. A count that goes *down* (a file restarted
    /// from zero because the server ignored the resume range) re-anchors without producing a
    /// negative rate.
    public func observing(totalBytes: Int64, at time: Date) -> ThroughputMeter {
        var next = self
        guard let lastBytes, let lastTime else {
            next.lastBytes = totalBytes
            next.lastTime = time
            return next
        }
        let interval = time.timeIntervalSince(lastTime)
        if totalBytes < lastBytes {
            next.lastBytes = totalBytes
            next.lastTime = time
            return next
        }
        guard interval >= minimumInterval else { return self }
        let instantaneous = Double(totalBytes - lastBytes) / interval
        let weight = 1 - exp(-interval / timeConstant)
        if let previous = smoothedBytesPerSecond {
            next.smoothedBytesPerSecond = previous + weight * (instantaneous - previous)
        } else {
            next.smoothedBytesPerSecond = instantaneous
        }
        next.observedSeconds += interval
        next.lastBytes = totalBytes
        next.lastTime = time
        return next
    }

    /// Seconds to move `remainingBytes` at the measured rate; nil before warm-up. Capped at a
    /// day so a near-zero rate reads as "a long time", not infinity.
    public func secondsRemaining(forBytes remainingBytes: Int64) -> TimeInterval? {
        guard let rate = bytesPerSecond else { return nil }
        guard remainingBytes > 0 else { return 0 }
        guard rate > 1 else { return Self.maximumSeconds }
        return min(Double(remainingBytes) / rate, Self.maximumSeconds)
    }

    public static let maximumSeconds: TimeInterval = 24 * 3600
}

/// Turns a jittery raw ETA into one a person can read without it jumping: between samples the
/// shown value counts down in real time; each new raw estimate pulls it only part of the way.
/// Good news (a shorter estimate) is taken faster than bad news, so a brief dip never makes
/// the number leap up, and a real slowdown still shows within seconds.
public struct ETASmoother: Equatable, Sendable {
    /// Share of the gap to the raw estimate closed per second when the raw is *longer*.
    public let riseRate: Double
    /// Share closed per second when the raw is *shorter*.
    public let fallRate: Double

    public private(set) var seconds: TimeInterval?
    private var lastTime: Date?

    public init(riseRate: Double = 0.2, fallRate: Double = 0.5) {
        self.riseRate = riseRate
        self.fallRate = fallRate
    }

    public func observing(rawSeconds: TimeInterval?, at time: Date) -> ETASmoother {
        var next = self
        guard let raw = rawSeconds else {
            // No rate yet (warm-up): keep counting down whatever we already showed.
            if let shown = seconds, let lastTime {
                next.seconds = max(0, shown - max(0, time.timeIntervalSince(lastTime)))
                next.lastTime = time
            }
            return next
        }
        guard let shown = seconds, let lastTime else {
            next.seconds = max(0, raw)
            next.lastTime = time
            return next
        }
        let elapsed = max(0, time.timeIntervalSince(lastTime))
        let predicted = max(0, shown - elapsed)
        let gap = raw - predicted
        let perSecond = gap > 0 ? riseRate : fallRate
        // Per-second rate compounded over the elapsed interval, so tick spacing doesn't matter.
        let share = 1 - pow(1 - perSecond, max(elapsed, 0.001))
        next.seconds = max(0, predicted + gap * share)
        next.lastTime = time
        return next
    }
}

/// A coarse bucket of the measured throughput, for the local funnel and the pacing
/// narrative. Named by what they mean for the ~632 MB speech model.
public enum SpeedBucket: String, Codable, CaseIterable, Sendable {
    /// ≥ 10 MB/s (≈ 80 Mbit/s): the model lands in about a minute.
    case fast
    /// ≥ 2.5 MB/s (≈ 20 Mbit/s): a few minutes.
    case moderate
    /// ≥ 0.5 MB/s (≈ 4 Mbit/s): a quarter of an hour or so.
    case slow
    /// Below that: a long wait.
    case verySlow
    /// No usable network when measured.
    case offline

    public static func from(bytesPerSecond: Double) -> SpeedBucket {
        switch bytesPerSecond {
        case 10_000_000...: .fast
        case 2_500_000...: .moderate
        case 500_000...: .slow
        default: .verySlow
        }
    }
}
