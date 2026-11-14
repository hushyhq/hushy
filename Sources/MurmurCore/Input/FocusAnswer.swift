import Foundation

/// Plain AX facts, classified without an Accessibility dependency.
public enum FocusAnswer: String, Sendable, Equatable {
    case field, noField = "no-field", unknown

    public static func classify(
        role: String?, subrole: String?, valueSettable: Bool,
        hasSelectedTextRange: Bool, bundleID: String?, ownWindowTextView: Bool? = nil,
        positivelyNoWindow: Bool = false
    ) -> Self {
        if let ownWindowTextView { return ownWindowTextView ? .field : .noField }
        if role == nil && positivelyNoWindow { return .noField }
        // Finder is the one app known by name: it draws no text of its own, so there is somewhere
        // to type only while a real text element has focus (renaming a file, its search field).
        // With nothing focused it is the desktop, as on main.
        let isFinder = bundleID == "com.apple.finder"
        guard let role else { return isFinder ? .noField : .unknown }
        if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXTextView"].contains(role) {
            return valueSettable || hasSelectedTextRange ? .field : .unknown
        }
        // A concrete non-text control is not an editor even when its value can be set (a slider
        // is the common example). A reported text selection still needs the cautious path.
        if !hasSelectedTextRange && ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch",
            "AXImage", "AXVideo", "AXMenuBar", "AXList", "AXTable", "AXOutline", "AXPopUpButton",
            "AXTab", "AXLink", "AXProgressIndicator"].contains(role) { return .noField }
        // A settable value or text selection on an unfamiliar element might belong to a custom
        // editor. An unreadable role gives no evidence either.
        if valueSettable || hasSelectedTextRange || role.isEmpty { return .unknown }
        // Finder's known desktop/container roles are concrete non-editing surfaces. An
        // unfamiliar role is still insufficient evidence, even in Finder.
        if isFinder && ["AXScrollArea", "AXGroup", "AXWindow", "AXBrowser"].contains(role) {
            return .noField
        }
        // Container and structural roles (windows, groups, scroll areas, toolbars) can host custom-drawn
        // editors; static text, rows, cells and future roles cannot rule one out. Menus and menu
        // items stay unknown: a web autocomplete list can report its highlighted item as focused
        // while the caret is still in the input. Password subroles are checked separately by
        // TargetGuard before any paste.
        return .unknown
    }
}

/// When a field found at paste time may replace what key-down saw.
///
/// Key-down can miss the field: Electron and Chromium build their accessibility tree only once
/// something asks for it, so the first answer is nothing at all, or only a container (a web area,
/// a group), and the real field is reported a moment later. Two cases are adopted, both only in
/// the same app and the same window, both only when key-down's answer was uncertain, and both only
/// for a field that positively reads as not a password field (a security read that failed or
/// timed out is not a yes):
///
/// - Nothing at key-down: a field now focused in that window.
/// - A container at key-down: a field now focused *inside that container* (its parent chain
///   reaches the key-down element within `ancestorLimit` steps).
///
/// Anything else (another window, a field outside that subtree, a parent that could not be read,
/// a field whose security is unknown) is not adopted, and the delivery guard treats it as before
/// (DECISIONS 2026-09-27, narrowed 2026-10-11).
///
/// Known breadth, accepted for now. Both cases adopt whichever field has focus at paste time, and
/// a web area contains every field on its page. A person who clicked from one field to another on
/// the same page while speaking gets the paste in the second field. Nothing read today says
/// *when* the field gained focus: the two looks are at key-down and at paste time. Telling the
/// two apart needs a look in between (shortly after key-down, once the tree has settled).
public enum FocusRefresh {
    /// How far up the parent chain a late field is followed to find the key-down container.
    /// Web pages nest deeply; each step is one accessibility read.
    public static let ancestorLimit = 24

    public static func mayAdopt(original: FocusAnswer, hadElement: Bool, sameApp: Bool,
                                sameWindow: Bool, current: FocusAnswer,
                                insideOriginal: Bool = false, security: FieldSecurity = .notSecure) -> Bool {
        guard original == .unknown, sameApp, sameWindow, current == .field, security == .notSecure else { return false }
        return !hadElement || insideOriginal
    }

    /// True when `ancestor` is reached by following `parent` from `element`, within `limit` steps.
    /// A parent that cannot be read ends the search: not inside.
    public static func isInside<Element>(
        _ element: Element, ancestor: Element, limit: Int = ancestorLimit,
        parent: (Element) -> Element?, isSame: (Element, Element) -> Bool
    ) -> Bool {
        var current = element
        for _ in 0..<max(0, limit) {
            guard let next = parent(current) else { return false }
            if isSame(next, ancestor) { return true }
            current = next
        }
        return false
    }
}

/// What one look at the field says, in numbers only: how many characters it holds, how many are
/// selected and where the caret is. Any of them may be unreadable. An absent selection length
/// means replacement cannot be ruled out.
public struct LandingProbe: Sendable, Equatable {
    public let characterCount: Int?
    public let selectedLength: Int?
    /// Where the selection starts (the caret, when nothing is selected).
    public let caretLocation: Int?

    public init(characterCount: Int?, selectedLength: Int?, caretLocation: Int? = nil) {
        self.characterCount = characterCount
        self.selectedLength = selectedLength
        self.caretLocation = caretLocation
    }
}
