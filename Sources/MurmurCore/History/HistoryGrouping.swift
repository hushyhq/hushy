import Foundation

/// Minimal shape `HistoryGrouping` needs from a history item — `Dictation` conforms below, and
/// tests use small fixtures, so the grouping algorithm never needs to import GRDB or build a
/// full `Dictation`.
public protocol HistoryGroupable {
    var groupID: Int64 { get }
    var groupCreatedAt: Date { get }
    var groupAppBundleID: String? { get }
}

extension Dictation: HistoryGroupable {
    public var groupID: Int64 { id ?? 0 }
    public var groupCreatedAt: Date { createdAt }
    public var groupAppBundleID: String? { appBundleID }
}

/// One run of consecutive, same-app items within a day. `items` keeps the caller's original
/// order (newest-first, matching `HistoryPager`'s day sections). `Identifiable` (keyed by the
/// first item's `groupID`, stable across rebuilds since runs never reorder items) so SwiftUI
/// call sites can hand runs straight to `ForEach` without a manual `id:` key path.
public struct HistoryRun<Item: HistoryGroupable>: Identifiable, Equatable where Item: Equatable {
    public let appBundleID: String?
    public let items: [Item]

    public var id: Int64 { items.first?.groupID ?? 0 }

    public init(appBundleID: String?, items: [Item]) {
        self.appBundleID = appBundleID
        self.items = items
    }
}

/// Pure grouping logic for History's "one icon per run of consecutive same-app dictations"
/// redesign (see `.claude/DECISIONS.md`, 2026-09-26 "History run grouping"). Lives in
/// MurmurCore (rather than the `Murmur` UI target) so it's unit-testable with plain `swift
/// test` — no SwiftUI/AppKit involved.
public enum HistoryGrouping {
    /// Consecutive items break into a new run when the app bundle id changes, or when the gap
    /// between one item's `createdAt` and the next exceeds `maxGap` (default 30 minutes). The
    /// day-change break rule lives one level up: callers already group items into per-day
    /// sections (see `HistoryPager.rebuildSections`) before calling this, so every run this
    /// function produces is implicitly within a single day.
    public static let defaultMaxGap: TimeInterval = 30 * 60

    /// Groups `items` (already ordered — newest-first, matching History's display order) into
    /// runs. Order is preserved; only consecutive items are ever merged into the same run, so
    /// this is a single linear pass, O(n).
    public static func runs<Item: HistoryGroupable & Equatable>(
        from items: [Item], maxGap: TimeInterval = defaultMaxGap
    ) -> [HistoryRun<Item>] {
        var result: [HistoryRun<Item>] = []
        var currentApp: String?
        var currentItems: [Item] = []
        var previous: Item?

        func flush() {
            guard !currentItems.isEmpty else { return }
            result.append(HistoryRun(appBundleID: currentApp, items: currentItems))
            currentItems = []
        }

        for item in items {
            let breaksRun: Bool = {
                guard let previous else { return false }
                if previous.groupAppBundleID != item.groupAppBundleID { return true }
                let gap = abs(previous.groupCreatedAt.timeIntervalSince(item.groupCreatedAt))
                return gap > maxGap
            }()
            if breaksRun { flush() }
            if currentItems.isEmpty { currentApp = item.groupAppBundleID }
            currentItems.append(item)
            previous = item
        }
        flush()
        return result
    }
}
