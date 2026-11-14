import MurmurCore
import SwiftUI

/// One app group: the header (icon, app name, count) and its entries as a tree — the spine runs
/// down from under the header icon, each entry branches off it to the right ("├"), and the last
/// entry closes it with a rounded elbow ("└"). Each row draws its own slice of the tree (see
/// `TimelineBranch`), exactly as History's `List` rows do, so the two screens are pixel-identical
/// and the spine stays continuous because rows sit flush (no spacing between them).
struct TimelineGroupView: View {
    let group: TimelineGroup
    var selectedID: String?
    var onSelect: ((TimelineEntry) -> Void)?
    var onUndo: ((ActionRecord) -> Void)?
    /// Collapsing is opt-in: pass both to let the header fold the group down to one line.
    var isCollapsed = false
    var onToggleCollapse: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineGroupHeader(
                group: group,
                isCollapsed: onToggleCollapse == nil ? nil : isCollapsed,
                onToggle: onToggleCollapse)
                .padding(.bottom, 2)
            ForEach(Array((isCollapsed ? [] : group.entries).enumerated()), id: \.element.id) { index, entry in
                TimelineEntryRow(
                    entry: entry,
                    isLast: index == group.entries.count - 1,
                    isSelected: selectedID == entry.id,
                    onUndo: { if case .action(let record) = entry { onUndo?(record) } },
                    onTap: onSelect.map { select in { select(entry) } })
            }
        }
    }
}
