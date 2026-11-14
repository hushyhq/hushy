import AppKit
import MurmurCore
import SwiftUI
import UniformTypeIdentifiers

/// Snapshot-only: the tone page in a state a still cannot reach by itself (TRY-93).
struct ToneBoardSnapshot: Equatable {
    /// Whether the writing model takes register lines (Prompt offered, rewrite examples).
    var registerLines = true
    /// An app shown mid-drag: a ghost where it was, and a lifted chip over `target`.
    var dragging: String?
    var target: ToneLane?
    /// A chip drawn in its hover state.
    var hovered: String?
    /// A lane drawn as it looks under the pointer.
    var hoveredLane: ToneLane?
}

extension EnvironmentValues {
    @Entry var snapshotToneBoard: ToneBoardSnapshot?
}

/// Voice & style → Style: the whole tone page (`ToneBoard`). One card per lane (Refined, Professional, Casual, Prompt,
/// As spoken), each holding the chips written that way: apps, websites, and one chip per kind of app ("Other email"),
/// which is what every app and website of that kind gets until it is placed. A chip moves by dragging it to another
/// lane, or from its menu (keyboard and VoiceOver too). A move is stored in the same `appChoices`, `siteChoices` or
/// per-kind tone the dictation reads, so what the page shows is what the next dictation there does.
///
/// States a designer restyles here: a lane at rest, with no chips ("Drop here"), under a drag (`isTargeted`), paused
/// while As spoken is on for every app (dimmed, takes no drops), and Prompt unavailable (`PromptComingCard`).
struct ToneBoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.installedApps) private var installedApps
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotAppUsage) private var snapshotUsage
    @Environment(\.snapshotToneBoard) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var usage: [String: Int] = [:]
    @State private var lookRevision = 0
    @State private var targeted: ToneLane?
    @State private var addNote: (lane: ToneLane, text: String)?
    @Namespace private var chipSpace

    private var registerLines: Bool { snapshot?.registerLines ?? model.cleanupModel.writesRegisterLines }

    var body: some View {
        let _ = lookRevision
        let settings = model.settings.toneSettings
        let board = ToneBoard.make(
            settings: settings, installed: installedApps, usage: snapshotUsage ?? usage, promptAvailable: registerLines)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(board.lanes) { lane in
                if lane.isAvailable {
                    let isPaused = settings.isAsSpoken && lane.lane != .asSpoken
                    ToneLaneCard(
                        lane: lane, board: board, registerLines: registerLines,
                        isTargeted: (snapshot?.target ?? targeted) == lane.lane,
                        note: addNote?.lane == lane.lane ? addNote?.text : nil,
                        sitesToOffer: ToneBoard.sitesToOffer(settings),
                        chipSpace: chipSpace,
                        actions: LaneActions(
                            move: move, remove: remove, addApp: { addApp(to: lane.lane) },
                            addSite: { addSite($0, to: lane.lane) }, addAddress: { addAddress($0, to: lane.lane) },
                            setTargeted: { isOn in
                                if isOn { targeted = lane.lane } else if targeted == lane.lane { targeted = nil }
                            }))
                        .saturation(isPaused ? 0 : 1)
                        .opacity(isPaused ? 0.5 : 1)
                        .disabled(isPaused)
                        .animation(Theme.Motion.fade, value: isPaused)
                } else {
                    PromptComingCard(settings: settings)
                }
            }
            if !board.noTone.isEmpty {
                // Code editors and terminals take no tone: one line, nothing to move.
                Label(ToneCopy.noToneFootnote(board.noTone.map(\.name)), systemImage: "chevron.left.forwardslash.chevron.right")
                    .labelStyle(FootnoteLabelStyle())
                    .help(ToneCopy.codeKindNote)
                    .padding(.top, 2)
            }
        }
        .task { await look() }
    }

    private func move(_ app: ToneBoardApp, _ lane: ToneLane) {
        withAnimation(Theme.spatial(reduceMotion: reduceMotion)) {
            model.settings.toneSettings = ToneBoard.moving(
                app, to: lane, in: model.settings.toneSettings, promptAvailable: registerLines)
        }
        announce("\(app.name) moved to \(lane.title)")
    }

    private func remove(_ app: ToneBoardApp) {
        withAnimation(Theme.spatial(reduceMotion: reduceMotion)) {
            model.settings.toneSettings = ToneBoard.removingSite(app, from: model.settings.toneSettings)
        }
        announce("\(app.name) removed")
    }

    /// VoiceOver hears where it went: the chip it was focused on has just left this lane.
    private func announce(_ text: String) {
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func addSite(_ key: String, to lane: ToneLane) {
        addNote = nil
        withAnimation(Theme.spatial(reduceMotion: reduceMotion)) {
            model.settings.toneSettings = ToneBoard.addingSite(
                key, to: lane, in: model.settings.toneSettings, promptAvailable: registerLines)
        }
    }

    /// Only the site's key or its host is kept, in the tone setting. Returns false for text that is no web address.
    private func addAddress(_ address: String, to lane: ToneLane) -> Bool {
        guard let added = ToneBoard.addingSite(
            address: address, to: lane, in: model.settings.toneSettings, promptAvailable: registerLines) else { return false }
        addNote = nil
        withAnimation(Theme.spatial(reduceMotion: reduceMotion)) { model.settings.toneSettings = added }
        return true
    }

    /// Lets the person pick any installed app for this lane. Only its bundle identifier is kept, in the tone setting.
    private func addApp(to lane: ToneLane) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add to \(lane.title)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The Info.plist is read off the main actor (a bounded read, see `InstalledAppScanner`).
        Task {
            guard let info = await Task.detached(priority: .userInitiated, operation: { InstalledAppScanner.read(url) }).value else {
                addNote = (lane, ToneCopy.couldNotReadApp)
                return
            }
            guard let added = ToneBoard.adding(
                info, to: lane, in: model.settings.toneSettings, promptAvailable: registerLines) else {
                addNote = (lane, AppCategory.isBrowser(info.bundleID) ? ToneCopy.browsersNeedKind : ToneCopy.codeAppsLeftAlone)
                return
            }
            addNote = nil
            withAnimation(Theme.spatial(reduceMotion: reduceMotion)) { model.settings.toneSettings = added }
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

/// What a lane card can ask the board to do.
struct LaneActions {
    let move: (ToneBoardApp, ToneLane) -> Void
    let remove: (ToneBoardApp) -> Void
    let addApp: () -> Void
    let addSite: (String) -> Void
    let addAddress: (String) -> Bool
    let setTargeted: (Bool) -> Void
}

extension ToneLane {
    var symbol: String {
        switch self {
        case .refined: "pencil.line"
        case .professional: "briefcase"
        case .casual: "bubble.left"
        case .prompt: "list.bullet.indent"
        case .asSpoken: "waveform"
        }
    }

    /// What a chip carries while it is dragged. The prefix keeps text dragged in from another app from moving
    /// anything.
    static let dragPrefix = "hushy-tone-app:"
}

/// One lane: its name, a one-line specimen of what it writes (the full example opens from it), the chips written
/// that way, and for As spoken the switch that turns it on for every app. What the lane does in words is hover help.
private struct ToneLaneCard: View {
    let lane: ToneBoardLane
    let board: ToneBoard
    let registerLines: Bool
    let isTargeted: Bool
    let note: String?
    let sitesToOffer: [KnownWebsite]
    let chipSpace: Namespace.ID
    let actions: LaneActions
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.snapshotToneBoard) private var snapshot
    @State private var hovering = false

    private var ink: Color { lane.lane.ink }
    private var isHot: Bool { hovering || snapshot?.hoveredLane == lane.lane }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            well.padding(.leading, 33)
            if let note { Label(note, systemImage: "info.circle").labelStyle(FootnoteLabelStyle()) }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ground }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: isHot)
        .animation(Theme.Motion.lift, value: isTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.lane.title), \(lane.apps.count) items")
    }

    private var ground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let edge = isTargeted ? ink.opacity(0.65) : isHot ? ink.opacity(0.35) : Theme.hairline
        return shape.fill(Theme.bgRaised)
            .overlay(shape.strokeBorder(edge, lineWidth: isTargeted ? 1 : 0.5))
            .shadow(color: shadowColor, radius: isTargeted ? 18 : isHot ? 14 : 10, y: isTargeted ? 6 : isHot ? 4 : 2)
    }

    private var shadowColor: Color {
        if scheme == .dark { return .black.opacity(isTargeted ? 0.45 : isHot ? 0.3 : 0) }
        return Theme.cardShadow.opacity(isTargeted ? 0.26 : isHot ? 0.2 : Theme.cardShadowOpacity)
    }

    private var isEveryApp: Bool { lane.lane == .asSpoken && model.settings.toneSettings.isAsSpoken }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            LaneGlyph(lane: lane.lane, isActive: isHot || isTargeted)
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.lane.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if isEveryApp {
                    Text(ToneCopy.asSpokenOnNote).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else if let example = ToneLaneExample.forLane(lane.lane, registerLines: registerLines) {
                    SpecimenButton(example: example, lane: lane.lane)
                } else {
                    Text(ToneCopy.laneDetail(lane.lane, registerLines: registerLines))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .help(ToneCopy.laneDetail(lane.lane, registerLines: registerLines))
            Spacer(minLength: Theme.Space.s)
            if lane.lane == .asSpoken { EveryAppSwitch() }
            AddMenu(lane: lane.lane, sitesToOffer: sitesToOffer, actions: actions)
        }
    }

    private var apps: [ToneBoardApp] {
        guard let dragging = snapshot?.dragging, snapshot?.target == lane.lane, let app = board.app(id: dragging) else {
            return lane.apps
        }
        return lane.apps + [app]
    }

    private var well: some View {
        let shown = apps
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack(alignment: .topLeading) {
            if shown.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.to.line.compact")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isTargeted ? "Drop to move it to \(lane.lane.title)" : ToneCopy.dropHere)
                }
                .font(Theme.Font.caption).foregroundStyle(isTargeted ? ink : Theme.textTertiary)
                .frame(maxWidth: .infinity)
            }
            WrapLayout(spacing: 6) {
                ForEach(shown) { app in
                    let isLifted = snapshot?.dragging == app.id && snapshot?.target == lane.lane
                    let isGhost = snapshot?.dragging == app.id && !isLifted
                    ToneAppChip(app: app, board: board, accent: ink, isHovered: snapshot?.hovered == app.id,
                                isLifted: isLifted, isGhost: isGhost, move: actions.move, remove: actions.remove)
                        .matchedGeometryEffect(id: isLifted ? "lifted-\(app.id)" : app.id, in: chipSpace)
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if isTargeted { shape.fill(lane.lane.wash(scheme, strong: true)) }
        }
        .overlay {
            if isTargeted || shown.isEmpty {
                shape.strokeBorder(isTargeted ? ink : Theme.hairline,
                                   style: StrokeStyle(lineWidth: isTargeted ? 1.25 : 0.75, dash: [5, 3]))
            }
        }
        .shadow(color: scheme == .dark && isTargeted ? ink.opacity(0.3) : .clear, radius: 10)
        .contentShape(shape)
        .modifier(LaneDrop(board: board, lane: lane.lane, move: actions.move, setTargeted: actions.setTargeted))
        .animation(Theme.Motion.hover, value: isTargeted)
    }
}

/// The lane's mark: its symbol in its ink on a wash of it. Brightens while the lane is under the pointer or a drag.
private struct LaneGlyph: View {
    let lane: ToneLane
    let isActive: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: lane.symbol)
            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(lane.ink)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lane.wash(scheme, strong: isActive)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(lane.ink.opacity(isActive ? 0.3 : 0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A short caption with a small leading glyph: footnotes and notes on the board.
struct FootnoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 9.5, weight: .semibold))
            configuration.title.lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
    }
}

/// As spoken for every app at once (`ToneSettings.isAsSpoken`): on the As spoken lane, since that is what it does.
private struct EveryAppSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isOn = Binding(
            get: { model.settings.toneSettings.isAsSpoken },
            set: { value in withAnimation(Theme.snappy) { model.settings.toneSettings.isAsSpoken = value } })
        HStack(spacing: 6) {
            Text(ToneCopy.asSpokenEveryAppTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            SwitchToggle(isOn: isOn)
        }
        .help(ToneCopy.asSpokenEveryAppDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ToneCopy.asSpokenTitle) in every app")
        .accessibilityHint(ToneCopy.asSpokenEveryAppDetail)
    }
}

/// "Add": an app from the disk, a known website, or any other website by its address. A round + in the lane's ink.
private struct AddMenu: View {
    let lane: ToneLane
    let sitesToOffer: [KnownWebsite]
    let actions: LaneActions
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var entersAddress = false
    @State private var hovering = false

    var body: some View {
        if isSnapshot {
            AddFace(lane: lane, isHot: false)
        } else {
            Menu {
                Button(ToneCopy.addAppItem, action: actions.addApp)
                Section(ToneCopy.addWebsiteSection) {
                    ForEach(sitesToOffer) { site in Button(site.name) { actions.addSite(site.key) } }
                    Button(ToneCopy.otherWebsite) { entersAddress = true }
                }
            } label: { AddFace(lane: lane, isHot: hovering) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .onHover { hovering = $0 }
            .help("Add an app or a website to \(lane.title)")
            .accessibilityLabel("\(ToneCopy.add) to \(lane.title)")
            .popover(isPresented: $entersAddress, arrowEdge: .bottom) {
                WebsiteEntry(lane: lane) { address in
                    let added = actions.addAddress(address)
                    if added { entersAddress = false }
                    return added
                }
            }
        }
    }
}

private struct AddFace: View {
    let lane: ToneLane
    let isHot: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isHot ? lane.ink : Theme.textSecondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(isHot ? lane.wash(scheme, strong: true) : Theme.bgSunken))
            .overlay(Circle().strokeBorder(isHot ? lane.ink.opacity(0.35) : Theme.hairline, lineWidth: 0.5))
            .contentShape(Circle())
            .animation(Theme.Motion.hover, value: isHot)
    }
}

/// A website by its address. Only its host is kept; the page is never read.
private struct WebsiteEntry: View {
    let lane: ToneLane
    let add: (String) -> Bool
    @State private var address = ""
    @State private var refused = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField(ToneCopy.websiteFieldPrompt, text: $address, prompt: Text(ToneCopy.websiteFieldPlaceholder))
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .accessibilityLabel(ToneCopy.websiteFieldPrompt)
            Text(refused ? ToneCopy.websiteNotAddress : ToneCopy.websiteKeptNote)
                .font(.system(size: 11)).foregroundStyle(refused ? Theme.textSecondary : Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(ToneCopy.addWebsiteTo(lane), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 280)
    }

    private func submit() { refused = !add(address) }
}

/// The lane's specimen: as many whole sentences of what Hushy wrote in its recorded example as fit on one line, in the
/// reading face, so the sample never stops mid-word. A click opens the whole example, what was said and what was written.
private struct SpecimenButton: View {
    let example: ToneLaneExample
    let lane: ToneLane
    @State private var shows = false
    @State private var hovering = false

    private var line: String {
        example.written.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Longest first: the whole line, then each shorter run of its opening sentences.
    private var wholeSentences: [String] {
        var sentences: [String] = []
        line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
        }
        return (1...max(sentences.count, 1)).reversed().map { sentences.prefix($0).joined(separator: " ") }
    }

    var body: some View {
        Button { shows.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "quote.opening").font(.system(size: 8.5, weight: .bold)).foregroundStyle(lane.ink.opacity(0.8))
                ViewThatFits(in: .horizontal) {
                    ForEach(wholeSentences, id: \.self) { Text($0).fixedSize() }
                    Text(line).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(hovering || shows ? Theme.textPrimary : Theme.textSecondary)
                Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary).opacity(hovering || shows ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .help(VoiceStyleCopy.specimenHelp)
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            LaneExample(example: example, ink: lane.ink).padding(Theme.Space.l).frame(width: 340)
        }
        .accessibilityLabel("\(ToneCopy.seeExample): \(example.written)")
    }
}

/// Takes a dropped chip. Left out of snapshots: `ImageRenderer` draws the AppKit drop view as a placeholder glyph.
private struct LaneDrop: ViewModifier {
    let board: ToneBoard
    let lane: ToneLane
    let move: (ToneBoardApp, ToneLane) -> Void
    let setTargeted: (Bool) -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot { content } else {
            content.dropDestination(for: String.self) { items, _ in
            guard let id = items.first(where: { $0.hasPrefix(ToneLane.dragPrefix) })?.dropFirst(ToneLane.dragPrefix.count),
                  let app = board.app(id: String(id)) else { return false }
                guard app.lane == lane || board.destinations(for: app).contains(lane) else { return false }
                if app.lane != lane { move(app, lane) }
                return true
            } isTargeted: { setTargeted($0) }
        }
    }
}

/// One real example: what was said, then what Hushy typed for it in the app it was recorded in.
struct LaneExample: View {
    let example: ToneLaneExample
    var ink: Color = Theme.phosphor

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 5) {
                ExampleLabel(text: ToneCopy.youSay)
                Text("“\(example.spoken)”")
                    .font(.system(size: 12.5, design: .serif)).italic()
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                ExampleLabel(text: ToneCopy.hushyWrites(in: example.app))
                Text(example.written)
                    .font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 9).padding(.leading, 12).padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bgSunken))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: 2).padding(.vertical, 8)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example. You say: \(example.spoken). Hushy writes in \(example.app): \(example.written)")
    }
}

/// The small label over each half of an example: quieter than a section eyebrow.
struct ExampleLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).font(.system(size: 9.5, weight: .semibold).width(.expanded)).tracking(0.7)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Prompt on a Mac whose writing model does not take register lines: shown so people know it is coming, holding no
/// apps and taking no drops, and saying what AI apps get meanwhile.
private struct PromptComingCard: View {
    let settings: ToneSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ToneLane.prompt.symbol)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(ToneCopy.promptName).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(ToneCopy.comingBadge.uppercased())
                        .font(.system(size: 9, weight: .bold).width(.expanded)).tracking(0.6)
                        .foregroundStyle(ToneLane.prompt.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(ToneLane.prompt.ink.opacity(0.1)))
                }
                Text(ToneCopy.promptComing(settings)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}
