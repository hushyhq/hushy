import AppKit
import ApplicationServices
import MurmurCore

/// Limits on the accessibility reads Hushy makes for itself between key release and ⌘V: the look
/// for a late field and the read of the field before the paste. Another app answers these on its
/// own main thread, so each read has a short timeout, and no read starts once the budget for the
/// whole run is spent. The worst case is therefore the budget plus one last read. A read that
/// fails, times out or is not started counts as "could not tell", and the paste goes on as it
/// would have without it. (The delivery guard's own reads, `TargetGuard`, are not bounded here: a
/// guard read that times out reads as "focus moved", so a short timeout there would turn a slow
/// app into "not pasted".)
enum AXBounds {
    /// The longest one bounded read may take, in seconds.
    static let readTimeout: Float = 0.1
    /// After this long, no further bounded read of the run starts.
    static let budget: Duration = .milliseconds(150)

    /// Runs reads of `element` under `readTimeout`, then puts the element back on the default.
    /// The timeout belongs to this one element reference, not to equal ones or to the process
    /// (`AXUIElementSetMessagingTimeout`); it is reset all the same, since the reference may be kept.
    @MainActor
    static func bounded<T>(_ element: AXUIElement, _ reads: () -> T) -> T {
        AXUIElementSetMessagingTimeout(element, readTimeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        return reads()
    }
}

/// The time left for one run of bounded reads (`AXBounds.budget`). Asked before every read.
struct AXReadBudget {
    private let deadline = ContinuousClock.now + AXBounds.budget
    var isSpent: Bool { ContinuousClock.now >= deadline }
}

/// Whether the system-wide focus query is still worth asking for one dictation's target. The
/// delivery guard asks it on every check of a target that was found that way; once it has timed
/// out it is not asked again, so it can cost one timeout per dictation, not one per check.
@MainActor
final class SystemQueryGate {
    private(set) var hasTimedOut = false
    func record(_ outcome: PasteDiagnosis.SystemQuery) {
        if outcome == .error(AXError.cannotComplete.rawValue) { hasTimedOut = true }
    }
}

/// Live focus over the Accessibility API, for `TargetGuard`. Reads only.
@MainActor
struct AXFocusReader: FocusReading {
    /// Ask the system-wide focused element when the app's own query gives nothing. Set at
    /// key-down and when looking for a late field; afterwards only for a target that was found
    /// that way, so every later check resolves focus as key-down did and no other target pays for it.
    var asksSystem = false
    /// Set for Hushy's own looks before ⌘V: each read of the app's focus or window is then bounded
    /// (`AXBounds.readTimeout`) and is not started once the budget is spent. Nil for the delivery
    /// guard, whose reads stay on the system default.
    var budget: AXReadBudget?
    /// Shared by every check of one target (`SystemQueryGate`).
    var systemGate: SystemQueryGate?

    /// One look at which element has focus, and how each query went.
    struct FocusQuery {
        let element: AXUIElement?
        let source: PasteDiagnosis.Query
        let appError: AXError
        let system: PasteDiagnosis.SystemQuery
    }

    func frontmostApp() -> (processID: Int32, bundleID: String?)? {
        NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) }
    }

    func isRunning(processID: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processID) else { return false }
        return !app.isTerminated
    }

    func focusedField(processID: Int32) -> AXUIElement? {
        focusQuery(processID: processID).element
    }

    /// The app's own focused element; failing that, and only when `asksSystem`, the system-wide
    /// one, used only if it belongs to the same process.
    func focusQuery(processID: Int32) -> FocusQuery {
        guard budget?.isSpent != true else {
            return FocusQuery(element: nil, source: .none, appError: .cannotComplete, system: .skipped)
        }
        var value: CFTypeRef?
        let appError = withApplication(processID) {
            AXUIElementCopyAttributeValue($0, kAXFocusedUIElementAttribute as CFString, &value)
        }
        if appError == .success, let element = Self.element(value) {
            return FocusQuery(element: element, source: .app, appError: .success, system: .skipped)
        }
        guard asksSystem, budget?.isSpent != true, systemGate?.hasTimedOut != true else {
            return FocusQuery(element: nil, source: .none, appError: appError, system: .skipped)
        }
        let system = Self.systemFocused(processID: processID)
        systemGate?.record(system.outcome)
        return FocusQuery(element: system.element, source: system.element == nil ? .none : .system,
                          appError: appError, system: system.outcome)
    }

    func focusedWindow(processID: Int32) -> AXUIElement? {
        guard budget?.isSpent != true else { return nil }
        var value: CFTypeRef?
        let read = withApplication(processID) {
            AXUIElementCopyAttributeValue($0, kAXFocusedWindowAttribute as CFString, &value)
        }
        return read == .success ? Self.element(value) : nil
    }

    /// Only a successful read of an empty window list is proof that the app has no window.
    /// An unsupported/timed-out AXWindows read says nothing about where paste may land.
    func positivelyHasNoWindows(processID: Int32) -> Bool {
        guard budget?.isSpent != true else { return false }
        var value: CFTypeRef?
        let read = withApplication(processID) {
            AXUIElementCopyAttributeValue($0, kAXWindowsAttribute as CFString, &value)
        }
        return read == .success && (value as? [Any])?.isEmpty == true
    }

    func isAlive(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        let read = { AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) }
        return (budget == nil ? read() : AXBounds.bounded(element, read)) != .invalidUIElement
    }

    /// The same role/subrole rule context reading and edit capture use (they fail closed on
    /// `.unknown`; `TargetGuard` decides per path).
    /// With a budget the two reads are bounded and not started once it is spent; a spent budget answers
    /// `.unknown`, which the guard treats as "might be a password field".
    func security(_ element: AXUIElement) -> FieldSecurity {
        guard let budget else { return ContextReader.security(of: element) }
        return AXBounds.bounded(element) { ContextReader.securityRead(of: element, isSpent: { budget.isSpent }).security }
    }

    func isSame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    /// The element's parent, read within `AXBounds.readTimeout`. Nil when it has none or the read failed.
    static func boundedParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let read = AXBounds.bounded(element) {
            AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        }
        return read == .success ? Self.element(value) : nil
    }

    /// One read of the app's own element: bounded when this reader has a budget. A fresh
    /// reference is made for each read and dropped after it.
    private func withApplication(_ processID: Int32, _ read: (AXUIElement) -> AXError) -> AXError {
        let app = AXUIElementCreateApplication(processID)
        return budget == nil ? read(app) : AXBounds.bounded(app) { read(app) }
    }

    /// The system-wide element's timeout is the whole process's, so it is set for this one read
    /// and put back to the default straight after.
    private static func systemFocused(processID: Int32) -> (element: AXUIElement?, outcome: PasteDiagnosis.SystemQuery) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, AXBounds.readTimeout)
        defer { AXUIElementSetMessagingTimeout(system, 0) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let element = Self.element(value) else {
            return (nil, .error((error == .success ? AXError.failure : error).rawValue))
        }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == processID else { return (nil, .otherProcess) }
        return (element, .ok)
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
