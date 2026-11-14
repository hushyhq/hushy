import Foundation

/// One element of an Accessibility tree, as far as the reach probe needs it: how many characters of text it holds
/// and what is under it. A node never hands out its text: the probe counts characters and nothing else, so no text
/// can be printed or saved by mistake. The real implementation is in `Sources/hushy-ax-probe`; tests use a fake tree.
public protocol AccessibilityReachNode {
    /// Characters of text the element exposes (its value, title or description, the longest of them); 0 for none.
    func textCharacterCount() -> Int
    /// The elements directly under this one, in on-screen order.
    func childNodes() -> [any AccessibilityReachNode]
    /// True for the root of web content (an AXWebArea), so the probe can say whether it reached any.
    var isWebArea: Bool { get }
}

extension AccessibilityReachNode {
    public var isWebArea: Bool { false }
}

/// What the probe found. Counts only.
public struct AccessibilityReachCounts: Equatable, Sendable {
    public enum Stop: String, Sendable { case completed, timeLimit, elementLimit }
    public var elementsVisited = 0
    public var textElements = 0
    /// Web content roots (AXWebArea) met, and elements and characters found at or under them.
    public var webAreas = 0
    public var webElements = 0
    public var webCharacters = 0
    public var totalCharacters = 0
    public var elapsedMilliseconds = 0
    /// Time at which the running total first passed `AccessibilityReachProbe.Budget.characterTarget`; nil if it never did.
    public var millisecondsToCharacterTarget: Int?
    public var stoppedBy = Stop.completed

    public init() {}
}

/// Walks a window's Accessibility tree breadth-first (the nearest elements first) under a time and element cap, and
/// reports how much text was reachable. Measurement for docs/product/SCREEN-CONTEXT-PLAN.md; nothing in the app uses it.
public enum AccessibilityReachProbe {
    public struct Budget: Equatable, Sendable {
        public var milliseconds: Int
        public var maxElements: Int
        /// The reading cap in the plan (about 4,000 characters): the probe notes when the walk got there.
        public var characterTarget: Int

        public init(milliseconds: Int = 150, maxElements: Int = 20_000, characterTarget: Int = 4_000) {
            self.milliseconds = milliseconds
            self.maxElements = maxElements
            self.characterTarget = characterTarget
        }
    }

    /// `elapsedMilliseconds` is read before each element, so a test can drive the clock.
    public static func walk(
        root: any AccessibilityReachNode, budget: Budget = Budget(), elapsedMilliseconds: () -> Int
    ) -> AccessibilityReachCounts {
        var counts = AccessibilityReachCounts()
        // Each queued element knows whether it is at or under web content.
        var queue: [(node: any AccessibilityReachNode, inWeb: Bool)] = [(root, false)]
        var head = 0
        while head < queue.count {
            let now = elapsedMilliseconds()
            if now >= budget.milliseconds { counts.stoppedBy = .timeLimit; counts.elapsedMilliseconds = now; return counts }
            if counts.elementsVisited >= budget.maxElements { counts.stoppedBy = .elementLimit; counts.elapsedMilliseconds = now; return counts }
            let (node, parentInWeb) = queue[head]
            head += 1
            counts.elementsVisited += 1
            let inWeb = parentInWeb || node.isWebArea
            if node.isWebArea { counts.webAreas += 1 }
            if inWeb { counts.webElements += 1 }
            let characters = max(0, node.textCharacterCount())
            if inWeb { counts.webCharacters += characters }
            if characters > 0 {
                counts.textElements += 1
                counts.totalCharacters += characters
                if counts.millisecondsToCharacterTarget == nil, counts.totalCharacters >= budget.characterTarget {
                    counts.millisecondsToCharacterTarget = now
                }
            }
            queue.append(contentsOf: node.childNodes().map { ($0, inWeb) })
        }
        counts.elapsedMilliseconds = elapsedMilliseconds()
        return counts
    }

    /// The one line the tool prints for a walk: counts and times, never text.
    public static func line(_ label: String, _ counts: AccessibilityReachCounts) -> String {
        let target = counts.millisecondsToCharacterTarget.map { "\($0) ms" } ?? "not reached"
        return "\(label): elements=\(counts.elementsVisited) textElements=\(counts.textElements) "
            + "characters=\(counts.totalCharacters) webAreas=\(counts.webAreas) webElements=\(counts.webElements) "
            + "webCharacters=\(counts.webCharacters) time=\(counts.elapsedMilliseconds) ms "
            + "4000CharactersAt=\(target) stoppedBy=\(counts.stoppedBy.rawValue)"
    }
}
