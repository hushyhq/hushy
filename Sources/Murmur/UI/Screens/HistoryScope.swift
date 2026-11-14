import MurmurCore
import SwiftUI

/// History's three always-visible date scopes. "All dates" used to be a caption-sized link at the
/// far end of the week strip (and "Any time" inside a filter popover); a person looking for last
/// week's dictation had to discover it. Here it is one of three labelled choices directly under
/// the search field. History still opens on Today (DECISIONS.md, "History date strip").
enum HistoryScope: String, CaseIterable, Identifiable {
    case today
    case lastSevenDays
    case allDates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .lastSevenDays: "Last 7 days"
        case .allDates: "All dates"
        }
    }

    /// The date filter this scope applies; nil is no filter at all.
    var dateRange: HistoryDateRange? {
        switch self {
        case .today: .today
        case .lastSevenDays: .last7Days
        case .allDates: nil
        }
    }

    /// The scope that reads as chosen for a date filter, or nil when the filter is one the bar
    /// does not hold (yesterday, another single day, a custom range). Tapping today's column in
    /// the week strip is still Today.
    static func current(for range: HistoryDateRange?, now: Date = Date(), calendar: Calendar = .current) -> HistoryScope? {
        switch range {
        case nil: return .allDates
        case .today: return .today
        case .last7Days: return .lastSevenDays
        case .custom:
            let today = calendar.startOfDay(for: now)
            return range?.singleSelectedDay(now: now, calendar: calendar) == today ? .today : nil
        case .yesterday, .last30Days: return nil
        }
    }

    /// Whether the removable chip that names the active range is needed: only for a range the
    /// bar itself cannot show as chosen.
    static func showsRangeChip(for range: HistoryDateRange?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        range != nil && current(for: range, now: now, calendar: calendar) == nil
    }
}

/// The scope choices as one segmented control, drawn in SwiftUI (an AppKit segmented picker
/// cannot be drawn by `ImageRenderer`, and this needs a "none chosen" state a picker lacks).
/// The chosen segment is a raised plate that travels between segments; under Reduce Motion it
/// changes in place.
struct HistoryScopeBar: View {
    let selection: HistoryScope?
    let onSelect: (HistoryScope) -> Void
    @Namespace private var plate
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryScope.allCases) { scope in
                ScopeSegment(scope: scope, isSelected: scope == selection, plate: plate) { onSelect(scope) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).fill(Theme.bgSunken))
        .animation(isSnapshot ? nil : Theme.Motion.spatial(Theme.Motion.snappy, reduceMotion: reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dates shown")
    }
}

private struct ScopeSegment: View {
    let scope: HistoryScope
    let isSelected: Bool
    let plate: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(scope.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected || hovering ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.bgRaised)
                            .shadow(color: scheme == .dark ? .clear : Theme.cardShadow.opacity(0.25), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "history-scope", in: plate)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
        .help(help)
        .accessibilityLabel(scope.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var help: String {
        switch scope {
        case .today: "Show today's dictations"
        case .lastSevenDays: "Show the last 7 days"
        case .allDates: "Show every dictation, from any date"
        }
    }
}
