import MurmurCore
import SwiftUI

/// A Claude.ai-chat-outline-style timeline scrubber along History list's trailing edge: short
/// tick marks, one per `HistoryPager.scrubberTicks` (already bucketed by
/// `HistoryScrubberModel.ticks(for:)` so this view never lays out more than a few thousand ticks
/// even at 20k loaded rows). The in-view tick is longer and lime; hovering expands a tick and
/// shows a bubble with its time and first words; click or drag scrolls the list. Day boundaries
/// get a small label. Purely presentational — all bucketing/active-tick math lives in
/// `MurmurCore.HistoryScrubberModel`, kept unit-tested there.
struct HistoryScrubber: View {
    let pager: HistoryPager
    /// The id of the topmost visible row, used to compute which tick is "active".
    let visibleID: Int64?
    /// Called with (row id, day) to scroll to when a tick is clicked or dragged over. `day` lets
    /// the caller `scrollTo` the day section first (its own `.id`), since individual rows aren't
    /// always given their own scroll anchor.
    let onSelect: (Int64, Date?) -> Void
    /// The hovered tick and its y position in this view, drawn by the parent as a bubble in an
    /// overlay above the list. (Drawn here, it would sit behind the AppKit-backed List.)
    @Binding var hover: ScrubberHover?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTickID: Int64?
    @State private var isDragging = false

    static let trackWidth: CGFloat = 24
    /// Fixed spacing like Claude's chat outline: a compact column centered vertically, rather
    /// than a few ticks stretched across the whole height.
    private static let tickSpacing: CGFloat = 7
    private static let tickWidth: CGFloat = 10
    private static let activeTickWidth: CGFloat = 16
    private static let hoverTickWidth: CGFloat = 22

    var body: some View {
        let ticks = pager.scrubberTicks
        if !ticks.isEmpty {
            GeometryReader { geometry in
                ticksColumn(ticks: ticks, height: geometry.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                .gesture(dragGesture(ticks: ticks, height: geometry.size.height))
                .onAppear { lastHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in lastHeight = height }
            }
            .frame(width: Self.trackWidth)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("History timeline")
            .accessibilityHint("Drag to scroll to a time")
        }
    }

    // MARK: Layout

    /// Ticks are laid out with equal spacing top-to-bottom (newest at top, matching the list's
    /// own newest-first order) rather than proportional to elapsed time — proportional spacing
    /// would squash an entire quiet week into a sliver next to one busy hour, which defeats the
    /// point of a scrubber a user can actually aim at.
    private func ticksColumn(ticks: [HistoryTick], height: CGFloat) -> some View {
        let activeID = HistoryScrubberModel.activeTickID(ticks: ticks, visibleID: visibleID, allItemsByID: pager.rowDatesByID)
        let spacing = columnSpacing(count: ticks.count, height: height)
        return VStack(spacing: 0) {
            ForEach(ticks) { tick in
                tickRow(tick: tick, isActive: tick.id == activeID)
                    .frame(height: spacing)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func columnSpacing(count: Int, height: CGFloat) -> CGFloat {
        guard count > 0 else { return Self.tickSpacing }
        return min(Self.tickSpacing, max(2, (height - 40) / CGFloat(count)))
    }

    /// Top of the tick column, so hover/drag positions map to ticks.
    private func columnTop(count: Int, height: CGFloat) -> CGFloat {
        (height - columnSpacing(count: count, height: height) * CGFloat(count)) / 2
    }

    private func tickRow(tick: HistoryTick, isActive: Bool) -> some View {
        let isHovered = hoveredTickID == tick.id
        let width: CGFloat = isHovered ? Self.hoverTickWidth : (isActive ? Self.activeTickWidth : Self.tickWidth)
        return HStack(spacing: 4) {
            if tick.isDayBoundary, let dayLabel = tick.dayLabel, isHovered {
                Text(dayLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Capsule()
                .fill(isActive || isHovered ? Theme.phosphor : Theme.textTertiary.opacity(0.45))
                .frame(width: width, height: tick.isDayBoundary ? 3 : 1.5)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : Theme.fade) { hoveredTickID = hovering ? tick.id : (hoveredTickID == tick.id ? nil : hoveredTickID) }
            publishHover()
        }
        .onTapGesture { onSelect(tick.anchorID, dayAnchor(for: tick)) }
        .animation(reduceMotion ? nil : Theme.fade, value: width)
    }

    @State private var lastHeight: CGFloat = 0

    private func publishHover() {
        let ticks = pager.scrubberTicks
        guard let hoveredTickID, let index = ticks.firstIndex(where: { $0.id == hoveredTickID }) else {
            hover = nil
            return
        }
        let spacing = columnSpacing(count: ticks.count, height: lastHeight)
        let y = columnTop(count: ticks.count, height: lastHeight) + spacing * (CGFloat(index) + 0.5)
        hover = ScrubberHover(timeLabel: ticks[index].timeLabel, subtitle: bubbleSubtitle(for: ticks[index]), y: y)
    }

    static func bubbleSubtitle(_ tick: HistoryTick) -> String {
        switch tick.kind {
        case .item: tick.firstLine
        case .run, .bucket: "\(tick.itemCount) \(tick.itemCount == 1 ? "dictation" : "dictations") · \(tick.firstLine)"
        }
    }

    private func bubbleSubtitle(for tick: HistoryTick) -> String {
        switch tick.kind {
        case .item: tick.firstLine
        case .run, .bucket: "\(tick.itemCount) \(tick.itemCount == 1 ? "dictation" : "dictations") · \(tick.firstLine)"
        }
    }

    private func dayAnchor(for tick: HistoryTick) -> Date? {
        pager.sections.first { Calendar.current.isDate($0.day, inSameDayAs: tick.createdAt) }?.day
    }

    // MARK: Interaction

    /// A single drag gesture handles both click (a drag that never moves is effectively a tap)
    /// and drag-to-scrub, since `List` scroll and this gesture would otherwise compete for the
    /// same vertical swipes if they were two separate recognizers.
    private func dragGesture(ticks: [HistoryTick], height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                guard let tick = tick(at: value.location.y, ticks: ticks, height: height) else { return }
                hoveredTickID = tick.id
                publishHover()
                onSelect(tick.anchorID, dayAnchor(for: tick))
            }
            .onEnded { _ in
                isDragging = false
                hoveredTickID = nil
                publishHover()
            }
    }

    private func tick(at y: CGFloat, ticks: [HistoryTick], height: CGFloat) -> HistoryTick? {
        guard !ticks.isEmpty, height > 0 else { return nil }
        let spacing = columnSpacing(count: ticks.count, height: height)
        let index = Int(((y - columnTop(count: ticks.count, height: height)) / spacing).rounded(.down))
        return ticks[min(max(index, 0), ticks.count - 1)]
    }
}

/// What the History list shows in its hover bubble for the scrubber.
struct ScrubberHover: Equatable {
    let timeLabel: String
    let subtitle: String
    let y: CGFloat
}

/// The hover bubble, drawn by `HistoryListContent` in an overlay above the list.
struct ScrubberBubble: View {
    let hover: ScrubberHover

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(hover.timeLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(hover.subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: 260, alignment: .trailing)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgRaised)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .fixedSize()
        .allowsHitTesting(false)
    }
}
