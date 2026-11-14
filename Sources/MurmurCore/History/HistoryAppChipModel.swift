import Foundation

/// One of History's app filter chips: "All apps" (bundleID nil) or one app. Chips carry no
/// numbers: a whole-history total per app (or a count of apps) asks nothing of the user and read
/// as inaccurate next to the grouped list, so they were dropped (DECISIONS.md, "Sidebar badges:
/// only actionable counts"). Order still reflects usage — most-used app first.
public struct HistoryAppChip: Identifiable, Equatable, Sendable {
    public let bundleID: String?
    public let name: String

    public var id: String { bundleID ?? "__all__" }
    public var isAllApps: Bool { bundleID == nil }

    /// VoiceOver phrasing: "All apps" or the app's name.
    public var accessibilityLabel: String { name }

    public init(bundleID: String?, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum HistoryAppChipModel {
    /// "All apps" first, then one chip per app in the order given (Store returns most-used first).
    public static func chips(from counts: [Store.AppDictationCount]) -> [HistoryAppChip] {
        let perApp = counts.map { HistoryAppChip(bundleID: $0.bundleID, name: $0.appName ?? $0.bundleID) }
        return [HistoryAppChip(bundleID: nil, name: "All apps")] + perApp
    }
}
