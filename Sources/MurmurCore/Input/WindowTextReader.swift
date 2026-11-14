import CoreGraphics
import Foundation

/// One element of an app window's Accessibility tree, as far as the window reader needs it. The real implementation
/// is in the app target (`WindowContextReader`); tests use a fake tree. Positions are screen points with y growing
/// downward, as Accessibility reports them.
public protocol WindowTextNode {
    /// Stable for one element within one read, so the reader can tell the branch it came from.
    var identity: AnyHashable { get }
    var role: String? { get }
    var subrole: String? { get }
    /// nil when the element has no readable position and size.
    var frame: CGRect? { get }
    /// The text this element holds, or nil. Asked at most once per element, and never for a secure field.
    func text() -> String?
    func parentNode() -> (any WindowTextNode)?
    func childNodes() -> [any WindowTextNode]
}

/// Reads the conversation around the text box a person is dictating into, from the focused window's Accessibility
/// tree, for context awareness (names and terms only; the text never reaches a model prompt). The rule:
///
/// 1. **Start at the focused element and go outward.** Look at what sits beside it under its parent, then beside the
///    parent under the grandparent, and so on, and stop at the first level where at least `minimumCharacters` of
///    text has been found (or at the window). The nearest container that holds text is the conversation the text
///    box belongs to.
/// 2. **Read only what is in the text box's column.** An element is skipped, with everything under it, when its
///    horizontal span does not overlap the focused element's. Sidebars (lists of other conversations) and side
///    panels sit to the left or right of the text box; the messages sit above it in the same column. The focused
///    element's own text is not read here (the field reader already has it).
/// 3. **Only text above the text box.** An element whose top is below the text box's top is skipped (footers,
///    disclaimers). Roles that are never conversation (toolbars, menus, tab groups, pop-up buttons, search fields,
///    secure fields) are skipped with their subtrees.
/// 4. **Newest first.** Children are visited last to first, so the bottom of the conversation is read first, and the
///    text found is ordered by closeness to the text box. The result is cut to `maxCharacters` of the newest text and
///    returned oldest to newest, so the end of the string is the nearest message.
/// 5. **Never guess a position.** With a focused frame known, an element without a frame contributes no text.
///
/// The read stops at `milliseconds`; whatever was found by then is returned. Counts are reported; the text is not
/// logged by this type or kept after it returns.
public enum WindowTextReader {
    public struct Budget: Equatable, Sendable {
        public var milliseconds = 150
        public var maxCharacters = 4_000
        public var minimumCharacters = 200
        public var maxNodes = 20_000
        public init() {}
    }

    public struct Result: Equatable, Sendable {
        public enum Stop: String, Sendable { case completed, timeLimit, nodeLimit }
        public var text = ""
        public var nodesVisited = 0
        public var textNodes = 0
        public var levelsAscended = 0
        public var elapsedMilliseconds = 0
        public var stoppedBy = Stop.completed
        public var characters: Int { text.count }
        public init() {}
    }

    static let excludedRoles: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem", "AXTabGroup", "AXPopUpButton",
        "AXMenuButton", "AXSegmentedControl", "AXScrollBar", "AXSlider", "AXSearchField", "AXSecureTextField",
    ]
    /// How far above the text box's top an element may end and still count as above it.
    static let verticalTolerance: CGFloat = 4

    private struct Found { let text: String; let distance: Double; let sequence: Int }

    public static func read(
        from focused: any WindowTextNode, budget: Budget = Budget(), elapsedMilliseconds: () -> Int
    ) -> Result {
        var result = Result()
        var found: [Found] = []
        var characters = 0
        var sequence = 0
        let focusFrame = focused.frame

        func spent() -> Bool {
            let now = elapsedMilliseconds()
            if now >= budget.milliseconds { result.stoppedBy = .timeLimit; return true }
            if result.nodesVisited >= budget.maxNodes { result.stoppedBy = .nodeLimit; return true }
            return false
        }

        func overlapsColumn(_ frame: CGRect, _ focus: CGRect) -> Bool {
            frame.maxX > focus.minX && frame.minX < focus.maxX
        }

        func scan(_ node: any WindowTextNode) {
            guard result.stoppedBy == .completed, characters < budget.maxCharacters, !spent() else { return }
            result.nodesVisited += 1
            let role = node.role
            if let role, excludedRoles.contains(role) { return }
            if (node.subrole ?? "").localizedCaseInsensitiveContains("secure") { return }
            let frame = node.frame
            if let focusFrame, let frame, !overlapsColumn(frame, focusFrame) { return }
            // Text is asked for only from an element that is placed above the text box. Unplaced text is never guessed
            // at, and text at or below the text box's top (footers, the box's own surroundings) is not asked for.
            var distance = Double(sequence)
            var mayRead = true
            if let focusFrame {
                if let frame, frame.maxY <= focusFrame.minY + verticalTolerance { distance = Double(focusFrame.minY - frame.maxY) } else { mayRead = false }
            }
            if mayRead, let text = node.text()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                found.append(Found(text: text, distance: distance, sequence: sequence))
                characters += text.count
                result.textNodes += 1
                sequence += 1
            }
            for child in node.childNodes().reversed() {
                scan(child)
                if result.stoppedBy != .completed || characters >= budget.maxCharacters { break }
            }
        }

        var came = focused.identity
        var current: any WindowTextNode = focused
        while result.stoppedBy == .completed, let parent = current.parentNode() {
            result.levelsAscended += 1
            if let role = parent.role, excludedRoles.contains(role) { break }
            for sibling in parent.childNodes().reversed() where sibling.identity != came {
                scan(sibling)
                if result.stoppedBy != .completed || characters >= budget.maxCharacters { break }
            }
            if characters >= budget.minimumCharacters || parent.role == "AXWindow" { break }
            came = parent.identity
            current = parent
        }
        result.elapsedMilliseconds = elapsedMilliseconds()
        result.text = assemble(found, maxCharacters: budget.maxCharacters)
        return result
    }

    /// A terminal exposes its visible grid as one focused text area, rather than message siblings.
    /// The adapter must supply only AX's visible character range; an unavailable range yields no text.
    public static func readVisibleTerminal(from focused: any WindowTextNode) -> Result {
        var result = Result()
        result.nodesVisited = 1
        guard let text = focused.text() else { return result }
        result.text = String(text.suffix(Budget().maxCharacters))
        result.textNodes = result.text.isEmpty ? 0 : 1
        return result
    }

    /// The newest `maxCharacters` of the found text, oldest first. A repeated line keeps its nearest place.
    private static func assemble(_ found: [Found], maxCharacters: Int) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        var total = 0
        for item in found.sorted(by: { ($0.distance, $0.sequence) < ($1.distance, $1.sequence) }) {
            guard seen.insert(item.text).inserted else { continue }
            // The cap counts the line break between lines, so the joined text never passes it.
            let room = maxCharacters - total - (kept.isEmpty ? 0 : 1)
            guard room > 0 else { break }
            kept.append(item.text.count > room ? String(item.text.suffix(room)) : item.text)
            total += min(item.text.count, room) + (kept.count > 1 ? 1 : 0)
        }
        return kept.reversed().joined(separator: "\n")
    }
}

/// File names and paths are useful spoken names even when they have no capitals or identifier case.
public enum TerminalScreenTerms {
    public static func extract(_ visibleText: String) -> [String] {
        var terms = ContextExtractor.extract(from: visibleText, window: WindowTextReader.Budget().maxCharacters,
                                             limit: WindowContextPolicy.maxMergedTerms)
        var seen = Set(terms.map { $0.lowercased() })
        for match in Regex.matchesCaseSensitive(visibleText, "(?:[~/][A-Za-z0-9_./-]+|[A-Za-z][A-Za-z0-9_-]*(?:/[A-Za-z0-9_.-]+)+|[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+)") {
            guard let value = match.string(at: 0, in: visibleText), value.count <= 64,
                  value.contains(where: \.isLetter), ScreenBoostPolicy.shouldBoost(value),
                  seen.insert(value.lowercased()).inserted else { continue }
            terms.append(value)
            if terms.count == WindowContextPolicy.maxMergedTerms { break }
        }
        return terms
    }
}

/// Which apps the window reader never touches: web browsers keep the focused-field read only (their page text is not
/// reached reliably, and a page is a different kind of content from an app's own conversation).
public enum WindowContextPolicy {
    static let extraBrowsers = [
        "org.chromium.chromium", "company.thebrowser.dia", "com.kagi.kagimacos", "ai.perplexity.comet", "com.openai.atlas",
        "com.sigmaos.sigmaos.macos", "com.duckduckgo.macos.browser", "org.torproject.torbrowser", "com.apple.safari",
        "com.google.chrome", "org.mozilla.", "com.microsoft.edgemac", "com.brave.browser", "com.vivaldi.vivaldi",
        "com.operasoftware.opera", "company.thebrowser.browser", "app.zen-browser",
    ]

    public static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return AppCategory.isBrowser(id) || extraBrowsers.contains { id.hasPrefix($0) }
    }

    /// The terms read from the window, merged after the ones the field reader found (those keep their place);
    /// capped so a long conversation cannot swamp the boost list.
    public static let maxMergedTerms = 40

    public static func merged(fieldTerms: [String], windowTerms: [String]) -> [String] {
        var seen = Set(fieldTerms.map { $0.lowercased() })
        var result = fieldTerms
        // Field terms already passed the extractor's policy; window labels are filtered before the cap so they take no slots.
        for term in ScreenBoostPolicy.filter(windowTerms).terms where seen.insert(term.lowercased()).inserted {
            result.append(term)
        }
        return Array(result.prefix(max(maxMergedTerms, fieldTerms.count)))
    }
}
