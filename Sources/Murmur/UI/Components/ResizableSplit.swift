import SwiftUI

/// A two-pane resizable split, like `HSplitView` but pure SwiftUI. `HSplitView` is backed by
/// `NSSplitView`, which `ImageRenderer` cannot draw (same category as `TextField` and the
/// `.segmented` picker style — see `SnapshotTextField`/`SnapshotSegmentedLook`), so History's
/// snapshots would otherwise come out as a plain unrendered placeholder. This draws the
/// leading pane at a draggable width and gives the rest to the trailing pane.
///
/// The default width is `idealLeading` unless a `persistenceKey` is given, in which case a
/// width the user has already dragged (saved under that key) wins over the default from then
/// on — dragging is remembered per split, but the *default* for someone who has never dragged
/// is whatever the caller passes in. History passes a wider ideal so the list gets the space by
/// default, without touching anyone's already-persisted width.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing
    var minLeading: CGFloat = 360
    var idealLeading: CGFloat = 420
    var maxLeading: CGFloat = 560
    var persistenceKey: String?
    var minTrailing: CGFloat = 320
    var hasSelection = false
    var showSelectedDetail = false
    var onBack: (() -> Void)?
    var onShowDetail: (() -> Void)?

    @State private var leadingWidth: CGFloat?
    @State private var isDraggingHandle = false
    /// Captured once when a drag begins, since `DragGesture`'s `translation` is cumulative
    /// from gesture start, not incremental between callbacks.
    @State private var widthAtDragStart: CGFloat?

    init(
        minLeading: CGFloat = 360, idealLeading: CGFloat = 420, maxLeading: CGFloat = 560,
        persistenceKey: String? = nil, minTrailing: CGFloat = 320,
        hasSelection: Bool = false, showSelectedDetail: Bool = false,
        onBack: (() -> Void)? = nil, onShowDetail: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) {
        self.minLeading = minLeading
        self.idealLeading = idealLeading
        self.maxLeading = maxLeading
        self.persistenceKey = persistenceKey
        self.minTrailing = minTrailing
        self.hasSelection = hasSelection
        self.showSelectedDetail = showSelectedDetail
        self.onBack = onBack
        self.onShowDetail = onShowDetail
        self.leading = leading()
        self.trailing = trailing()
        if let persistenceKey {
            let saved = UserDefaults.standard.double(forKey: Self.defaultsKey(persistenceKey))
            if saved > 0 { _leadingWidth = State(initialValue: saved) }
        }
    }

    private static func defaultsKey(_ key: String) -> String { "resizableSplit.\(key).leadingWidth" }

    var body: some View {
        GeometryReader { geometry in
            let decision = DetailLayout.decide(
                available: geometry.size.width,
                preferredList: min(leadingWidth ?? idealLeading, maxLeading),
                minimumList: minLeading, minimumDetail: minTrailing,
                hasSelection: hasSelection, showSelectedDetail: showSelectedDetail)
            switch decision {
            case let .split(listWidth, _):
                HStack(spacing: 0) {
                    leading.frame(width: listWidth)
                    handle(maximumLeading: geometry.size.width - 8 - minTrailing)
                    trailing.frame(maxWidth: .infinity)
                }
            case .listOnly:
                if hasSelection {
                    CompactList(onShowDetail: { onShowDetail?() }) { leading }
                } else {
                    leading.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .detailOnly:
                CompactDetail(backTitle: "Back to list", onBack: { onBack?() }) {
                    trailing
                }
            }
        }
    }

    private func handle(maximumLeading: CGFloat) -> some View {
        Rectangle()
            .fill(isDraggingHandle ? Theme.phosphor.opacity(0.4) : Theme.hairline)
            .frame(width: isDraggingHandle ? 2 : 0.5)
            .frame(width: 8) // wider hit target than the visible line
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingHandle = true
                        if widthAtDragStart == nil { widthAtDragStart = leadingWidth ?? idealLeading }
                        let base = widthAtDragStart ?? idealLeading
                        leadingWidth = min(max(base + value.translation.width, minLeading), maxLeading, maximumLeading)
                    }
                    .onEnded { _ in
                        isDraggingHandle = false
                        widthAtDragStart = nil
                        if let persistenceKey, let leadingWidth {
                            UserDefaults.standard.set(Double(leadingWidth), forKey: Self.defaultsKey(persistenceKey))
                        }
                    }
            )
    }
}
