import Foundation

/// Whether the person is at the Mac, from the seconds since their last keyboard or mouse input
/// (`CGEventSource`), read on a slow timer while they are active. When they go idle the app stops the timer and
/// waits for the next input event instead, so an idle Mac is never woken by Hushy.
public struct ActivityTracker: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Input within the last `activeWindow`: a chance to keep the model's pages marked used.
        case activeTick
        /// No input for `idleThreshold`: stop the timer and watch for input.
        case wentIdle
        /// The first input after idle; `idleSeconds` is how long the Mac sat without input.
        case back(idleSeconds: TimeInterval)
    }

    public var idleThreshold: TimeInterval
    public var activeWindow: TimeInterval
    public private(set) var isIdle = false
    private var idleSince: Date?

    public init(idleThreshold: TimeInterval = 180, activeWindow: TimeInterval = 60) {
        self.idleThreshold = idleThreshold
        self.activeWindow = activeWindow
    }

    /// A timer reading while active.
    public mutating func tick(idleSeconds: TimeInterval, now: Date) -> Event? {
        guard !isIdle else { return nil }
        if idleSeconds >= idleThreshold {
            isIdle = true
            idleSince = now.addingTimeInterval(-idleSeconds)
            return .wentIdle
        }
        return idleSeconds < activeWindow ? .activeTick : nil
    }

    /// An input event while idle (the app's event monitor). Ignored while active.
    public mutating func input(now: Date) -> Event? {
        guard isIdle else { return nil }
        isIdle = false
        let seconds = idleSince.map { max(0, now.timeIntervalSince($0)) } ?? idleThreshold
        idleSince = nil
        return .back(idleSeconds: seconds)
    }
}
