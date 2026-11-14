import AppKit
import ApplicationServices
import MurmurCore

/// Reads what the focused field of a code editor is (a chat box, the code buffer, the terminal) from the class names and
/// labels Chromium gives to Accessibility, for `EditorChatSurface`. Blocking and bounded; run it off the main thread, in
/// `startWindowRead`'s detached task. It reads class tokens and labels only, never the field's text.
enum EditorChatReader {
    /// How far up from the focused element to look. The chat box's marker class sits a few levels above the input.
    private static let maxAncestors = 14
    private static let budget: Duration = .milliseconds(400)
    private static let perReadTimeout: Float = 0.05

    static func facts(pid: pid_t) -> EditorChatSurface.Facts {
        let started = ContinuousClock.now
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, perReadTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return EditorChatSurface.Facts() }
        var current = focused as! AXUIElement
        var classNames = [String](), labels = [String]()
        for _ in 0...maxAncestors {
            AXUIElementSetMessagingTimeout(current, perReadTimeout)
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, "AXDOMClassList" as CFString, &raw) == .success,
               let list = raw as? [String] { classNames += list }
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute] {
                var text: CFTypeRef?
                if AXUIElementCopyAttributeValue(current, attribute as CFString, &text) == .success,
                   let value = text as? String, !value.isEmpty { labels.append(value) }
            }
            if ContinuousClock.now - started > budget { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        return EditorChatSurface.Facts(classNames: classNames, labels: labels)
    }

    /// What the focused field is, or nil when the app is not an editor with a chat box.
    static func surface(bundleID: String?, pid: pid_t) -> EditorChatSurface.Surface? {
        guard EditorChatSurface.isEditor(bundleID: bundleID) else { return nil }
        return EditorChatSurface.surface(for: facts(pid: pid))
    }
}
