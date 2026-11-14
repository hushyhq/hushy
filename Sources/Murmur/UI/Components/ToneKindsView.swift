import AppKit
import MurmurCore
import SwiftUI

/// Onboarding: the person's apps, met as kinds, one short row each with the kind's tone. Settings organises the same
/// apps by tone instead (`ToneBoardView`, TRY-93). AI tools are their own kind, and code editors and terminals are
/// shown honestly as taking no tone.
///
/// The apps are the ones installed on this Mac (`ToneKinds`), looked up off the main thread when the screen
/// appears, and ordered by how much the person dictates into each (a local count, never sent anywhere).
struct ToneKindsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.installedApps) private var installedApps
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotAppUsage) private var snapshotUsage
    @State private var usage: [String: Int] = [:]
    /// Bumped when a newer look at the installed apps arrives, so the list is rebuilt.
    @State private var lookRevision = 0
    /// Whether kinds with a tone of their own stay with no apps; onboarding drops empty kinds.
    let includeEmpty: Bool
    var limit: Int?

    var body: some View {
        let _ = lookRevision
        let groups = ToneKinds.groups(
            settings: model.settings.toneSettings, installed: installedApps, usage: snapshotUsage ?? usage,
            includeEmpty: includeEmpty, limit: limit)
        VStack(alignment: .leading, spacing: 6) {
            // The heading and the one line show only when there is something to show, which is known once the
            // look at the installed apps has finished.
            if !groups.isEmpty { Eyebrow(ToneCopy.appsTitle).padding(.top, 4) }
            ForEach(groups) { group in
                CompactKindRow(group: group, setKind: { set($0, group.kind) })
            }
            if !groups.isEmpty {
                Text(ToneCopy.onboardingAppsDetail).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
            }
        }
        .task { await look() }
    }

    private func set(_ value: AppToneOption.Value, _ kind: ToneKind) {
        withAnimation(Theme.snappy) {
            model.settings.toneSettings = ToneKinds.applying(value, to: kind, in: model.settings.toneSettings)
        }
    }

    /// Reads the installed apps and the local usage counts away from the main thread, then redraws.
    private func look() async {
        guard !isSnapshot else { return }
        let store = model.store
        usage = await Task.detached(priority: .utility) { (try? store.appWordCounts()) ?? [:] }.value
        await InstalledAppCatalog.shared.refresh()
        lookRevision += 1
    }
}

/// The one control for a kind: its tone menu, or what stands in its place for AI tools and code.
struct KindControl: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(AppModel.self) private var model
    let group: ToneKindGroup
    let setKind: (AppToneOption.Value) -> Void

    private var selectedTitle: String {
        if case .tone(let tone) = group.selected { return tone.title }
        return group.options.first?.title ?? ""
    }

    @ViewBuilder var body: some View {
        if group.kind.hasOwnTone {
            if isSnapshot {
                TonePill(title: selectedTitle)
            } else {
                Menu {
                    ForEach(group.options) { option in
                        Button { setKind(option.value) } label: {
                            if option.value == group.selected { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                        }
                    }
                } label: { TonePill(title: selectedTitle) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        } else if group.showsPromptComing {
            // On a model that takes register lines AI apps are written as prompts already; elsewhere it is coming.
            if model.cleanupModel.writesRegisterLines {
                Text(ToneCopy.promptName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 0.5))
            } else {
                PromptComingChip()
            }
        } else {
            Text(ToneCopy.noToneInCode).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Onboarding: a kind on one short row, its apps as small icons, its tone on the right.
private struct CompactKindRow: View {
    let group: ToneKindGroup
    let setKind: (AppToneOption.Value) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: group.kind.symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgSunken))
            Text(group.kind.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).layoutPriority(1)
            HStack(spacing: 4) {
                ForEach(group.apps) { row in CompactAppIcon(row: row) }
                if group.hiddenCount > 0 {
                    Text("+\(group.hiddenCount)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: Theme.Space.s)
            KindControl(group: group, setKind: setKind)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.kind.title): \(group.apps.map(\.name).joined(separator: ", "))")
    }
}

private struct CompactAppIcon: View {
    let row: AppToneRow

    var body: some View {
        if let id = row.bundleIDs.first(where: { AppIcon.icon(for: $0) != nil }) {
            AppIcon(bundleID: id).frame(width: 18, height: 18)
        } else {
            Text(String(row.name.prefix(1))).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 4.5).fill(Theme.bgSunken))
        }
    }
}

struct TonePill: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// "Prompt" is shown so people know it is planned; it cannot be picked, and nothing here says it works.
private struct PromptComingChip: View {
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Text(ToneCopy.promptName).font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
            Text(ToneCopy.comingBadge).font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1.5).background(Capsule().fill(Theme.bgRaised))
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, compact ? 0 : 8).padding(.vertical, compact ? 0 : 5)
        .overlay {
            if !compact { Capsule().strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])) }
        }
        .accessibilityLabel("\(ToneCopy.promptName), \(ToneCopy.comingBadge)")
    }
}

/// Lays chips out in rows and wraps to the next row when the width runs out.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
