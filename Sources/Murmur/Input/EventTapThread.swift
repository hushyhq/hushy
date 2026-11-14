import CoreFoundation
import Foundation

/// A thread with its own run loop, for the event tap. Every key and click on the Mac waits on the
/// tap's callback, so it must never wait on the main thread, which a dictation start or a busy view
/// can hold for hundreds of milliseconds (audit 2026-11-07, B2).
final class EventTapThread: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var thread: Thread?
    private var loop: CFRunLoop?

    /// Starts the thread and returns once its run loop is running.
    func start() {
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "app.hushy.event-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        lock.unlock()
        thread.start()
        ready.wait()
    }

    private func run() {
        let loop = CFRunLoopGetCurrent()
        // A run loop with nothing in it returns at once; this timer keeps it alive until `stop`.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .commonModes)
        lock.lock()
        self.loop = loop
        lock.unlock()
        ready.signal()
        CFRunLoopRun()
        CFRunLoopTimerInvalidate(keepAlive)
    }

    func add(_ source: CFRunLoopSource) {
        guard let loop = currentLoop() else { return }
        CFRunLoopAddSource(loop, source, .commonModes)
        CFRunLoopWakeUp(loop)
    }

    func remove(_ source: CFRunLoopSource) {
        guard let loop = currentLoop() else { return }
        CFRunLoopRemoveSource(loop, source, .commonModes)
    }

    /// Runs `block` on the tap thread, as the tap's own callback would run there.
    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let loop = currentLoop() else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    func stop() {
        lock.lock()
        let loop = self.loop
        self.loop = nil
        thread = nil
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }

    private func currentLoop() -> CFRunLoop? {
        lock.lock()
        defer { lock.unlock() }
        return loop
    }
}
