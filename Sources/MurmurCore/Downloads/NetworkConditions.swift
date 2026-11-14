import Foundation

/// What macOS says about the current network path (`NWPath`): reachable at all, "expensive"
/// (cellular or a personal hotspot) and "constrained" (Low Data Mode). A plain value so the
/// download policy is testable without a real network.
public struct NetworkConditions: Equatable, Sendable {
    public let isReachable: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool

    public init(isReachable: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isReachable = isReachable
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public static let unmetered = NetworkConditions(isReachable: true)
    public static let offline = NetworkConditions(isReachable: false)

    /// Metered in the sense the user cares about: every megabyte may cost money or data cap.
    public var isMetered: Bool { isExpensive || isConstrained }
}

/// Whether a download may run on the current network. Big downloads never start (or keep
/// going) on a metered path without the user's OK; small ones do, since asking about 2 MB is
/// noise.
public enum DownloadGate {
    /// Downloads with less than this left don't need permission on a metered network.
    public static let askAboveBytes: Int64 = 25_000_000

    public enum Decision: Equatable, Sendable {
        case proceed
        /// No network: wait for the path to come back, then resume.
        case waitForNetwork
        /// Metered network and a big download: stop (keeping partial bytes) and ask.
        case askFirst
    }

    /// - Parameter approvedOnMetered: the user said "download anyway" this session.
    public static func decide(
        conditions: NetworkConditions, remainingBytes: Int64, approvedOnMetered: Bool
    ) -> Decision {
        guard conditions.isReachable else { return .waitForNetwork }
        guard conditions.isMetered, !approvedOnMetered, remainingBytes > askAboveBytes else { return .proceed }
        return .askFirst
    }
}

/// Exponential backoff for retrying a failed download: 2 s, 4 s, 8 s … capped, with optional
/// jitter so many Macs coming back online at once don't retry in lockstep. Pure; the jitter
/// source is injected so tests are deterministic.
public struct RetryBackoff: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let multiplier: Double
    public let maximumDelay: TimeInterval
    public let maximumAttempts: Int
    /// 0…1 share of the delay that is randomised (0 = none).
    public let jitter: Double

    public init(
        initialDelay: TimeInterval = 2, multiplier: Double = 2, maximumDelay: TimeInterval = 120,
        maximumAttempts: Int = 6, jitter: Double = 0.2
    ) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
        self.jitter = jitter
    }

    /// Delay before retry number `attempt` (1-based: the delay after the first failure), or nil
    /// once `maximumAttempts` retries are used up. `random` returns 0…1.
    public func delay(beforeRetry attempt: Int, random: () -> Double = { Double.random(in: 0...1) }) -> TimeInterval? {
        guard attempt >= 1, attempt <= maximumAttempts else { return nil }
        let base = min(initialDelay * pow(multiplier, Double(attempt - 1)), maximumDelay)
        let spread = base * jitter
        return max(0, base - spread + 2 * spread * min(max(random(), 0), 1))
    }
}
