import Foundation

/// The one on/off state for usage numbers, plus the **data epoch**, readable from any thread.
///
/// The settings object flips it in the same call that changes the setting, so there is no window
/// where the person has switched sharing off but recording or uploading still sees it on.
///
/// The epoch is a whole number that goes up every time the switch goes from on to off (and once at
/// launch when it starts off). Every file usage numbers keeps lives in a folder named for the epoch
/// it was written in (`MetricsDataStore`), and everything that holds data across an `await` carries
/// the epoch it started with and asks `allows(epoch:)` before it writes or sends. After an off, the
/// old epoch can never be current again, so nothing recorded before the off is reachable, whether
/// or not it has been deleted yet, across relaunches and crashes. Deleting old folders is only tidying.
///
/// The uploader also registers a handler that runs, synchronously, the moment the switch turns off
/// (to cancel a request that is already in flight).
public final class MetricsSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    private var currentEpoch: Int
    private var turnOffHandlers: [@Sendable () -> Void] = []

    public init(isOn: Bool = false, epoch: Int = 0) {
        on = isOn
        currentEpoch = epoch
    }

    public var isOn: Bool {
        get { lock.withLock { on } }
        set {
            let handlers: [@Sendable () -> Void] = lock.withLock {
                let turningOff = on && !newValue
                if turningOff { currentEpoch += 1 }
                on = newValue
                return turningOff ? turnOffHandlers : []
            }
            handlers.forEach { $0() }
        }
    }

    /// The data epoch: which folder is current.
    public var epoch: Int { lock.withLock { currentEpoch } }

    /// The one check, used before every write that outlives a call and before every send, and after
    /// every `await`: true only while the switch is on and `epoch` is still the current one.
    public func allows(epoch: Int) -> Bool { lock.withLock { on && currentEpoch == epoch } }

    /// Sets the epoch read back from storage at launch (the switch is still off).
    public func restoreEpoch(_ epoch: Int) {
        lock.withLock { currentEpoch = max(currentEpoch, min(max(epoch, 0), MetricsDataStore.maximumEpoch)) }
    }

    /// Starts a new epoch without a switch change (launch with the switch off: whatever an earlier
    /// run left behind becomes unreachable).
    public func advanceEpoch() { lock.withLock { currentEpoch += 1 } }

    /// Runs `handler` on the thread that turns the switch off, every time it goes from on to off.
    public func whenTurnedOff(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { turnOffHandlers.append(handler) }
    }
}
