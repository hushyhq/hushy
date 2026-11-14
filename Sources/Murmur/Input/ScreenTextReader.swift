import AppKit
import ApplicationServices
import MurmurCore

/// "Summarize this": reads the visible text of the frontmost app's focused window through the
/// Accessibility API (browser pages, Mail, Slack, Preview PDFs, Notes). Same rules as
/// `ContextReader`: password managers and secure fields are never read, a hung app can't stall
/// the pill (150 ms per call), and nothing read is logged or kept beyond the one summary. The
/// text is **untrusted**: it goes to `ScreenSummarizer` only, never to the action extractor.
enum ScreenTextReader {
    struct Window {
        let appName: String
        let title: String
        let text: String
        var wordCount: Int { TextStats.wordCount(text) }
    }

    /// Enough for a long article; more would only slow the read.
    static let maxCharacters = 24_000
    static let maxElements = 1_500
    static let maxDepth = 40

    /// Roles whose value or title is page content.
    static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell", "AXRow", "AXListMarker",
    ]

    /// Roles never descended into: chrome, not content.
    static let skippedRoles: Set<String> = ["AXMenuBar", "AXToolbar", "AXTabGroup", "AXScrollBar", "AXPopUpButton", "AXMenu"]

    static func frontWindowText() -> Window? {
        guard let app = NSWorkspace.shared.frontmostApplication, !ContextReader.isDenylisted(bundleID: app.bundleIdentifier) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = focused as! AXUIElement
        var collector = Collector()
        collector.walk(window, depth: 0)
        let text = collector.lines.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return Window(appName: app.localizedName ?? "App", title: stringAttribute(window, kAXTitleAttribute) ?? "", text: text)
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Depth-first over the window, gathering text in reading order.
    struct Collector {
        var lines: [String] = []
        var characters = 0
        var visited = 0

        mutating func walk(_ element: AXUIElement, depth: Int) {
            guard depth < maxDepth, visited < maxElements, characters < maxCharacters else { return }
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if skippedRoles.contains(role) || ContextReader.isSecureField(element) { return }
            if textRoles.contains(role), let text = content(of: element, role: role) {
                lines.append(text)
                characters += text.count
                // A text area's value already holds its children's words.
                if role == "AXTextArea" || role == "AXTextField" { return }
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list { walk(child, depth: depth + 1) }
        }

        private func content(of element: AXUIElement, role: String) -> String? {
            let raw = stringAttribute(element, kAXValueAttribute) ?? (role == "AXLink" || role == "AXHeading" ? stringAttribute(element, kAXTitleAttribute) : nil)
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(maxCharacters - characters))
        }
    }
}
