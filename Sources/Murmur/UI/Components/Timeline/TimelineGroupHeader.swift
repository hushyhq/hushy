import MurmurCore
import SwiftUI

/// The mockup's app-group header: a rounded-square app icon (real app icon, falling back to a
/// colored initial — reusing `AppBadge`'s exact look) + app name in semibold. "N dictations"
/// appears only while the group is *collapsed*, where it says what expanding will reveal; an
/// expanded group already shows its rows, so a count there is just a decorative total. Shared by Home's Today feed and History
/// (via the `appBundleID:appName:count:` initializer, since History's runs are keyed off
/// `HistoryTimelineRow`, not `TimelineEntry` — see `HistoryListContent`).
struct TimelineGroupHeader: View {
    let appBundleID: String?
    let appName: String?
    let count: Int
    /// When set, the header shows a chevron and toggles its group open/closed on click.
    var isCollapsed: Bool?
    var onToggle: (() -> Void)?
    @State private var hovering = false

    init(group: TimelineGroup, isCollapsed: Bool? = nil, onToggle: (() -> Void)? = nil) {
        appBundleID = group.appBundleID
        appName = group.appName
        count = group.entries.count
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
    }

    init(appBundleID: String?, appName: String?, count: Int) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.count = count
    }

    var body: some View {
        if let onToggle, count > 1 {
            Button(action: onToggle) { label }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(Theme.fade, value: hovering)
                .help(isCollapsed == true ? "Show \(count) dictations" : "Collapse")
                .accessibilityLabel(isCollapsed == true ? "\(appName ?? "Dictation"), \(count) dictations" : appName ?? "Dictation")
                .accessibilityValue(isCollapsed == true ? "Collapsed" : "Expanded")
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: Theme.Space.s) {
            AppBadge(bundleID: appBundleID, appName: appName)
            Text(appName ?? "Dictation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if isCollapsed == true, count > 1 {
                Text("\(count) dictations")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let isCollapsed, onToggle != nil, count > 1 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(Theme.fade, value: isCollapsed)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A day header inside the timeline list ("Today", "Yesterday", "Wed, Sep 23") — shares its
/// label logic with the History scrubber via `HistoryScrubberModel.dayLabel`.
struct TimelineDayHeader: View {
    let day: Date

    var body: some View {
        Text(HistoryScrubberModel.dayLabel(for: day))
            .font(Theme.Font.eyebrow)
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, Theme.Space.xs)
    }
}
