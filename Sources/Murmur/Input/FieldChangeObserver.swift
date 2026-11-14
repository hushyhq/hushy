import ApplicationServices
import Foundation
import os

/// Listens for one field's Accessibility "value changed" reports while its paste is watched for edits
/// (`EditWatcher.ChangeSubscriber`). It listens to the exact element Hushy pasted into and to nothing else: a report
/// is passed on only when it names that element, so text elsewhere in the app is never read because of it. It reads
/// nothing itself; the handler takes the bounded learning read (`LiveEditWatch.readOnChange`). Started after the
/// paste, stopped when the watch ends.
@MainActor
enum FieldChangeObserver {
    private static let log = Logger(subsystem: "app.hushy", category: "learning")

    /// What the observer's C callback reaches through its refcon. Unchecked: both fields are set once, and the
    /// callback runs only on the main run loop, where the handler is called.
    private final class Listener: @unchecked Sendable {
        let element: AXUIElement
        let onChange: @MainActor () -> Void
        init(element: AXUIElement, onChange: @escaping @MainActor () -> Void) {
            self.element = element
            self.onChange = onChange
        }
    }

    /// Starts listening to `element`; the returned closure stops it (once is enough; more calls do nothing). An app
    /// that does not let the element be observed gives a closure that does nothing, and the schedule's looks remain.
    static func subscribe(_ element: AXUIElement, onChange: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return {} }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return {} }
        let listener = Listener(element: element, onChange: onChange)
        let refcon = Unmanaged.passRetained(listener)
        let notification = kAXValueChangedNotification as CFString
        // Some apps report a field's changes only to an observer of the whole app; the callback still passes on
        // only the reports that name the watched element.
        let app = AXUIElementCreateApplication(pid)
        guard let observed = [element, app].first(where: {
            AXObserverAddNotification(observer, $0, notification, refcon.toOpaque()) == .success
        }) else {
            refcon.release()
            log.debug("change reports unavailable for this field")
            return {}
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        var isStopped = false
        return {
            guard !isStopped else { return }
            isStopped = true
            AXObserverRemoveNotification(observer, observed, notification)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            refcon.release()
        }
    }

    /// Runs on the main run loop (the source is added there). Passes on only a report about the watched element.
    private static let callback: AXObserverCallback = { _, element, _, refcon in
        guard let refcon else { return }
        let listener = Unmanaged<Listener>.fromOpaque(refcon).takeUnretainedValue()
        guard CFEqual(element, listener.element) else { return }
        MainActor.assumeIsolated { listener.onChange() }
    }
}
