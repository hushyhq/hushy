import Foundation

/// How the focus the user had at key-down differs from the focus right before a paste.
/// Recorded in the dictation log line as `reason=target-changed:<rawValue>`.
public enum TargetChange: String, Sendable, Equatable, CaseIterable {
    /// Another app is frontmost (or nothing is).
    case app
    /// Same app, another window. Only used when the app exposed no focused field at key-down
    /// (Electron before its AX tree settles, some terminals), so the window is the best identity.
    case window
    /// Same app, another field or no field (the user clicked a different text box, a sidebar…).
    case field
    /// The original field, its window or its app no longer exists (sheet closed, app quit).
    case fieldClosed = "field-closed"
}

/// The result of re-checking the key-down target right before dispatch.
public enum TargetVerdict: Sendable, Equatable {
    /// Same app, same field (or, for apps without field identity, same app and window).
    case unchanged
    /// The target moved; never paste blindly (see `TargetedDelivery`).
    case changed(TargetChange)
    /// A password field has focus now. Never paste and never stage text on the clipboard for it.
    /// `change` is nil when the bound field itself reads as secure.
    case secureField(change: TargetChange?)
}

/// Whether a field is a password field, as far as the platform can tell.
public enum FieldSecurity: Sendable, Equatable {
    case secure
    case notSecure
    /// The role/subrole couldn't be read (timeout, odd AX bridge). Fail-closed callers treat
    /// this as secure.
    case unknown
}

/// Platform seam for reading live focus. The app implements it over the Accessibility API with
/// `AXUIElement` as `Element`; tests use plain values. Every call is a cheap read — no side
/// effects — so `TargetGuard` can re-run it before the clipboard write, before ⌘V and before
/// Return.
@MainActor
public protocol FocusReading {
    associatedtype Element
    /// The frontmost app's process and bundle ID, or nil when nothing is frontmost.
    func frontmostApp() -> (processID: Int32, bundleID: String?)?
    func isRunning(processID: Int32) -> Bool
    func focusedField(processID: Int32) -> Element?
    func focusedWindow(processID: Int32) -> Element?
    /// False only when the element is known to be destroyed (AX: invalid element).
    func isAlive(_ element: Element) -> Bool
    func security(_ element: Element) -> FieldSecurity
    func isSame(_ lhs: Element, _ rhs: Element) -> Bool
}

/// The target captured once at key-down. Immutable for the session.
public struct BoundFocus<Element> {
    public let processID: Int32?
    public let bundleID: String?
    /// The focused field at key-down, or nil when the app exposed none.
    public let field: Element?
    /// The focused window at key-down; used only as the fallback identity when `field` is nil.
    public let window: Element?
    /// `field` positively read as a password field at key-down. Read once there rather than on
    /// every re-check, so the common "same field" check costs one AX call on the release path.
    public let fieldIsSecure: Bool

    public init(processID: Int32?, bundleID: String?, field: Element?, window: Element?, fieldIsSecure: Bool = false) {
        self.processID = processID
        self.bundleID = bundleID
        self.field = field
        self.window = window
        self.fieldIsSecure = fieldIsSecure
    }
}

/// Compares the key-down target with live focus. Pure given the reader, so every branch is
/// unit-tested with a fake reader (`TargetGuardTests`).
///
/// Secure fields: once the target has moved, a field that is or *might* be a password field
/// (`.unknown`) fails closed — nothing is pasted and nothing is staged on the clipboard for it.
/// The key-down field itself is refused only when it positively read as secure at key-down, so an
/// app whose AX bridge answers the subrole query with an error keeps getting its dictations.
@MainActor
public enum TargetGuard {
    public static func check<Reader: FocusReading>(
        _ bound: BoundFocus<Reader.Element>, reader: Reader
    ) -> TargetVerdict {
        guard let front = reader.frontmostApp() else { return .changed(.app) }
        let live = reader.focusedField(processID: front.processID)
        guard let boundPID = bound.processID, front.processID == boundPID, front.bundleID == bound.bundleID else {
            let change: TargetChange = bound.processID.map(reader.isRunning) == false ? .fieldClosed : .app
            return moved(change, live: live, reader: reader)
        }
        if let boundField = bound.field {
            guard let live, reader.isSame(boundField, live) else {
                return moved(reader.isAlive(boundField) ? .field : .fieldClosed, live: live, reader: reader)
            }
            return bound.fieldIsSecure ? .secureField(change: nil) : .unchanged
        }
        // No field identity at key-down: fall back to the window, then to "same app".
        if let boundWindow = bound.window, let liveWindow = reader.focusedWindow(processID: front.processID),
           !reader.isSame(boundWindow, liveWindow) {
            return moved(reader.isAlive(boundWindow) ? .window : .fieldClosed, live: live, reader: reader)
        }
        if let live, reader.security(live) == .secure { return .secureField(change: nil) }
        return .unchanged
    }

    private static func moved<Reader: FocusReading>(
        _ change: TargetChange, live: Reader.Element?, reader: Reader
    ) -> TargetVerdict {
        if let live, reader.security(live) != .notSecure { return .secureField(change: change) }
        return .changed(change)
    }
}
