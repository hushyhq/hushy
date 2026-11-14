import AppKit
import ApplicationServices
import MurmurCore

/// Reads the conversation around the focused text box, from the focused window's Accessibility tree, for
/// "Context awareness": the terms in it (names, product words, jargon) help the recogniser and the spelling fixer for
/// that one dictation. The text goes through `ContextExtractor` and is dropped; it is not logged, kept or sent, and it
/// never reaches a model prompt. The walking rule is `WindowTextReader`; this file only adapts Accessibility to it and
/// applies the same refusals as `ContextReader`.
enum WindowContextReader {
    /// Counts only: nothing here holds text.
    struct Outcome: Sendable {
        let terms: [String]
        let characters: Int
        let nodesVisited: Int
        let milliseconds: Int
        let stoppedBy: WindowTextReader.Result.Stop
        /// Ordinary-word tokens present in the read text but kept out of the boost list (`LearningLexicon`).
        let commonWordFiltered: Int
    }

    /// nil when the app is not read at all: excluded by the person, a password manager or credential surface, a web
    /// browser, a secure focused field, or no focused element. Blocking and bounded (about 150 ms plus one Accessibility
    /// call); call it off the main thread.
    static func read(bundleID: String?, pid: pid_t, excludedApps: Set<String>, terminal: Bool = false) -> Outcome? {
        guard let bundleID,
              !excludedApps.contains(bundleID), !ContextReader.isDenylisted(bundleID: bundleID),
              !WindowContextPolicy.isBrowser(bundleID) else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard !ContextReader.isSecureField(element) else { return nil }
        let started = ContinuousClock.now
        let node = AXWindowNode(element: element, visibleTerminal: terminal)
        let result = terminal ? WindowTextReader.readVisibleTerminal(from: node) : WindowTextReader.read(from: node) {
            let spent = ContinuousClock.now - started
            return Int(spent.components.seconds * 1_000 + spent.components.attoseconds / 1_000_000_000_000_000)
        }
        return Outcome(
            terms: terminal ? TerminalScreenTerms.extract(result.text) : ContextExtractor.extractWidened(from: result.text),
            characters: result.characters,
            nodesVisited: result.nodesVisited, milliseconds: result.elapsedMilliseconds, stoppedBy: result.stoppedBy,
            commonWordFiltered: ContextTermTrace.commonWordFiltered(from: result.text))
    }
}

/// One Accessibility element as a `WindowTextNode`. Reads happen when asked, each limited by the messaging timeout.
private struct AXWindowNode: WindowTextNode {
    let element: AXUIElement
    var visibleTerminal = false

    var identity: AnyHashable { AnyHashable(element) }
    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }

    var frame: CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    func text() -> String? {
        let role = self.role
        if role == "AXSecureTextField" || (subrole ?? "").localizedCaseInsensitiveContains("secure") { return nil }
        if visibleTerminal {
            var rawRange: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &rawRange) == .success,
                  let rawRange, CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(rawRange as! AXValue, .cfRange, &range) else { return nil }
            var rawText: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                             rawRange, &rawText) == .success else { return nil }
            return rawText as? String
        }
        if let value = string(kAXValueAttribute), !value.isEmpty { return value }
        if let role, ["AXStaticText", "AXHeading", "AXTextArea"].contains(role) {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(attribute), !text.isEmpty { return text }
            }
        }
        return nil
    }

    func parentNode() -> (any WindowTextNode)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXWindowNode(element: value as! AXUIElement, visibleTerminal: visibleTerminal)
    }

    func childNodes() -> [any WindowTextNode] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.map { AXWindowNode(element: $0, visibleTerminal: visibleTerminal) }
    }

    private func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// What the window read found for one dictation, shared between the background read and the key release. The read
/// publishes once; the release takes whatever is there and never waits, so a late read changes nothing.
final class WindowContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var published: [String]?
    private var vocabulary: VocabularyContext?
    private var commonWordFiltered = 0
    private var agentPrompt = false

    /// The field terms followed by the window's, once the read has finished with terms; nil before that.
    var terms: [String]? { lock.withLock { published } }
    var filteredCommonWords: Int { lock.withLock { commonWordFiltered } }
    /// The recogniser vocabulary for those terms, once set (the early-cleaning passes use it when it is).
    var readyVocabulary: VocabularyContext? { lock.withLock { vocabulary } }
    var isAgentPrompt: Bool { lock.withLock { agentPrompt } }

    func publish(_ terms: [String], commonWordFiltered: Int = 0) {
        lock.withLock {
            if published == nil {
                published = terms
                self.commonWordFiltered = commonWordFiltered
            }
        }
    }
    func setVocabulary(_ value: VocabularyContext) { lock.withLock { vocabulary = value } }
    func markAgentPrompt() { lock.withLock { agentPrompt = true } }
}
