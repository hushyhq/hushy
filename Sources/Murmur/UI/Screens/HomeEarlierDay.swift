import MurmurCore
import SwiftUI

/// The most recent earlier day on Home, as one collapsed row below the Today card
/// ("Yesterday · 14 dictations · 2 voice actions"). Opening it shows that day's timeline in
/// place, with the same dictation cap and "Show N more" row as Today.
struct EarlierDaySection: View {
    let day: HomeDayEntries
    let groups: [TimelineGroup]
    let isOpen: Bool
    let showAll: Bool
    let selectedEntryID: String?
    let onToggleOpen: () -> Void
    let onToggleShowAll: () -> Void
    let onSelect: (TimelineEntry) -> Void
    let onUndo: (ActionRecord) -> Void
    @State private var collapsed: Set<String> = []

    var body: some View {
        Card(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HomeDisclosureRow(
                    title: day.summary, isExpanded: isOpen, collapsedAngle: -90, expandedAngle: 0,
                    accessibilityLabel: (isOpen ? "Hide " : "Show ") + day.summary,
                    action: onToggleOpen)
                if isOpen {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(groups) { group in
                            let key = group.entries.last?.id ?? String(group.id)
                            TimelineGroupView(
                                group: group, selectedID: selectedEntryID,
                                onSelect: onSelect, onUndo: onUndo,
                                isCollapsed: collapsed.contains(key),
                                onToggleCollapse: { toggle(key) })
                        }
                        if day.hiddenDictationCount > 0 {
                            HomeShowMoreRow(hiddenCount: day.hiddenDictationCount, isExpanded: showAll, day: day.label, action: onToggleShowAll)
                        }
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.bottom, Theme.Space.s)
                    .transition(.opacity)
                }
            }
        }
        .animation(Theme.fade, value: isOpen)
    }

    private func toggle(_ key: String) {
        withAnimation(Theme.fade) {
            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        }
    }
}

/// "Show 12 more" / "Show fewer" at the bottom of a day's entries.
struct HomeShowMoreRow: View {
    let hiddenCount: Int
    let isExpanded: Bool
    /// Names the day for VoiceOver ("Today", "Yesterday").
    let day: String
    let action: () -> Void

    var body: some View {
        HomeDisclosureRow(
            title: isExpanded ? "Show fewer" : "Show \(hiddenCount) more",
            isExpanded: isExpanded, collapsedAngle: 0, expandedAngle: 180,
            accessibilityLabel: isExpanded
                ? "Show fewer dictations from \(day.lowercased())"
                : "Show \(hiddenCount) more \(hiddenCount == 1 ? "dictation" : "dictations") from \(day.lowercased())",
            action: action)
    }
}
