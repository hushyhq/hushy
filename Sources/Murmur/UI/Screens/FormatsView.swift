import MurmurCore
import SwiftUI

/// Formats tab of Voice & style: one-off shapes (Email, Message, Note, Bullet points and the person's own) picked
/// from the pill for a single dictation. Stored as `Mode`s; tones on the Style board decide how each app reads, so a
/// format here never presents itself as picking itself per app. A stored app assignment from before keeps working
/// and is shown only inside the editor, where it can be stopped.
struct FormatsTabContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotFormatHovered) private var snapshotHovered
    @State private var editing: Mode?
    @State private var creatingNew = false

    var body: some View {
        let modes = model.settings.modes
        ColumnsLayout(minColumnWidth: 168, spacing: Theme.Space.m) {
            ForEach(modes) { mode in
                FormatCard(
                    mode: mode, isHovered: snapshotHovered == mode.id,
                    onEdit: { editing = mode },
                    onDuplicate: { editing = model.settings.duplicateMode(mode) },
                    onDelete: mode.isBuiltIn ? nil : { model.settings.deleteMode(id: mode.id) })
            }
            NewFormatCard { creatingNew = true }
        }
        .sheet(item: $editing) { mode in
            FormatEditorSheet(mode: mode, onSave: { model.settings.upsertMode($0) })
        }
        .sheet(isPresented: $creatingNew) {
            FormatEditorSheet(
                mode: Mode(name: VoiceStyleCopy.newFormat, icon: "sparkles", cleanupLevel: .clean, prompt: nil,
                           appBundleIDs: [], isBuiltIn: false),
                onSave: { model.settings.upsertMode($0) })
        }
    }
}

extension EnvironmentValues {
    /// Snapshot-only: a format card drawn as it looks under the pointer.
    @Entry var snapshotFormatHovered: UUID?
}

/// One format: a miniature of the shape it gives the text, its name, and its instruction in one line. A click opens
/// the editor; duplicate and delete come up under the pointer and in the context menu.
private struct FormatCard: View {
    let mode: Mode
    var isHovered = false
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: (() -> Void)?
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHot: Bool { hovering || isHovered }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 0) {
                FormatSpecimen(shape: FormatShape(mode), isHot: isHot)
                    .padding(6)
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHot ? Theme.phosphor : Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(isHot ? Theme.phosphorTint : Theme.bgSunken))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mode.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m).padding(.top, 4).padding(.bottom, Theme.Space.m)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { ground }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .help(mode.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? VoiceStyleCopy.plainFormatLine)
        .accessibilityLabel("\(mode.name) format. \(line)")
        .accessibilityHint("Opens the editor")
        .accessibilityActions {
            Button("Duplicate", action: onDuplicate)
            if let onDelete { Button("Delete", action: onDelete) }
        }
        // Beside the card's own button, not inside its label, so each tool takes its own click.
        .overlay(alignment: .topTrailing) { tools.accessibilityHidden(true) }
        .offset(y: isHot && !reduceMotion ? -2 : 0)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.lift, value: isHot)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Duplicate", action: onDuplicate)
            if let onDelete { Button("Delete", role: .destructive, action: onDelete) }
        }
    }

    /// A built-in shows its shape in words; the person's own format, the start of its instruction.
    private var line: String {
        let shape = FormatShape(mode)
        if mode.isBuiltIn, let line = VoiceStyleCopy.formatLine(shape) { return line }
        guard mode.isTransform, let prompt = mode.prompt else { return VoiceStyleCopy.plainFormatLine }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape.fill(Theme.bgRaised)
            .overlay(shape.strokeBorder(isHot ? Theme.phosphor.opacity(0.4) : Theme.hairline, lineWidth: 0.5))
            .shadow(color: shadow, radius: isHot ? 14 : 8, y: isHot ? 6 : 2)
    }

    private var shadow: Color {
        scheme == .dark ? .black.opacity(isHot ? 0.4 : 0) : Theme.cardShadow.opacity(isHot ? 0.24 : Theme.cardShadowOpacity)
    }

    /// Duplicate and delete, floating over the miniature while the pointer is on the card.
    private var tools: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "plus.square.on.square", help: "Duplicate", action: onDuplicate)
            if let onDelete { IconButton(symbol: "trash", help: "Delete", tint: Theme.textTertiary, action: onDelete) }
        }
        .padding(2)
        .background(Capsule().fill(Theme.bgRaised).shadow(color: .black.opacity(0.12), radius: 4, y: 1))
        .padding(10)
        .opacity(isHot ? 1 : 0)
        .allowsHitTesting(isHot)
    }
}

/// The last tile: a dashed card that starts a new format.
private struct NewFormatCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hovering ? Theme.phosphor : Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(hovering ? Theme.phosphorTint : Theme.bgSunken))
                Text(VoiceStyleCopy.newFormat).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 148)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? Theme.phosphor.opacity(0.5) : Theme.hairline,
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityLabel(VoiceStyleCopy.newFormat)
    }
}

/// Lays its children out in as many equal columns as fit at `minColumnWidth`, row by row. A grid that `ImageRenderer`
/// draws (lazy grids come out empty in snapshots).
struct ColumnsLayout: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat

    private func columns(for width: CGFloat) -> Int { max(1, Int((width + spacing) / (minColumnWidth + spacing))) }

    private func columnWidth(_ width: CGFloat, _ count: Int) -> CGFloat {
        (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    private func rowHeights(_ width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let count = columns(for: width)
        let itemWidth = columnWidth(width, count)
        return stride(from: 0, to: subviews.count, by: count).map { start in
            subviews[start..<min(start + count, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth * 3
        let heights = rowHeights(width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = columns(for: bounds.width)
        let itemWidth = columnWidth(bounds.width, count)
        let heights = rowHeights(bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<count {
                let index = row * count + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (itemWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: itemWidth, height: height))
            }
            y += height + spacing
        }
    }
}
