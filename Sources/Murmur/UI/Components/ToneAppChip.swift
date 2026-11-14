import MurmurCore
import SwiftUI

/// One chip on the tone page: an app, a website (globe) or a kind of app (dashed: what unplaced apps and websites of
/// that kind get). Drag it to another lane; click it (or press Space on it) for "Move to …"; right-click for the same
/// moves as a menu; VoiceOver lists them as actions. All four end in the same `move`. A website can also be removed.
///
/// States a designer restyles here (`ChipFace.State`): rest, hovered, lifted (dragged), ghost (the space it leaves).
struct ToneAppChip: View {
    let app: ToneBoardApp
    let board: ToneBoard
    /// The ink of the lane it sits in: the edge it takes while lifted.
    var accent: Color = Theme.phosphor
    var isHovered = false
    /// Snapshot-only: drawn as it looks under the pointer while dragged over a tone.
    var isLifted = false
    /// Snapshot-only: the space it leaves behind while dragged.
    var isGhost = false
    let move: (ToneBoardApp, ToneLane) -> Void
    var remove: (ToneBoardApp) -> Void = { _ in }
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var hovering = false
    @State private var showsMenu = false

    private var destinations: [ToneLane] { board.destinations(for: app) }

    var body: some View {
        if isSnapshot {
            face
        } else {
            // Not a Button: on macOS a Button takes the mouse-down, so `.draggable` on it never starts a drag
            // (founder, 2026-10-28: "I am not able to drag"). A tap opens the menu; Space or Return does from the keyboard.
            face
                .contentShape(Capsule())
                .onTapGesture { showsMenu = true }
                .focusable()
                .onKeyPress(keys: [.space, .return]) { _ in showsMenu = true; return .handled }
                .accessibilityAddTraits(.isButton)
                .onHover { hovering = $0 }
                .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
                    ToneMoveMenu(app: app, destinations: destinations, pick: { lane in
                        showsMenu = false
                        move(app, lane)
                    }, remove: app.isSite ? { showsMenu = false; remove(app) } : nil)
                }
                .contextMenu {
                    Section(ToneCopy.moveTitle(app.name)) {
                        ForEach(destinations) { lane in
                            Button(lane == app.naturalLane ? ToneCopy.backTo(lane) : ToneCopy.moveTo(lane)) { move(app, lane) }
                        }
                    }
                    if app.isSite { Button(ToneCopy.removeWebsite, role: .destructive) { remove(app) } }
                }
                .draggable(ToneLane.dragPrefix + app.id) { ChipFace(app: app, state: .lifted, accent: accent) }
                .accessibilityLabel(accessibilityName)
                .accessibilityHint(ToneCopy.chipHint)
                .accessibilityActions {
                    ForEach(destinations) { lane in
                        Button(ToneCopy.moveTo(lane)) { move(app, lane) }
                    }
                    if app.isSite { Button(ToneCopy.removeWebsite) { remove(app) } }
                }
                .help(app.kindPlace.map(ToneCopy.kindChipHelp) ?? "")
        }
    }

    private var accessibilityName: String {
        if let place = app.kindPlace { return ToneCopy.kindChipLabel(place, in: app.lane) }
        return app.isSite ? ToneCopy.websiteChipLabel(app.name, in: app.lane) : ToneCopy.chipLabel(app.name, in: app.lane)
    }

    private var face: some View {
        let state: ChipFace.State = isGhost ? .ghost : isLifted ? .lifted : (isHovered || hovering || showsMenu) ? .hovered : .rest
        return ChipFace(app: app, state: state, accent: accent)
    }
}

/// How a chip looks. Kept apart from the button so the drag preview is the same chip. At rest it sits on the well
/// with a hairline and a breath of shadow; under the pointer it rises a point; picked up it tilts, grows and takes
/// the ink of the lane it is over; the space it leaves is a dashed ghost.
struct ChipFace: View {
    enum State: Equatable { case rest, hovered, lifted, ghost }

    let app: ToneBoardApp
    let state: State
    var accent: Color = Theme.phosphor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(app.name).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(app.isKind ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
            if app.isPlaced {
                Image(systemName: "pin.fill").font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85)).rotationEffect(.degrees(35))
                    .help(ToneCopy.placedByYou)
                    .accessibilityLabel(ToneCopy.placedByYou)
            }
            // Always there, so "click to move" is visible before anyone hovers; brighter under the pointer.
            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(state == .hovered ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                .accessibilityHidden(true)
        }
        .padding(.leading, 5).padding(.trailing, 9).padding(.vertical, 4.5)
        .background { ground }
        .opacity(state == .ghost ? 0.3 : 1)
        .overlay {
            if state == .ghost {
                Capsule().strokeBorder(Theme.textTertiary.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .scaleEffect(reduceMotion ? 1 : scale)
        .rotationEffect(.degrees(state == .lifted && !reduceMotion ? -2.5 : 0))
        .offset(y: state == .hovered && !reduceMotion ? -1 : 0)
        .contentShape(Capsule())
        .animation(state == .lifted ? Theme.Motion.pickUp : Theme.Motion.lift, value: state)
    }

    private var scale: CGFloat {
        switch state {
        case .lifted: 1.07
        case .hovered: 1.02
        case .rest, .ghost: 1
        }
    }

    @ViewBuilder private var ground: some View {
        let capsule = Capsule()
        let fill: Color = app.isKind && state != .lifted ? .clear : Theme.bgRaised
        capsule.fill(fill)
            .overlay(capsule.strokeBorder(
                border, style: StrokeStyle(lineWidth: state == .lifted ? 1.25 : 0.75,
                                           dash: app.isKind && state != .lifted ? [3, 2] : [])))
            // Dark mode: a lit top edge instead of a shadow, so the chip reads as raised on the dark well.
            .overlay(alignment: .top) {
                if scheme == .dark && !app.isKind && state != .ghost {
                    capsule.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.09), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 0.75)
                }
            }
            .shadow(color: shadow, radius: shadowRadius, y: shadowY)
    }

    /// An app's own icon; a globe for a website; the kind's symbol for a kind of app.
    @ViewBuilder private var icon: some View {
        if app.isSite || app.isKind {
            Image(systemName: app.kindPlace?.symbol ?? "globe")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bgSunken))
                .accessibilityHidden(true)
        } else {
            ToneAppIcon(bundleIDs: app.row.bundleIDs, name: app.name, size: 18)
        }
    }

    private var border: Color {
        switch state {
        case .rest, .ghost: Theme.hairline
        case .hovered: Theme.textTertiary.opacity(0.55)
        case .lifted: accent.opacity(0.9)
        }
    }

    private var shadow: Color {
        switch state {
        case .ghost: .clear
        case .lifted: Color.black.opacity(scheme == .dark ? 0.55 : 0.2)
        case .hovered: Color.black.opacity(scheme == .dark ? 0.35 : 0.11)
        case .rest: Color.black.opacity(scheme == .dark || app.isKind ? 0 : 0.05)
        }
    }

    private var shadowRadius: CGFloat {
        switch state {
        case .lifted: 12
        case .hovered: 5
        case .rest, .ghost: 1.5
        }
    }

    private var shadowY: CGFloat {
        switch state {
        case .lifted: 7
        case .hovered: 2.5
        case .rest, .ghost: 1
        }
    }
}

/// The app's own icon, or its first letter when it has none to show.
struct ToneAppIcon: View {
    let bundleIDs: [String]
    let name: String
    let size: CGFloat

    var body: some View {
        if let id = bundleIDs.first(where: { AppIcon.icon(for: $0) != nil }) {
            AppIcon(bundleID: id).frame(width: size, height: size)
        } else {
            Text(String(name.prefix(1))).font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26).fill(Theme.bgSunken))
                .accessibilityHidden(true)
        }
    }
}

/// "Move Slack to": the other tones, each with its symbol. The tone the app would follow by its kind is marked, so
/// "back where it was" is one click.
struct ToneMoveMenu: View {
    let app: ToneBoardApp
    let destinations: [ToneLane]
    let pick: (ToneLane) -> Void
    /// Set for a website: "Remove from this page".
    var remove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if !app.isKind && !app.isSite { ToneAppIcon(bundleIDs: app.row.bundleIDs, name: app.name, size: 16) }
                Text(ToneCopy.moveTitle(app.name)).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
            ForEach(destinations) { lane in
                ToneMoveRow(lane: lane, isNatural: app.isPlaced && lane == app.naturalLane) { pick(lane) }
            }
            Divider().overlay(Theme.hairline).padding(.vertical, 4)
            if let remove {
                Button(ToneCopy.removeWebsite, action: remove).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.bottom, 4)
            }
            Text(app.kindPlace.map(ToneCopy.kindChipHelp) ?? (app.isPlaced ? ToneCopy.placedByYou : ToneCopy.followsItsKind))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.bottom, 2)
        }
        .padding(6)
        .frame(width: 236, alignment: .leading)
    }
}

private struct ToneMoveRow: View {
    let lane: ToneLane
    let isNatural: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: lane.symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(lane.ink).frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(lane.wash(scheme)))
                Text(isNatural ? ToneCopy.backTo(lane) : lane.title)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? lane.wash(scheme, strong: true) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isNatural ? ToneCopy.backTo(lane) : ToneCopy.moveTo(lane))
    }
}
