import MurmurCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(BetaGateController.self) private var gate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if !gate.isOpen {
                BetaGateView(gate: gate)
            } else if model.showOnboarding {
                OnboardingView()
            } else {
                MainView()
                    .overlay { PrivacyIntro() }
            }
        }
        .background(Theme.bgBase)
        .tint(Theme.phosphor)
        .onAppear {
            model.openWindowHandler = { openWindow(id: "main") }
            model.openSettingsHandler = { openSettings() }
            if gate.isOpen { WindowSizing.enlargeOnce() }
        }
    }
}

/// The main window: sidebar, the selected section, and — on every section, not only Home — the
/// Assistant as a right-hand pane (founder question 2026-09-28, P0 14: "full window or just
/// the right pane?"). Right pane, everywhere: the Assistant reads your notes, so it belongs
/// beside the note or the day you're looking at, the way Cursor's and VS Code's chat sit
/// beside the file; a full-window chat would duplicate claude.ai and lose that context.
/// Opening it from the sidebar row, ⌥⌘0, the menu bar or a voice answer never changes the
/// section any more. The pane needs room (`AssistantPane.hasRoom`): below that width it folds
/// to the "Assistant" button and reopens when the window is wide enough.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        @Bindable var handoff = model.handoff
        let collapsed = model.settings.sidebarCollapsed
        GeometryReader { geometry in
            let hasRoom = AssistantPane.hasRoom(windowWidth: geometry.size.width, sidebarCollapsed: collapsed)
            // The Assistant only reads notes and meetings, so it goes with them (`FeatureFlags.meetings`).
            let assistantVisible = FeatureFlags.meetings && !model.settings.assistantCollapsed && hasRoom
            HStack(spacing: 0) {
                Sidebar(collapsed: collapsed, assistantVisible: assistantVisible)
                    .frame(width: collapsed ? 68 : 248)
                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if FeatureFlags.meetings, !assistantVisible {
                            ShowAssistantButton { model.showAssistant(hasRoom: hasRoom) }
                                .padding(.top, Theme.Space.xs)
                                .padding(.trailing, Theme.Space.l)
                                .transition(.opacity)
                        }
                    }
                if assistantVisible {
                    AssistantColumn()
                        .frame(width: AssistantPane.width)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.hairline).frame(width: 0.5)
                        }
                        .transition(Theme.trailingPane(reduceMotion: reduceMotion))
                }
            }
            // Collapsing widens the section once, deliberately: one calm spring (a cross-fade
            // under Reduce Motion), whether it came from the header button, the section's
            // button, the sidebar row or ⌥⌘0.
            .animation(Theme.spatial(reduceMotion: reduceMotion), value: assistantVisible)
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(Theme.settle, value: collapsed)
        // An "open this dictation" request that History never served is dropped on leaving.
        .onChange(of: model.section) { _, section in
            HistoryOpenRequest.shared.sectionChanged(isHistory: section == .history)
        }
        .sheet(isPresented: $handoff.showingConfirmation, onDismiss: { model.handoff.confirmationClosed() }) {
            TaskHandoffConfirmationView()
        }
        .sheet(isPresented: $handoff.showingList, onDismiss: { model.handoff.listClosed() }) { TaskHandoffListView() }
        .background {
            // ⌃⌘S toggles the sidebar, like Finder and Mail.
            Button("") { model.settings.sidebarCollapsed.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .hidden()
            // ⌘2 jumps to History, next to Dictation's implicit "first" slot; no other
            // section currently has a shortcut, so this doesn't collide with anything.
            Button("") { model.section = .history }
                .keyboardShortcut("2", modifiers: .command)
                .hidden()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .home: HomeView()
        case .history: LockGate { HistoryView(library: model.library) }
        case .notes where FeatureFlags.meetings: LockGate { MeetingsView() }
        case .notes: HomeView()
        case .insights: LockGate { InsightsView() }
        case .style: VoiceAndStyleView()
        case .ai: AIConnectView()
        }
    }
}

/// The Assistant pane's one width and its room rule (`AssistantPaneTests`).
enum AssistantPane {
    /// Wide enough for the chat's bubbles and the action-item rows; narrow enough that a section
    /// keeps a comfortable measure beside it.
    static let width: CGFloat = 380
    /// The least a section may keep beside the pane: History's list (360) plus a readable
    /// detail column. Below this the pane folds away rather than squeezing the section.
    static let minimumSectionWidth: CGFloat = 560
    static let sidebarWidth: CGFloat = 248
    static let collapsedSidebarWidth: CGFloat = 68

    static func hasRoom(windowWidth: CGFloat, sidebarCollapsed: Bool) -> Bool {
        windowWidth - (sidebarCollapsed ? collapsedSidebarWidth : sidebarWidth) - width >= minimumSectionWidth
    }

    /// The window width that fits the pane beside a section at `minimumSectionWidth`.
    static func windowWidthWithRoom(sidebarCollapsed: Bool) -> CGFloat {
        (sidebarCollapsed ? collapsedSidebarWidth : sidebarWidth) + width + minimumSectionWidth
    }
}

/// Shown at the section's top-right while the Assistant pane is folded away.
private struct ShowAssistantButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.phosphor)
                Text("Assistant").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Image(systemName: "sidebar.right").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .background(Capsule().fill(hovering ? Theme.selection : Theme.bgRaised))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Show Assistant (⌥⌘0)")
        .accessibilityLabel("Show Assistant")
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    let collapsed: Bool
    /// Whether the Assistant pane is on screen right now (open *and* the window has room).
    let assistantVisible: Bool
    @State private var showSearch = false
    /// One selection plate that travels between rows (`matchedGeometryEffect`) instead of each
    /// row fading its own fill — the eye follows the move, and it reads as one object.
    @Namespace private var selectionPlate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Snapshot-only: the alternative lower-band layout (`SidebarLayout.hint`).
    @Environment(\.snapshotSidebarLayout) private var snapshotLayout

    private var layout: SidebarLayout { snapshotLayout ?? .quiet }

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 0) {
            // Sits beside the window's traffic lights.
            HStack {
                Spacer()
                IconButton(symbol: "sidebar.left", help: collapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)") {
                    model.settings.sidebarCollapsed.toggle()
                }
            }
            .frame(height: 28)
            .padding(.top, 10)
            .padding(.horizontal, Theme.Space.s)
            .opacity(collapsed ? 0 : 1)

            if collapsed {
                IconButton(symbol: "sidebar.left", help: "Show sidebar (⌃⌘S)") { model.settings.sidebarCollapsed = false }
                    .padding(.bottom, Theme.Space.l)
                IconButton(symbol: "magnifyingglass", help: "Search (⌘K)") { showSearch = true }
                    .padding(.bottom, Theme.Space.l)
            } else {
                Wordmark()
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, Theme.Space.xs)
                    .padding(.bottom, Theme.Space.l)
                SidebarSearchField { showSearch = true }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.l)
            }

            group(FeatureFlags.meetings ? [.home, .history, .notes] : [.home, .history])
            groupTitle("You")
            group([.style, .insights])

            // The lower band (`SidebarLayout`): what you do sits under where you go, and the
            // footer is the profile row. "Record a note" is a quiet outlined button, not the
            // lime fill it was: dictation is what Hushy is for and starts from a key, so no
            // button in the window outranks Home's dictation card. The Assistant row toggles
            // the pane. Readiness shows only while something blocks
            // dictation (`SidebarReadinessRow`) — no status rows that do nothing when clicked
            // (founder test 2026-09-28, P0 9).
            actions
                .padding(.top, Theme.Space.xl)
            Spacer()
            Divider().overlay(Theme.hairline)
            SidebarFooter(collapsed: collapsed)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSunken.opacity(0.5))
        .background {
            Button("") { showSearch = true }.keyboardShortcut("k", modifiers: .command).hidden()
        }
        .sheet(isPresented: $showSearch) { SearchPalette() }
    }

    /// Record a note, the readiness row (only while something blocks dictation), the `.hint`
    /// option's key-cap line, and the Assistant, as a block.
    private var actions: some View {
        VStack(spacing: 0) {
            if FeatureFlags.meetings {
                RecordNoteButton(collapsed: collapsed)
                    .padding(.bottom, Theme.Space.s)
            }
            SidebarReadinessRow(collapsed: collapsed)
            if layout == .hint {
                SidebarKeyHint(collapsed: collapsed)
            }
            if FeatureFlags.meetings {
                AssistantSidebarRow(collapsed: collapsed, isOpen: assistantVisible)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(.horizontal, collapsed ? Theme.Space.s : Theme.Space.m)
    }

    private func badge(for section: AppModel.Section) -> Int {
        switch section {
        // Only actionable counts get a badge (DECISIONS.md, "Sidebar badges: only actionable
        // counts"): a Notes total asks nothing of the user, so it's gone.
        case .history: model.historyBadgeCount
        default: 0
        }
    }

    private func group(_ sections: [AppModel.Section]) -> some View {
        VStack(spacing: 2) {
            ForEach(sections) { section in
                SidebarItem(section: section, isSelected: model.section == section, collapsed: collapsed,
                            badge: badge(for: section), plate: selectionPlate) {
                    model.section = section
                }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .animation(Theme.Motion.spatial(Theme.Motion.snappy, reduceMotion: reduceMotion), value: model.section)
    }

    @ViewBuilder
    private func groupTitle(_ title: String) -> some View {
        if collapsed {
            Rectangle().fill(Theme.hairline).frame(width: 24, height: 0.5).padding(.vertical, Theme.Space.m)
        } else {
            Eyebrow(title)
                .padding(.horizontal, Theme.Space.l + 4)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.s)
        }
    }
}

/// A quiet, non-editable field that opens the real search sheet — matches the mockup's
/// "Search ⌘K" affordance without duplicating focus/typing state that lives in the sheet.
private struct SidebarSearchField: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Text("Search").font(Theme.Font.body).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("⌘K").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(hovering ? Theme.selection : Theme.bgRaised))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

/// Bottom-most row: the profile (`SidebarProfileRow`: name and plan, opens Settings → Hushy
/// Pro), the appearance toggle, the feedback button and the Settings gear. Collapsed, the avatar
/// stacks above the feedback button and the gear. The old readiness dot/text ("● Ready") lived here; per product direction (2026-09-27)
/// it's gone — `SidebarReadinessRow` shows readiness, and only while something is blocked. The
/// gear opens the real macOS Settings window (⌘,), centred on this window; the speech bubble
/// opens the Send feedback sheet (`SendFeedbackSheet`), which emails the founder.
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    var collapsed: Bool
    @State private var showFeedback = false

    var body: some View {
        Group {
            if collapsed {
                VStack(spacing: Theme.Space.s) {
                    SidebarProfileRow(collapsed: true)
                    feedbackButton
                    IconButton(symbol: "gearshape", help: "Settings (⌘,)") { model.openSettingsWindow() }
                }
                .padding(.vertical, Theme.Space.m)
            } else {
                HStack(spacing: Theme.Space.xs) {
                    SidebarProfileRow(collapsed: false)
                    AppearanceToggle()
                    feedbackButton
                    IconButton(symbol: "gearshape", help: "Settings (⌘,)") { model.openSettingsWindow() }
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.s + 2)
            }
        }
        .sheet(isPresented: $showFeedback) { SendFeedbackSheet() }
    }

    private var feedbackButton: some View {
        IconButton(symbol: "ellipsis.bubble", help: SendFeedbackCopy.buttonHelp) { showFeedback = true }
    }
}

/// A compact, single-line nav row that *is* the Assistant pane's toggle — not a separate
/// destination duplicating the pane's own "Hide Assistant (⌥⌘0)" header button. It shows
/// selected (filled, like the other `SidebarItem` rows) exactly when the pane is on screen,
/// and clicking it flips that: closes the pane if it's open, opens it beside the current
/// section otherwise — it never changes the section (P0 14: the Assistant is a right pane on
/// every section). This is deliberately *not* about external MCP client connections (Claude
/// Desktop/Cursor/etc. — that status lives in Settings → AI connections and the full
/// `AIConnectView`, opened via `AppModel.Section.ai`); conflating the two was the whole problem
/// with the old "Ask your AI" card, which showed "Not connected" even while the Assistant chat
/// worked fine.
///
/// While off, the row still opens the pane — it shows the existing opt-in card/consent flow.
/// This never flips `assistantEnabled` directly; that only happens through `AssistantModel`'s
/// consent flow.
private struct AssistantSidebarRow: View {
    @Environment(AppModel.self) private var model
    var collapsed: Bool
    /// The pane is on screen right now (`MainView` decides: open, and the window has room).
    var isOpen: Bool
    @State private var hovering = false

    /// The green dot means the Assistant is on *and* signed in — i.e. a chat sent right now
    /// would actually go through, not just that the toggle is on. "Sign in" surfaces the one
    /// case where it's on but wouldn't work; "Off" covers the opt-in-not-given state.
    private var trailingState: (text: String, color: Color?, a11y: String) {
        let assistant = model.assistant
        guard assistant.isEnabled else { return ("Off", nil, "off") }
        if assistant.claudeState == .signedOut { return ("Sign in", nil, "signed out") }
        return ("", Theme.success, "connected")
    }

    var body: some View {
        Button {
            if isOpen {
                model.settings.assistantCollapsed = true
            } else {
                model.showAssistant(hasRoom: nil)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isOpen ? Theme.phosphor : Theme.textSecondary)
                if !collapsed {
                    Text("Assistant")
                        .font(.system(size: 15, weight: isOpen ? .semibold : .regular))
                        .foregroundStyle(isOpen ? Theme.textPrimary : Theme.textSecondary)
                    Spacer()
                    trailingLabel
                } else if let color = trailingState.color {
                    Circle().fill(color).frame(width: 5, height: 5)
                        .offset(x: 8, y: -8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(isOpen ? Theme.phosphorTint : (hovering ? Theme.selection.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide Assistant (⌥⌘0)" : "Show Assistant (\(trailingState.a11y))")
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
        .accessibilityLabel("Assistant, \(trailingState.a11y)")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    @ViewBuilder
    private var trailingLabel: some View {
        let state = trailingState
        if let color = state.color {
            Circle().fill(color).frame(width: 6, height: 6)
                .help("Assistant connected")
                .accessibilityLabel("Connected")
        } else {
            Text(state.text).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Cycles System → Light → Dark.
/// One click flips light ↔ dark from whatever is showing now (a three-way cycle had a
/// "Dark → System" step that changed nothing on a dark Mac). Right-click to match the system.
private struct AppearanceToggle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let isDark = scheme == .dark
        Button {
            withAnimation(Theme.fade) { model.settings.appearance = isDark ? .light : .dark }
        } label: {
            Image(systemName: isDark ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .contentTransition(.symbolEffect(.replace.downUp))
                .rotationEffect(.degrees(isDark ? 0 : 90))
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isDark)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Theme.selection : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isDark ? "Switch to light (right-click for more)" : "Switch to dark (right-click for more)")
        .contextMenu {
            ForEach(AppSettings.Appearance.allCases) { option in
                Button {
                    withAnimation(Theme.fade) { model.settings.appearance = option }
                } label: {
                    if option == model.settings.appearance {
                        Label(option == .system ? "Match system" : option.title, systemImage: "checkmark")
                    } else {
                        Text(option == .system ? "Match system" : option.title)
                    }
                }
            }
        }
        .accessibilityLabel(isDark ? "Switch to light appearance" : "Switch to dark appearance")
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoTile(size: 30)
            // The wordmark: lowercase, bold, tight, and a lime full stop — said, cleaned, done.
            (Text("hushy").foregroundStyle(Theme.textPrimary) + Text(".").foregroundStyle(Theme.phosphor))
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hushy")
    }
}

/// The app icon in miniature: a graphite tile with a hairline edge and top sheen in dark mode,
/// a soft sage/cream tile with a hairline edge in light mode — the same Wave-H (handbook
/// design/brand: two stems, a crossbar, two dots) either way, so the mark reads as native to
/// whichever sidebar it sits on rather than always being a dark square dropped onto a light
/// background. Slots follow scripts/make-icon.swift: bars 12 wide on a 20 pitch, heights
/// 12/84/38/84/12, the 92-unit span at 72% of the tile.
struct LogoTile: View {
    var size: CGFloat = 30
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Briefly raised when the appearance changes, so the mark "speaks" once.
    @State private var wave = false

    private static let heights: [CGFloat] = [12, 84, 38, 84, 12]
    private static let unit: CGFloat = 0.72 / 92

    var body: some View {
        let corner = size * 0.27
        let isDark = scheme == .dark
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isDark ? Color(hex: 0x16191E) : Color(hex: 0xEBEFDD))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(
                    colors: [isDark ? .white.opacity(0.07) : .white.opacity(0.5), .clear],
                    startPoint: .top, endPoint: .center))
            HStack(spacing: size * 8 * Self.unit) {
                ForEach(Self.heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Theme.phosphorFill)
                        .frame(width: size * 12 * Self.unit,
                               height: size * Self.unit * Self.heights[index] * waveScale(index))
                        .animation(.spring(response: 0.32, dampingFraction: 0.45).delay(Double(index) * 0.03), value: wave)
                }
            }
            .shadow(color: Theme.phosphor.opacity(isDark ? 0.45 : 0), radius: size * 0.05)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isDark ? .white.opacity(0.12) : .black.opacity(0.08), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(isDark ? 0.25 : 0.1), radius: 2, y: 1)
        .onChange(of: scheme) { _, _ in
            guard !reduceMotion else { return }
            wave = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { wave = false }
        }
    }

    private func waveScale(_ index: Int) -> CGFloat {
        guard wave else { return 1 }
        // The dots rise into bars and the crossbar grows: the menu-bar "listening" silhouette.
        switch Self.heights[index] {
        case 12: return 3
        case 38: return 1.5
        default: return 1
        }
    }
}

private struct SidebarItem: View {
    let section: AppModel.Section
    let isSelected: Bool
    var collapsed = false
    var badge = 0
    /// Spoken after the number, e.g. "History, 2 new to recover".
    var badgeMeaning = "new to recover"
    let plate: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.phosphor : Theme.textSecondary)
                if !collapsed {
                    Text(section.title)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    Spacer()
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.bgSunken))
                    }
                } else if badge > 0 {
                    Circle().fill(Theme.warning).frame(width: 5, height: 5)
                        .offset(x: 8, y: -8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(hovering && !isSelected ? Theme.selection.opacity(0.6) : .clear)
                    if isSelected {
                        // The travelling plate, with a short phosphor trace at its leading edge.
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.phosphorTint)
                            Capsule().fill(Theme.phosphor).frame(width: 2.5, height: 14).padding(.leading, 3)
                        }
                        .matchedGeometryEffect(id: "sidebar-selection", in: plate)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        // Selection moves on mouse-down, like Finder's sidebar: the click registers on the first
        // frame instead of waiting for release (DESIGN-LANGUAGE.md §3, "feedback within 1 frame").
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if !isSelected { action() }
        })
        .help(collapsed ? section.title : "")
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
        .accessibilityLabel(badge > 0 ? "\(section.title), \(badge) \(badgeMeaning)" : section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RecordNoteButton: View {
    @Environment(AppModel.self) private var model
    var collapsed = false
    @State private var hovering = false

    var body: some View {
        if model.recorder.isRecording, let startedAt = model.recorder.activeNote?.createdAt {
            RecordingStatusRow(
                collapsed: collapsed, startedAt: startedAt,
                isCapturingCallAudio: model.recorder.isCapturingSystemAudio,
                onStop: { model.toggleNoteRecording() })
        } else {
            Button { model.toggleNoteRecording() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    if !collapsed {
                        Text("Record a note")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("⇧⌘N").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(hovering ? Theme.selection : Theme.bgRaised))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Theme.fade, value: hovering)
            .help(collapsed ? "Record a note (⇧⌘N)" : "")
            .accessibilityLabel("Record a note")
        }
    }
}

/// A calm inline status row shown in place of the record button while a note is recording:
/// a pulsing dot, an elapsed timer, a small call-audio indicator, and a small stop button — not
/// a full-width red banner.
private struct RecordingStatusRow: View {
    var collapsed: Bool
    let startedAt: Date
    /// Whether *this* recording is capturing system audio — read-only here (task requirement:
    /// "a small switch shown next to the record button while recording"). It shows as an icon
    /// rather than a live toggle because capture is already running for this note by the time
    /// the row appears; flipping "Record call audio" mid-recording would need to start/stop a
    /// Core Audio tap under an in-progress note, which the settings toggle (Settings → Notes)
    /// already controls for the *next* recording — tapping this icon jumps there.
    var isCapturingCallAudio: Bool
    let onStop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot(color: Theme.error)
            if !collapsed {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(startedAt))
                    Text("Recording note · \(String(format: "%d:%02d", seconds / 60, seconds % 60))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if isCapturingCallAudio {
                    Image(systemName: "phone.arrow.down.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .help("Recording call audio")
                        .accessibilityLabel("Recording call audio")
                }
                Spacer(minLength: 4)
            }
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.bgSunken))
            }
            .buttonStyle(.plain)
            .help("Stop recording (⇧⌘N)")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, collapsed ? 0 : Theme.Space.m)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.bgRaised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording note")
    }
}

/// A small pulsing dot, factored out of `StatusDot` for a standalone indicator with no label.
private struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 4).scaleEffect(pulse ? 2 : 1).opacity(pulse ? 0 : 0.8))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// SwiftUI only applies `defaultSize` to brand-new windows; people who opened an earlier
/// build keep the old, smaller frame. Grow it once to the new default.
@MainActor
enum WindowSizing {
    static let preferred = NSSize(width: 1320, height: 880)

    static func enlargeOnce() {
        let key = "didApplyLargeWindowV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
                  let screen = window.screen?.visibleFrame,
                  window.frame.width < preferred.width else { return }
            let size = NSSize(width: min(preferred.width, screen.width - 40), height: min(preferred.height, screen.height - 40))
            let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        }
    }
}
