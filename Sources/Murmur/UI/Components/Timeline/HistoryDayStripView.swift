import MurmurCore
import SwiftUI

/// The horizontal week strip: a month label, then day columns (weekday letter over the date
/// number). Each day has exactly one look, from `DayStripEntry.emphasis`: the filtered-to day is
/// a filled accent circle (the only thing that ever reads as "selected"); today, when not
/// filtered to, is an accent-coloured number with no fill; other days with dictations are
/// secondary text with a dot underneath (grey, or red when something needs attention); empty
/// days are dimmed. Hover is a hairline ring, never a fill, so a hovered day can't pass for a
/// second selection. Tapping a day filters History to it via
/// `dateRange = .custom(start: day, end: day)`; the bucketing is `HistoryDayStrip`. "All dates"
/// used to be a small link at this strip's far end; it is now a labelled choice in
/// `HistoryScopeBar`, directly above.
struct HistoryDayStripView: View {
    let days: [DayStripEntry]
    let onSelect: (Date) -> Void
    /// The selected-day circle is one object that travels between columns.
    @Namespace private var selectionCircle
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedDate: Date? { days.first { $0.emphasis == .selected }?.date }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Text(HistoryDayStrip.monthLabel(for: days))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: Theme.Space.xs) {
                ForEach(days) { day in
                    DayColumn(day: day, selectionCircle: selectionCircle) { onSelect(day.date) }
                }
            }
            .animation(isSnapshot ? nil : Theme.Motion.spatial(Theme.Motion.snappy, reduceMotion: reduceMotion), value: selectedDate)
            Spacer(minLength: 0)
        }
    }
}

private struct DayColumn: View {
    let day: DayStripEntry
    let selectionCircle: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false
    /// `ImageRenderer` captures a single frame, so an emphasis change made in `onAppear` (the
    /// snapshot switching the default Today filter to another range) would be caught mid-fade.
    @Environment(\.isSnapshot) private var isSnapshot

    private static let circle: CGFloat = 24

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // `.fixedSize()` + an explicit `.frame(width:)`, plus `.id(day.date)` for
                // distinct identity per column (the narrow weekday *label* itself repeats —
                // Tue/Thu are both "T", Sat/Sun both "S"): without a fixed intrinsic size,
                // `ImageRenderer` was non-deterministically dropping some of these `Text` views
                // entirely from a 7-wide `HStack`.
                Text(day.weekdayLetter)
                    .font(.system(size: 10, weight: day.isToday ? .bold : .medium))
                    .foregroundStyle(day.isToday ? Theme.textSecondary : Theme.textTertiary)
                    .opacity(day.emphasis == .empty ? 0.6 : 1)
                    .fixedSize()
                    .frame(width: Self.circle)
                    .id(day.date)
                Text("\(day.dayNumber)")
                    .font(.system(size: 13, weight: numberWeight).monospacedDigit())
                    .foregroundStyle(numberColor)
                    .frame(width: Self.circle, height: Self.circle)
                    .background {
                        if day.emphasis == .selected {
                            Circle().fill(Theme.phosphorFill)
                                .matchedGeometryEffect(id: "day-selection", in: selectionCircle)
                        }
                    }
                    .overlay(Circle().strokeBorder(hoverRing, lineWidth: 1))
                dot
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.fade, value: isHovered)
        .animation(isSnapshot ? nil : Theme.fade, value: day.emphasis)
        .id(day.date)
        .accessibilityLabel(Text(day.date, format: .dateTime.weekday(.wide).month().day()))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(day.emphasis == .selected ? .isSelected : [])
    }

    private var numberColor: Color {
        switch day.emphasis {
        case .selected: Theme.onPhosphor
        case .today: Theme.phosphor
        case .active: Theme.textSecondary
        case .empty: Theme.textTertiary.opacity(0.55)
        }
    }

    private var numberWeight: Font.Weight {
        switch day.emphasis {
        case .selected, .today: .semibold
        case .active, .empty: .regular
        }
    }

    private var hoverRing: Color {
        isHovered && day.emphasis != .selected ? Theme.textTertiary.opacity(0.5) : .clear
    }

    private var dot: some View {
        let color: Color = switch day.dot {
        case .none: .clear
        case .hasEntries: Theme.textTertiary.opacity(0.6)
        case .needsAttention: Theme.error
        }
        return Circle().fill(color).frame(width: 4, height: 4)
    }

    private var accessibilityValue: String {
        let activity = switch day.dot {
        case .none: "No dictations"
        case .hasEntries: "Has dictations"
        case .needsAttention: "Has dictations, some need attention"
        }
        return day.isToday ? "Today, \(activity.prefix(1).lowercased())\(activity.dropFirst())" : activity
    }
}
