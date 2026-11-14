import AppKit
import IOKit.ps
import MurmurCore
import Synchronization

/// Sends `ModelWarmthKeeper` the signals that usually come shortly before a dictation: the screen waking or
/// unlocking, the login session becoming active, the first keyboard or mouse input after idle, an app coming to
/// the front, and a slow tick while the person is using the Mac. The keeper decides what each one may do.
/// While the Mac is idle nothing here runs: the tick timer is stopped and an input event monitor waits instead.
@MainActor
final class PredictiveWarmer {
    private let keeper: ModelWarmthKeeper
    private let center: NotificationCenter
    private let distributed: DistributedNotificationCenter
    private let idleSeconds: () -> TimeInterval
    private let tickInterval: TimeInterval
    private let installInputMonitor: @MainActor (@escaping () -> Void) -> Any?
    private let removeInputMonitor: @MainActor (Any) -> Void
    private var tracker: ActivityTracker
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var inputMonitor: Any?
    /// The last signal handed to the keeper (tests).
    private(set) var lastSignal: WarmSignal?

    init(
        keeper: ModelWarmthKeeper,
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributed: DistributedNotificationCenter = .default(),
        tracker: ActivityTracker = ActivityTracker(),
        tickInterval: TimeInterval = 60,
        idleSeconds: @escaping () -> TimeInterval = PredictiveWarmer.systemIdleSeconds,
        installInputMonitor: @escaping @MainActor (@escaping () -> Void) -> Any? = PredictiveWarmer.installInputMonitor,
        removeInputMonitor: @escaping @MainActor (Any) -> Void = PredictiveWarmer.removeInputMonitor
    ) {
        self.keeper = keeper
        self.center = center
        self.distributed = distributed
        self.tracker = tracker
        self.tickInterval = tickInterval
        self.idleSeconds = idleSeconds
        self.installInputMonitor = installInputMonitor
        self.removeInputMonitor = removeInputMonitor
    }

    func start() {
        let workspace: [(Notification.Name, WarmSignal)] = [
            (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.screensDidWakeNotification, .wake),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
            (NSWorkspace.didActivateApplicationNotification, .appActivated),
        ]
        for (name, signal) in workspace { observe(center, name, signal) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlock)
        startTicking()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
        if let inputMonitor { removeInputMonitor(inputMonitor) }
        inputMonitor = nil
    }

    /// One timer reading (the timer calls this; tests call it directly).
    func tick(now: Date = Date()) {
        switch tracker.tick(idleSeconds: idleSeconds(), now: now) {
        case .activeTick: send(.activeTick)
        case .wentIdle: waitForInput()
        case .back, nil: break
        }
    }

    /// The first input after idle (the event monitor calls this; tests call it directly).
    func inputArrived(now: Date = Date()) {
        guard case .back = tracker.input(now: now) else { return }
        if let inputMonitor { removeInputMonitor(inputMonitor) }
        inputMonitor = nil
        send(.backFromIdle)
        startTicking()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ signal: WarmSignal) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(signal) }
        }
        observers.append((center, observer))
    }

    private func send(_ signal: WarmSignal) {
        lastSignal = signal
        let keeper = keeper
        Task.detached(priority: .utility) { await keeper.handle(signal) }
    }

    private func startTicking() {
        timer?.invalidate()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = tickInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func waitForInput() {
        timer?.invalidate()
        timer = nil
        inputMonitor = installInputMonitor { [weak self] in
            MainActor.assumeIsolated { self?.inputArrived() }
        }
    }

    // MARK: System readings

    /// Seconds since the last keyboard, mouse or trackpad input in this login session.
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Global and local monitors for the first input after idle. Mouse events need no permission; key events
    /// arrive only with Accessibility, which Hushy has for pasting.
    static func installInputMonitor(_ handler: @escaping () -> Void) -> Any? {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown, .flagsChanged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in handler() }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in handler(); return event }
        return [global, local].compactMap { $0 }
    }

    static func removeInputMonitor(_ monitor: Any) {
        for item in monitor as? [Any] ?? [] { NSEvent.removeMonitor(item) }
    }
}

/// `WarmConditions` from the system: power source, Low Power Mode, thermal state, the last memory-pressure
/// event (fed by the app's `MemoryPressureMonitor`) and the load average.
final class SystemWarmConditions: Sendable {
    private let pressure = Mutex(MemoryPressureLevel.normal)

    func memoryPressure(_ level: MemoryPressureLevel) {
        pressure.withLock { $0 = level }
    }

    func read() -> WarmConditions {
        let info = ProcessInfo.processInfo
        return WarmConditions(
            onBattery: Self.onBattery(), lowPowerMode: info.isLowPowerModeEnabled, thermal: info.thermalState,
            memoryPressure: pressure.withLock { $0 }, busyCPU: Self.busyCPU(cores: info.activeProcessorCount))
    }

    static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    /// The 1-minute load average is at least 3/4 of the active cores.
    static func busyCPU(cores: Int) -> Bool {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return false }
        return loads[0] >= Double(cores) * 0.75
    }
}
