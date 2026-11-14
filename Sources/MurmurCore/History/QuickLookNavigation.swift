import Foundation

/// Previous/next stepping for Home's Quick Look dictation panel, in the feed's visual order:
/// top to bottom across every group, visiting only dictations (notes and voice actions have
/// no Quick Look, so the arrows skip straight over them). Pure, so the order rules are tested
/// without a window.
public enum QuickLookNavigation {
    public enum Direction: Sendable {
        case previous, next
    }

    /// Dictation ids in the order they appear in `groups`.
    public static func dictationIDs(in groups: [TimelineGroup]) -> [Int64] {
        groups.flatMap(\.entries).compactMap { entry in
            if case .dictation(let item) = entry { return item.id }
            return nil
        }
    }

    /// The dictation one step from `current` in `direction`, or nil at either end. When
    /// `current` is no longer in the feed (deleted, or aged out of "today"), stepping starts
    /// from the nearest end instead of doing nothing: next → first, previous → last.
    public static func neighbor(of current: Int64?, in groups: [TimelineGroup], direction: Direction) -> Int64? {
        neighbor(of: current, inOrder: dictationIDs(in: groups), direction: direction)
    }

    public static func neighbor(of current: Int64?, inOrder order: [Int64], direction: Direction) -> Int64? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return direction == .next ? order.first : order.last
        }
        let target = direction == .next ? index + 1 : index - 1
        return order.indices.contains(target) ? order[target] : nil
    }
}
