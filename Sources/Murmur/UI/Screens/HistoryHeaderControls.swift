import MurmurCore
import SwiftUI

/// The fuller date filter's entry point: a funnel icon that fills in when a range is active, and
/// opens `HistoryDateFilterPopover` on click. The three everyday choices are `HistoryScopeBar`
/// beside it; this holds the rest (yesterday, 30 days, a custom range). Kept separate from the
/// "Jump to a date" calendar button (which scrolls the already-loaded list to a day, not a SQL
/// filter).
struct HistoryDateFilterButton: View {
    @Binding var dateRange: HistoryDateRange?
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: dateRange == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(dateRange == nil ? Theme.textSecondary : Theme.phosphor)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Filter by date")
        .accessibilityLabel("Filter by date")
        .accessibilityValue(dateRange?.label ?? HistoryScope.allDates.title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HistoryDateFilterPopover(dateRange: $dateRange, isPresented: $isPresented)
        }
    }
}

/// Preset list plus a "Custom range…" disclosure with two compact `DatePicker`s. Presets apply
/// immediately on click (closing the popover); Custom needs an explicit Apply so a half-picked
/// range never fires a query per click.
struct HistoryDateFilterPopover: View {
    @Binding var dateRange: HistoryDateRange?
    @Binding var isPresented: Bool
    @State private var showCustom = false
    @State private var customStart = Calendar.current.startOfDay(for: Date())
    @State private var customEnd = Calendar.current.startOfDay(for: Date())

    private static let presets: [HistoryDateRange] = [.today, .yesterday, .last7Days, .last30Days]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            presetRow(title: HistoryScope.allDates.title, isSelected: dateRange == nil) {
                dateRange = nil
                isPresented = false
            }
            ForEach(Self.presets, id: \.label) { preset in
                presetRow(title: preset.label, isSelected: dateRange == preset) {
                    dateRange = preset
                    isPresented = false
                }
            }
            Divider().overlay(Theme.hairline).padding(.vertical, Theme.Space.xs)
            Button {
                withAnimation(Theme.fade) { showCustom.toggle() }
            } label: {
                HStack {
                    Text("Custom range…").font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(showCustom ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pick a custom start and end date")
            .accessibilityLabel("Custom range")
            .accessibilityHint("Choose a start and end date")

            if showCustom {
                customRangeControls
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 240)
    }

    private var customRangeControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            DatePicker("Start", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                .datePickerStyle(.compact)
                .help("Start of the custom range")
                .accessibilityLabel("Custom range start date")
                .onChange(of: customStart) { _, newValue in
                    if newValue > customEnd { customEnd = newValue }
                }
            DatePicker("End", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                .datePickerStyle(.compact)
                .help("End of the custom range")
                .accessibilityLabel("Custom range end date")
            HStack {
                Button("Clear") {
                    dateRange = nil
                    isPresented = false
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Remove the date filter")
                Spacer()
                Button("Apply") {
                    dateRange = .custom(start: customStart, end: customEnd)
                    isPresented = false
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Apply the custom date range")
                .accessibilityLabel("Apply custom range")
            }
            .padding(.top, Theme.Space.xs)
        }
        .padding(.top, Theme.Space.xs)
    }

    private func presetRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.phosphor)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, Theme.Space.xxs)
        }
        .buttonStyle(.plain)
        .help("Show dictations from \(title.lowercased())")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Removable chip showing the active date filter, matching the app/status chips' capsule look.
/// The ✕ clears the filter without opening the popover, mirroring `SearchField`'s clear button.
struct DateRangeChip: View {
    let label: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold))
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Clear date filter")
            .accessibilityLabel("Clear date filter")
        }
        .foregroundStyle(Theme.onPhosphor)
        .padding(.horizontal, Theme.Space.s + 2)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.phosphorFill))
    }
}
