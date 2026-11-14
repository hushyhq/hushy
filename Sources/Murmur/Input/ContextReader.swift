import AppKit
import ApplicationServices
import MurmurCore

/// Reads the text around the insertion point in the focused app via the Accessibility API, for
/// "Context awareness" (Settings → Privacy & data, on by default). Called once at the start of
/// a dictation, from `DictationController.begin`; the caller uses the result for that single
/// dictation and drops it immediately — nothing this returns is ever logged or persisted (see
/// `.claude/DECISIONS.md`'s context-awareness entry). Pulling text out is the only impure part
/// of this feature; everything that interprets it (`ContextExtractor`/`ContextSpellingFixer`)
/// lives in MurmurCore and is pure/testable.
enum ContextReader {
    /// One-shot read. Exclusions are checked before querying Accessibility at all.
    static func terms(app: NSRunningApplication?, excludedApps: Set<String>) -> [String] {
        termSnapshot(app: app, excludedApps: excludedApps).terms
    }

    /// Boost terms and edit-learning evidence share one read and the same security gate.
    static func termSnapshot(app: NSRunningApplication?, excludedApps: Set<String>) -> (terms: [String], evidence: [String]) {
        guard let bundleID = app?.bundleIdentifier,
              !excludedApps.contains(bundleID), !isDenylisted(bundleID: bundleID),
              let pid = app?.processIdentifier else { return ([], []) }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return ([], []) }
        let element = focused as! AXUIElement
        guard !isSecureField(element) else { return ([], []) }
        let field = surroundingText(app: app) ?? ""
        var windowTitle = ""
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success {
                windowTitle = title as? String ?? ""
            }
        }
        let text = String(field.suffix(ContextExtractor.maxWindowLength)) + " " + String(windowTitle.prefix(256))
        return (ContextExtractor.extract(from: text), ScreenTermEvidence.extract(from: text))
    }
    /// Bundle IDs of password managers: their fields are exactly the kind of sensitive content
    /// this feature must never read, even when AX doesn't mark the individual field secure
    /// (e.g. a manager's own unlock/search UI, not just the fields it fills into other apps).
    static let passwordManagerBundleIDs: Set<String> = [
        "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.lastpassmacdesktop", "com.dashlane.dashlanephonefinal",
        "com.callpod.keepersecurity", "com.nordpass.macos", "com.apple.Passwords",
    ]

    /// Extra denylist beyond password managers/secure fields: apps where reading surrounding
    /// text would routinely surface sensitive content (system credential UI, banking-adjacent
    /// system panes) even though they're not password managers per se.
    static let bundleIDDenylist: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.systempreferences", "com.apple.preference.security",
    ]

    /// True when this app should never have its surrounding text read, regardless of what field
    /// has focus — password managers and a small denylist of system credential surfaces.
    static func isDenylisted(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return passwordManagerBundleIDs.contains(bundleID) || bundleIDDenylist.contains(bundleID)
    }

    /// Reads up to `ContextExtractor.maxWindowLength` characters of text around the insertion
    /// point in `app`'s currently focused element, or nil when the app is denylisted, no element
    /// is focused, the field is a secure text field, or AX can't provide a value. Deliberately
    /// conservative: any uncertainty about whether a field is safe to read returns nil rather
    /// than guessing.
    static func surroundingText(app: NSRunningApplication?) -> String? {
        guard !isDenylisted(bundleID: app?.bundleIdentifier), let pid = app?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        // A hung app must never delay the start of a dictation: AX's default is 6 s per call.
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard !isSecureField(element) else { return nil }

        guard let value = stringValue(element) else { return nil }
        // Trim to the window around the caret when the field's full value is much longer than
        // the window — cheaper than reading a huge document, and matches the "±1,000 characters
        // around the insertion point" requirement more literally than just taking the value's
        // tail. Falls back to the trailing window of the whole value when the caret position
        // isn't available (most editors don't expose it via this attribute, so this is the
        // common path) — `ContextExtractor.extract` already caps to the last 1,000 characters
        // itself, so this is a belt-and-suspenders trim, not the only enforcement point.
        if let caret = insertionPointOffset(element), value.count > ContextExtractor.maxWindowLength * 2 {
            return windowed(value, around: caret)
        }
        return value
    }

    /// True for AXSecureTextField and any element whose subrole marks it as protected — the
    /// hard "never read this" signal from the Accessibility API itself. Fails closed: if the role
    /// can't be read (timeout, dead app), or the subrole query errors for any reason other than
    /// "this element has no subrole", the field is treated as secure and never read.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        security(of: element) != .notSecure
    }

    /// The three-way answer behind `isSecureField`; `TargetGuard` needs to tell "known secure"
    /// from "couldn't tell" (see its doc comment).
    static func security(of element: AXUIElement) -> FieldSecurity {
        securityRead(of: element).security
    }

    /// The same answer with the error of the read that left it unknown (`.success` otherwise), for
    /// the paste diagnosis log line.
    /// `isSpent` is asked before each of the two reads; a read that is not started leaves the
    /// answer unknown, which every caller treats as "might be a password field".
    static func securityRead(
        of element: AXUIElement, isSpent: () -> Bool = { false }
    ) -> (security: FieldSecurity, error: AXError) {
        guard !isSpent() else { return (.unknown, .cannotComplete) }
        var roleValue: CFTypeRef?
        let roleRead = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        guard roleRead == .success, let role = roleValue as? String else {
            return (.unknown, roleRead == .success ? .failure : roleRead)
        }
        if role == "AXSecureTextField" { return (.secure, .success) }
        guard !isSpent() else { return (.unknown, .cannotComplete) }
        var subroleValue: CFTypeRef?
        let subroleRead = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        switch subroleRead {
        case .success:
            if let subrole = subroleValue as? String, subrole.localizedCaseInsensitiveContains("secure") {
                return (.secure, .success)
            }
            return (.notSecure, .success)
        case .noValue, .attributeUnsupported:
            return (.notSecure, .success)
        default:
            return (.unknown, subroleRead)
        }
    }

    private static func stringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The caret's character offset, when the field exposes a zero-length selected range at the
    /// insertion point. Returns nil (not zero) when unavailable, so callers can distinguish "no
    /// caret info" from "caret at position zero."
    private static func insertionPointOffset(_ element: AXUIElement) -> Int? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) else { return nil }
        return range.location
    }

    /// The up-to-1,000-character window of `text` centered on `offset`, clamped to the string's
    /// bounds.
    private static func windowed(_ text: String, around offset: Int) -> String {
        let half = ContextExtractor.maxWindowLength / 2
        let clampedOffset = max(0, min(offset, text.count))
        let startIndex = text.index(text.startIndex, offsetBy: max(0, clampedOffset - half))
        let endOffset = min(text.count, clampedOffset + half)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)
        guard startIndex < endIndex else { return "" }
        return String(text[startIndex..<endIndex])
    }
}
