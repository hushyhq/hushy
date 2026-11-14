import AppKit
import ApplicationServices
import MurmurCore

/// Reads the selected text of the focused field through Accessibility, at key-down, for voice edit
/// (`FeatureFlags.voiceEdit`). The text lives in that one dictation's settings and is dropped with
/// them; it is never logged or stored. Password fields, password managers and the system
/// credential panes are never read (`ContextReader`'s gates), and every read is bounded so a hung
/// app cannot delay the start of a dictation.
enum SelectionReader {
    /// What the focused field shows as selected, and whether a paste could replace it.
    struct Reading: Equatable {
        let text: String
        let location: Int?
        let isEditable: Bool
    }

    /// The selection voice edit works on: only a field whose text can be replaced. A field that cannot be
    /// replaced is not read at all, so a dictation's key-down pays one call less.
    static func read(app: NSRunningApplication?) -> SelectedText? {
        guard let element = gatedElement(of: app), isEditable(element),
              let text = selectedText(of: element) else { return nil }
        return SelectedText(text: text, location: selectedRange(of: element)?.location)
    }

    /// The selection of the focused element, replaceable or not, for a person who asked to restyle it
    /// (`RestyleController`): text selected on a page or in a terminal can be rewritten into the clipboard.
    /// The same gates as `read`: never a password field, a password manager or a credential pane.
    static func readAny(app: NSRunningApplication?) -> Reading? {
        guard let element = gatedElement(of: app), let text = selectedText(of: element) else { return nil }
        return Reading(text: text, location: selectedRange(of: element)?.location, isEditable: isEditable(element))
    }

    private static func gatedElement(of app: NSRunningApplication?) -> AXUIElement? {
        guard let app, !ContextReader.isDenylisted(bundleID: app.bundleIdentifier),
              let element = focusedElement(of: app.processIdentifier),
              !ContextReader.isSecureField(element) else { return nil }
        return element
    }

    /// Text selected on a web page, in a terminal's scrollback or in a PDF cannot be replaced by a paste,
    /// so it is never edited: only a field whose value can be set counts.
    static func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func focusedElement(of pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Selects `length` UTF-16 units from `location`. False when the field does not take it.
    static func select(location: Int, length: Int, in element: AXUIElement) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
