import AppKit
import MurmurCore
import SwiftUI

/// `Murmur --snapshots <dir>` renders every page, light and dark, to PNGs and quits.
/// Lets developers and agents review layout without clicking through the app.
@MainActor
enum Snapshots {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshots"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    /// Redirects `AppPaths` to a disposable directory before `AppModel` opens the database, so
    /// snapshot rendering never reads or writes the user's real notes and dictations. Must run
    /// before `AppModel()` is constructed (see `AppDelegate.init`).
    static func prepareEnvironmentIfNeeded() {
        guard requestedDirectory != nil, ProcessInfo.processInfo.environment["MURMUR_HOME"] == nil else { return }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("MURMUR_HOME", home.path, 1)
    }

    static func render(model: AppModel, to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = Fixtures.seed(into: model.store)
        let learnedFixtures = LearnedSnapshots.seed(into: model.store, settings: model.settings)
        prepareHomeHistory(model: model)
        model.library.startObserving()
        // Let the database observations deliver their first values.
        try? await Task.sleep(for: .seconds(1))
        let size = CGSize(width: 1320, height: 900)

        for scheme in [ColorScheme.light, .dark] {
            for (name, state) in [
                ("signed-out", BetaGateView.SnapshotState.signedOut),
                ("waiting-for-browser", .browser),
                ("sign-in-expired", .expired),
                ("waiting-for-approval", .waiting),
                ("could-not-check", .couldNotCheck),
                ("checking", .checking),
            ] {
                await capture(BetaGateView(gate: nil, snapshot: state), name: "gate-\(name)",
                              scheme: scheme, size: size, directory: directory)
            }
            // Pages show the Assistant connected with no conversation yet (suggested prompts);
            // `renderAssistant` covers the other states. Never probes for a real agent CLI.
            model.assistant.pinForSnapshot(installed: [.claudeCode], messages: [])
            await renderPages(model: model, scheme: scheme, size: size, directory: directory)
            await renderHomeStates(model: model, scheme: scheme, size: size, directory: directory)
            await renderHomeHistory(model: model, scheme: scheme, size: size, directory: directory)
            await renderAssistant(model: model, scheme: scheme, size: size, directory: directory)
            await renderDictateStatusStates(model: model, scheme: scheme, size: size, directory: directory)
            await renderPermissionRecovery(model: model, scheme: scheme, size: size, directory: directory)
            await renderOnboarding(model: model, scheme: scheme, size: size, directory: directory)
            await renderUXFeel(model: model, scheme: scheme, size: size, directory: directory)
            await renderActionTrigger(model: model, scheme: scheme, size: size, directory: directory)
            await renderActionPill(scheme: scheme, directory: directory)
            await renderHandoff(model: model, scheme: scheme, directory: directory)
            await renderNotPasted(scheme: scheme, directory: directory)
            await renderRecovery(scheme: scheme, directory: directory)
            await renderPastedUnchecked(scheme: scheme, directory: directory)
            await renderVoiceEdit(scheme: scheme, directory: directory)
            await renderRestyle(scheme: scheme, directory: directory)
            await renderPillMotion(scheme: scheme, directory: directory)
            await renderPillLive(scheme: scheme, directory: directory)
            await renderPillCentring(scheme: scheme, directory: directory)
            await renderLoadingProgress(scheme: scheme, directory: directory)
            await renderNameChip(scheme: scheme, directory: directory)
            await renderPills(scheme: scheme, directory: directory)
            await renderBrand(scheme: scheme, directory: directory)
            await renderLaunch(scheme: scheme, directory: directory)
            await renderInsightsStatRow(scheme: scheme, directory: directory)
            await renderVoiceLab(model: model, scheme: scheme, directory: directory)
            await renderTune(model: model, scheme: scheme, directory: directory)
            await renderHonesty(model: model, scheme: scheme, size: size, directory: directory)
            await renderSettingsPanes(model: model, scheme: scheme, directory: directory)
            await renderProPageStates(model: model, scheme: scheme, directory: directory)
            await renderTones(model: model, scheme: scheme, size: size, directory: directory)
            await renderUsageNumbers(model: model, scheme: scheme, directory: directory)
            await renderFeedback(model: model, scheme: scheme, directory: directory)
            await capture(
                SettingsGroup { CrashReportsSettingsSection(settings: model.settings) }.padding(Theme.Space.xl).environment(model),
                name: "crash-reports-settings", scheme: scheme, size: CGSize(width: 780, height: 140),
                directory: directory, fixedSize: true)
            await renderCleanupModel(model: model, scheme: scheme, directory: directory)
            await renderWritingHome(model: model, scheme: scheme, size: size, directory: directory)
            await renderCalendarNaming(scheme: scheme, directory: directory)
            await renderMicrophoneSetting(model: model, scheme: scheme, directory: directory)
            await renderUninstall(scheme: scheme, directory: directory)
            await renderUpdateReady(scheme: scheme, directory: directory)
            await renderRivalKey(scheme: scheme, directory: directory)
            await renderMemoryPane(scheme: scheme, directory: directory)
            await renderShareRecap(scheme: scheme, directory: directory)
            await renderActionItems(scheme: scheme, directory: directory)
            await renderOpenActionItems(scheme: scheme, directory: directory)
            await VoicesSnapshots.render(model: model, size: size) { view, name, size, fixed in
                await capture(view, name: name, scheme: scheme, size: size, directory: directory, fixedSize: fixed)
            }
            if let learnedFixtures {
                await LearnedSnapshots.render(model: model, seeded: learnedFixtures, size: size) { view, name, size, fixed in
                    await capture(view, name: name, scheme: scheme, size: size, directory: directory, fixedSize: fixed)
                }
            }
        }

        // After every other page, so the invented meetings never appear in their stills.
        await renderMeetings(model: model, size: size, directory: directory)
        writeMeetingsContactSheet(directory: directory)
        await renderNoteRestyle(model: model, size: size, directory: directory)
        model.settings.sidebarCollapsed = false
        model.clearSnapshotPreferences()
        _ = fixtures
        print("Snapshots written to \(directory.path)")
        NSApp.terminate(nil)
    }

    /// One page per app section, plus the extra Home and Notes states that need specific
    /// fixture rows or interaction state to show (needs-attention filter, an expanded failed
    /// row, a failed note selected).
    private static func renderPages(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        // `HUSHY_MEETINGS=off` renders the release layout: no Notes page then.
        for section in AppModel.Section.available() {
            model.section = section
            for collapsed in section == .home ? [false, true] : [false] {
                model.settings.sidebarCollapsed = collapsed
                await capture(
                    MainView().environment(model),
                    name: "\(section.rawValue)\(collapsed ? "-collapsed" : "")",
                    scheme: scheme, size: size, directory: directory)
            }
        }
        model.settings.sidebarCollapsed = false

        model.section = .home
        await capture(
            MainView().environment(model).environment(\.snapshotHomeSelection, true),
            name: "home-selected", scheme: scheme, size: size, directory: directory)
        // The sidebar's lower band for a founding member (the profile row; `home` itself follows
        // the machine's account), and the alternative `.hint` layout (a static key-cap line under
        // Record a note) for the founder's pick — `home` shows the live `.quiet` layout.
        await capture(
            MainView().environment(model).environment(\.snapshotPlan, .founding),
            name: "home-sidebar-founding", scheme: scheme, size: size, directory: directory)
        await capture(
            MainView().environment(model).environment(\.snapshotSidebarLayout, .hint),
            name: "home-sidebar-hint", scheme: scheme, size: size, directory: directory)

        model.section = .history
        await capture(
            MainView().environment(model).environment(\.snapshotHistoryFilter, .needsAttention),
            name: "history-needs-attention", scheme: scheme, size: size, directory: directory)

        await capture(
            MainView().environment(model).environment(\.snapshotHistorySelecting, true),
            name: "history-selected", scheme: scheme, size: size, directory: directory)

        await capture(
            MainView().environment(model).environment(\.snapshotHistoryDateRange, .last7Days),
            name: "history-date-filtered", scheme: scheme, size: size, directory: directory)

        let today = Calendar.current.startOfDay(for: Date())
        await capture(
            MainView().environment(model).environment(\.snapshotHistoryDateRange, .custom(start: today, end: today)),
            name: "history-day-selected", scheme: scheme, size: size, directory: directory)

        model.section = .notes
        if let failedNote = model.library.notes.first(where: { $0.status == .failed }) {
            model.selectedNoteID = failedNote.id
            await capture(MainView().environment(model), name: "notes-failed-selected", scheme: scheme, size: size, directory: directory)
        }
        await renderFreePlan(model: model, scheme: scheme, size: size, directory: directory)
        model.selectedNoteID = nil
    }

    /// The Account pane for a founding member and not (pinned via `snapshotPlan` so the real account
    /// on this Mac can't change it), and the Voice actions pane, which has no allowance any more.
    private static func renderFreePlan(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        for (plan, suffix) in [(SnapshotPlan.free, "free"), (.founding, "founding")] {
            let page = SettingsSnapshotPage(
                pane: .account, needsAttentionBadge: false,
                retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
            await capture(
                page.environment(model).environment(\.snapshotPlan, plan),
                name: "settings-account-\(suffix)", scheme: scheme, size: CGSize(width: 780, height: 720), directory: directory)
        }
        let actions = SettingsSnapshotPage(
            pane: .voiceActions, needsAttentionBadge: false,
            retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
        await capture(
            actions.environment(model).environment(\.snapshotPlan, .free),
            name: "settings-voiceActions-free", scheme: scheme, size: CGSize(width: 780, height: 720), directory: directory)
        // The note while Hushy's model downloads and the simple fixes run (TRY-88).
        let waiting = PillModel()
        waiting.state = .idle
        let downloading = LocalModelInstall.downloading(received: 38, total: 100, secondsRemaining: 140)
        waiting.banner = .cleanupModelWaiting(
            line: CleanupModelController.waitingLine(for: downloading) ?? "",
            progress: CleanupModelController.waitingProgress(for: downloading))
        await capture(
            PillView(model: waiting).padding(40).background(Theme.bgSunken).environment(\.colorScheme, scheme),
            name: "pill-cleanupModelWaiting", scheme: scheme, size: CGSize(width: 560, height: 160), directory: directory, fixedSize: true)
    }

    /// Home's Assistant column in each state (fixture messages, no real CLI), plus the Quick Look
    /// panel's content at its default size. Kept in its own function so additions elsewhere
    /// don't conflict with it.
    private static func renderAssistant(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        model.section = .home
        model.assistant.pinForSnapshot(installed: [.claudeCode, .codex], messages: AssistantModel.snapshotConversation)
        await capture(MainView().environment(model), name: "home-assistant-connected", scheme: scheme, size: size, directory: directory)

        // A forced "thinking" state: the agent's activity line ("Thinking…") is model-authored
        // energy, not the user's, so it takes purple (`Theme.working`), never lime (C2).
        model.assistant.pinForSnapshot(
            installed: [.claudeCode, .codex],
            messages: [
                AssistantModel.Message(role: .user, text: "Draft a standup update from today"),
                AssistantModel.Message(role: .assistant, text: "", activity: "Thinking…", isStreaming: true),
            ])
        await capture(MainView().environment(model), name: "home-assistant-thinking", scheme: scheme, size: size, directory: directory)

        model.assistant.pinForSnapshot(installed: [], messages: [])
        await capture(MainView().environment(model), name: "home-assistant-notconnected", scheme: scheme, size: size, directory: directory)

        model.assistant.pinForSnapshot(installed: [.claudeCode, .codex], messages: [], signedOut: [.claudeCode])
        await capture(MainView().environment(model), name: "home-assistant-signedout", scheme: scheme, size: size, directory: directory)

        // Off (the default): install line on the card; no agent CLI is probed while off.
        model.assistant.pinForSnapshot(installed: [], messages: [], enabled: false)
        await capture(MainView().environment(model), name: "home-assistant-off", scheme: scheme, size: size, directory: directory)

        model.assistant.pinForSnapshot(
            installed: [.claudeCode], messages: AssistantModel.snapshotActionConversation, title: "Remind me tomorrow at 9…")
        let handlers = model.assistant.actionHandlers
        model.assistant.actionHandlers.isEntitled = { true }
        await capture(MainView().environment(model), name: "home-assistant-action", scheme: scheme, size: size, directory: directory)
        model.assistant.actionHandlers = handlers
        await renderAssistantActionOutcomes(model: model, scheme: scheme, directory: directory)

        // Popovers and sheets can't be drawn by `ImageRenderer`; render their content directly.
        await capture(
            ChatHistoryView(fixture: AssistantModel.snapshotHistory()).environment(model),
            name: "home-assistant-history", scheme: scheme, size: CGSize(width: 300, height: 420), directory: directory,
            fixedSize: true)
        await capture(
            AssistantConsentSheet(onAccept: {}, onCancel: {}).environment(model),
            name: "home-assistant-consent", scheme: scheme, size: CGSize(width: 460, height: 470), directory: directory,
            fixedSize: true)

        model.assistant.pinForSnapshot(installed: [.claudeCode], messages: [])
        model.settings.assistantCollapsed = true
        await capture(MainView().environment(model), name: "home-assistant-collapsed", scheme: scheme, size: size, directory: directory)
        model.settings.assistantCollapsed = false
        // Settings → AI connections (rendered later) shows one ready agent and one to sign in.
        model.assistant.pinForSnapshot(installed: [.claudeCode, .codex], messages: [], signedOut: [.codex])

        let calendar = model.dayClock.calendar
        if let dictation = model.library.dictations.first(where: { calendar.isDate($0.createdAt, inSameDayAs: model.dayClock.now) && !$0.text.isEmpty }) {
            let quickLook = DictationQuickLook()
            let library = model.library
            let clock = model.dayClock
            quickLook.order = { Snapshots.homeQuickLookOrder(library: library, clock: clock) }
            quickLook.select(dictation.id)
            await capture(
                QuickLookContent(quickLook: quickLook, snapshotDictation: dictation).environment(model),
                name: "home-quicklook", scheme: scheme, size: DictationQuickLook.defaultSize, directory: directory, fixedSize: true)
        }
    }

    /// The sidebar's readiness row (`SidebarReadinessRow`; absent when ready) in each of the
    /// states `DictationReadinessStatusTests.snapshotStatesCoverDistinctKinds` locks down (plus
    /// `dictate-status-loading`, added for the purple/ink split — C2): ready, the speech model
    /// downloading (ink — a transfer), the speech model loading into memory (purple — the model
    /// working), microphone access needed, Accessibility needed, and a Keyboard-settings conflict
    /// warning. Captures the whole sidebar (via `MainView`, like `renderPages`) rather than the
    /// row in isolation, so a reviewer sees it in the real hierarchy next to "Record a note" and
    /// the Assistant row. State is restored to "ready" afterwards so later captures in this same
    /// pass aren't affected.
    private static func renderDictateStatusStates(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        model.section = .home
        model.settings.sidebarCollapsed = false
        model.modelStatus.pinForSnapshot(.ready)
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .granted)
        await capture(MainView().environment(model), name: "dictate-status-ready", scheme: scheme, size: size, directory: directory)

        let expected = SpeechEngine.expectedDownloadBytes(for: .v2)
        let downloading = ModelDownloadProgress(
            fraction: 0.43, expectedBytes: expected, completedFiles: 1, totalFiles: 4, estimatedSecondsRemaining: 30)
        model.modelStatus.pinForSnapshot(.downloading(downloading.fraction), download: downloading)
        await capture(MainView().environment(model), name: "dictate-status-downloading", scheme: scheme, size: size, directory: directory)
        model.modelStatus.pinForSnapshot(.ready)

        // The model moving into memory (not a transfer): purple, not ink (C2).
        model.modelStatus.pinForSnapshot(.loading)
        await capture(MainView().environment(model), name: "dictate-status-loading", scheme: scheme, size: size, directory: directory)
        model.modelStatus.pinForSnapshot(.ready)

        model.permissions.pinForSnapshot(microphone: .denied)
        await capture(MainView().environment(model), name: "dictate-status-mic-needed", scheme: scheme, size: size, directory: directory)
        model.permissions.pinForSnapshot(microphone: .granted)

        model.permissions.pinForSnapshot(accessibility: .denied)
        await capture(MainView().environment(model), name: "dictate-status-accessibility-needed", scheme: scheme, size: size, directory: directory)
        model.permissions.pinForSnapshot(accessibility: .granted)

        // The remapped-Globe-key warning would otherwise depend on the real machine's Globe-key
        // action (`Permissions.globeKeyAction`); `snapshotDictateWarning` forces that branch
        // instead, so the capture is deterministic in CI (see the environment key's doc comment).
        await capture(
            MainView().environment(model).environment(\.snapshotDictateWarning, true),
            name: "dictate-status-keyboard-conflict", scheme: scheme, size: size, directory: directory)
    }

    /// One capture per Settings pane (General, Privacy, Voice actions, Account, About, Advanced,
    /// the Notes & meetings preview pane, and — DEBUG builds only — Developer), each rendered with
    /// the left sidebar so a reviewer sees the real window shape, not just the content column.
    /// Advanced is captured twice more: with the notes and meetings preview switched on (which
    /// adds the Assistant settings), and the Erase sheet beside Privacy. Settings is its own
    /// window/scene now (see `MurmurApp`'s `Settings { }` scene); `ImageRenderer` can't render
    /// `TabView` (or other live-window-backed AppKit navigation) off-screen — it crashes with "no
    /// current update to enqueue action to" — so this renders `SettingsSnapshotPage` (sidebar +
    /// `SettingsPaneContent`) directly instead, one pane at a time, the same pattern as Voice
    /// Lab/Tune below.
    private static func renderSettingsPanes(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let needsAttention = !model.permissions.allGranted
            || (Permissions.globeKeyAction.conflicts && model.settings.triggerKey == .fn)
        func page(_ pane: SettingsPane) -> SettingsSnapshotPage {
            SettingsSnapshotPage(
                pane: pane, needsAttentionBadge: needsAttention,
                retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
        }
        // The Assistant group in Advanced shows only for an install that already turned it on (or
        // while previewing notes and meetings); the stills show a fresh install.
        let assistantWasOn = model.settings.assistantEnabled
        model.settings.assistantEnabled = false
        defer { model.settings.assistantEnabled = assistantWasOn }
        for pane in SettingsPane.allCases {
            await capture(
                page(pane).environment(model),
                name: "settings-\(pane.rawValue)", scheme: scheme, size: CGSize(width: 780, height: 720),
                directory: directory)
            // The real window's fold: the same pane clipped at the window's height, so a
            // reviewer sees what shows before scrolling (`ImageRenderer` can't draw the live
            // scroll view itself).
            let window = SettingsView.windowSize
            await capture(
                page(pane).environment(model).frame(height: window.height, alignment: .top).clipped(),
                name: "settings-\(pane.rawValue)-window", scheme: scheme, size: window, directory: directory, fixedSize: true)
        }
        let preview = model.settings.notesAndMeetingsPreview
        model.settings.notesAndMeetingsPreview = true
        await capture(
            page(.advanced).environment(model),
            name: "settings-advanced-preview-on", scheme: scheme, size: CGSize(width: 780, height: 900), directory: directory)
        model.settings.notesAndMeetingsPreview = preview
        await capture(
            EraseDataSheet().environment(model),
            name: "settings-erase", scheme: scheme, size: CGSize(width: 520, height: 380), directory: directory, fixedSize: true)
    }

    private static func renderProPageStates(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let session = AccountSession(userID: "snapshot-person", accessToken: "fixture", refreshToken: "fixture",
                                     expiresAt: .distantFuture, email: "sample@example.invalid")
        let base = AccountConfiguration(url: URL(string: "https://example.invalid")!, anonKey: "fixture")
        // Hushy is free (founder, 2026-11-11): the pane differs only by sign-in and the badge.
        let states: [(String, SnapshotPlan, ProPageSnapshotAccount)] = [
            ("signed-out", .free, .init(signedIn: false, session: nil, inviteOutcome: nil, configuration: base)),
            ("founding", .founding, .init(signedIn: true, session: session, inviteOutcome: .noCode, configuration: base)),
            ("signed-in", .free, .init(signedIn: true, session: session, inviteOutcome: .noCode, configuration: base)),
        ]
        for (name, plan, account) in states {
            let page = SettingsSnapshotPage(pane: .account, needsAttentionBadge: false,
                retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
            await capture(page.environment(model).environment(\.snapshotPlan, plan).environment(\.snapshotProAccount, account),
                          name: "account-page-\(name)", scheme: scheme, size: CGSize(width: 780, height: 720), directory: directory)
        }
    }

    /// Voice Lab, captured directly (bypassing Settings' sheet presentation, same as
    /// onboarding below) at its own fixed sheet size rather than the full page size.
    private static func renderVoiceLab(model: AppModel, scheme: ColorScheme, directory: URL) async {
        await capture(
            VoiceLabView().environment(model),
            name: "voicelab", scheme: scheme, size: CGSize(width: 640, height: 620), directory: directory, fixedSize: true)
    }

    /// "Tune Hushy to your voice", captured directly at its own sheet size (same pattern as
    /// Voice Lab above). Kept in its own function, separate from the pill/page renderers other
    /// agents extend, so additions here don't create merge conflicts with theirs.
    private static func renderTune(model: AppModel, scheme: ColorScheme, directory: URL) async {
        await capture(
            TuneView().environment(model),
            name: "tune", scheme: scheme, size: CGSize(width: 640, height: 620), directory: directory, fixedSize: true)
    }

    /// Every `PillState`, rendered at the pill's real (small) size on a neutral backdrop.
    /// Brand surfaces (`brand-*`): the sidebar wordmark and tile at three sizes, the menu-bar
    /// glyph in both states on a menu-bar-like strip (at the renderer's 2× plus a ×4 zoom), and
    /// the h-key hold-to-talk proposal (direction A) — a proposal only, nothing live uses it.
    private static func renderBrand(scheme: ColorScheme, directory: URL) async {
        let isDark = scheme == .dark
        let strip = isDark ? Color(hex: 0x1C1E25) : Color(hex: 0xE6E9E4)
        let tint: Color = isDark ? .white : .black
        let menuBar = HStack(spacing: 14) {
            Text("Finder").font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text("File").font(.system(size: 13)).foregroundStyle(tint)
            Spacer()
            ForEach([false, true], id: \.self) { active in
                Image(nsImage: MenuBarGlyph.image(active: active)).renderingMode(.template).foregroundStyle(tint)
            }
            Text("Mon 28 Sep  9:41").font(.system(size: 13)).foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .frame(width: 360, height: 24)
        .background(strip)
        let sheet = VStack(alignment: .leading, spacing: 28) {
            Wordmark()
            HStack(alignment: .bottom, spacing: 24) {
                LogoTile(size: 30)
                LogoTile(size: 64)
                LogoTile(size: 128)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Menu bar: resting, listening").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                menuBar
                menuBar.scaleEffect(4, anchor: .topLeading).frame(width: 360 * 4, height: 24 * 4, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Hold-to-talk key (direction A) — proposal, not live: resting, held")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 24) {
                    HoldKeyGlyph(size: 40)
                    HoldKeyGlyph(size: 64)
                    HoldKeyGlyph(size: 64, held: true)
                    HoldKeyGlyph(size: 96, held: true)
                }
            }
        }
        .padding(32)
        await capture(sheet, name: "brand", scheme: scheme, size: CGSize(width: 1520, height: 200), directory: directory)
    }


    private static func renderPills(scheme: ColorScheme, directory: URL) async {
        let normalLevels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        let states: [(String, PillState)] = [
            ("idle", .idle),
            ("listening", .listening),
            ("handsFree", .handsFree(startedAt: Date())),
            ("recordingNote", .recordingNote(startedAt: Date())),
            ("processing", .processing()),
            ("actionProcessing", .actionProcessing),
            ("processingMode", .processing(modeName: "Email")),
            ("done", .done(words: 42)),
            ("doneAsHeard", .done(words: 42, asHeard: true)),
            ("doneNotSent", .done(words: 42, notSent: true)),
            ("doneShort", .done(words: 8)),
            // Every outcome that isn't a paste is one line (UI round 2026-09-28 §1): copied for
            // ⌘V, or held for a password field — never the text.
            ("copiedSwitchedApps", .copied(reason: .targetChanged(.app))),
            ("copiedAnotherField", .copied(reason: .targetChanged(.field))),
            ("copiedPasteFailed", .copied(reason: .pasteFailed)),
            ("heldSecureField", .held(copied: false)),
            ("heldSecureField-copied", .held(copied: true)),
            ("error", .error(PillModel.microphoneFailedMessage)),
        ]
        for (name, state) in states {
            let pill = PillModel()
            pill.state = state
            pill.showWhenIdle = true
            switch state {
            case .listening, .handsFree, .recordingNote:
                pill.setLevels(normalLevels)
            default:
                break
            }
            let view = PillView(model: pill)
                .padding(40)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: "pill-\(name)", scheme: scheme, size: CGSize(width: 480, height: 160), directory: directory, fixedSize: true)
        }

        await renderPillStages(levels: normalLevels, scheme: scheme, directory: directory)
        await renderPillActions(scheme: scheme, directory: directory)
        await renderAppChoice(scheme: scheme, directory: directory)
        await renderPillAnchors(scheme: scheme, directory: directory)
        await renderNoField(scheme: scheme, directory: directory)
        await renderPillHover(scheme: scheme, directory: directory)
        await renderPillHints(scheme: scheme, directory: directory)
        await renderPillSide(scheme: scheme, directory: directory)
        await renderPillAsk(scheme: scheme, directory: directory)
        await renderPillFiles(scheme: scheme, directory: directory)
        await renderActionOutcomes(scheme: scheme, directory: directory)
        await renderActionMissingTarget(scheme: scheme, directory: directory)
        await renderPillV3(scheme: scheme, directory: directory)

        // The adaptive level meter's whole point is that a whisper and loud speech both produce
        // visible bar motion — capture both ends of that range so a reviewer can eyeball it
        // without running a live mic (see AdaptiveLevelMeter and its unit tests).
        await renderLevelVariant(name: "pill-listening-whisper", rms: 0.002, scheme: scheme, directory: directory)
        await renderLevelVariant(name: "pill-listening-loud", rms: 0.3, scheme: scheme, directory: directory)

        // A hovered ✓ tooltip ("Done"), like the Wispr Flow reference's hint. Live
        // hover state can't be captured by ImageRenderer, so `snapshotForceTooltip` renders the
        // tooltip as if hovered.
        let tooltipPill = PillModel()
        tooltipPill.state = .handsFree(startedAt: Date())
        tooltipPill.setLevels(normalLevels)
        let tooltipView = PillView(model: tooltipPill)
            .padding(40)
            .background(Theme.bgSunken)
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotForceTooltip, true)
        await capture(tooltipView, name: "pill-handsFree-tooltip", scheme: scheme, size: CGSize(width: 480, height: 160), directory: directory, fixedSize: true)

        // The hovered idle pill (mic + ⚡ buttons, the "Dictate fn"/"Action fn ⌃" hint, and the
        // format chip): hover lives on `PillModel`, so it can be forced here without a pointer.
        let modes = [
            (id: UUID(), name: "Email", icon: "envelope"),
            (id: UUID(), name: "Message", icon: "message"),
        ]
        let hovers: [(String, PillModel.IdleControl?, PillModel.ActiveMode?)] = [
            ("idle-hover", nil, nil),
            ("idle-hover-action", .action, nil),
            ("idle-hover-mode", .dictate, PillModel.ActiveMode(name: "Email", isManualOverride: true)),
            ("idle-hover-action-mode", .action, PillModel.ActiveMode(name: "Email", isManualOverride: true)),
        ]
        for (name, control, activeMode) in hovers {
            let pill = PillModel()
            pill.state = .idle
            pill.showWhenIdle = true
            pill.modeChoices = modes
            pill.activeMode = activeMode
            pill.isHovered = true
            pill.hoveredIdleControl = control
            let view = PillView(model: pill)
                .padding(40)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: "pill-\(name)", scheme: scheme, size: CGSize(width: 480, height: 160), directory: directory, fixedSize: true)
        }
    }

    /// The processing choreography (DESIGN-LANGUAGE.md §3.1): wet ink while polishing (short and
    /// overflowing), dry ink while typing, and a listening pill whose afterglow ghosts sit above
    /// falling bars — each driven through the real `PillModel.advance(to:ink:)` path.
    private static func renderPillStages(levels: [Double], scheme: ColorScheme, directory: URL) async {
        let raw = "so um I think we should ship the pill on friday no thursday"
        let longRaw = "okay so the plan for the launch is we do the private beta first and then um the public launch once gate twelve passes"
        let cleaned = "I think we should ship the pill on Thursday."
        let stages: [(String, PillModel.ProcessingStage, String?)] = [
            ("pill-polishing", .polishing, raw),
            ("pill-polishing-long", .polishing, longRaw),
            ("pill-typing", .typing, cleaned),
        ]
        for (name, stage, ink) in stages {
            let pill = PillModel()
            pill.state = .processing()
            pill.setLevels(levels)
            if stage == .typing { pill.advance(to: .polishing, ink: raw) }
            pill.advance(to: stage, ink: ink)
            await capturePill(pill, name: name, scheme: scheme, directory: directory)
        }
        let afterglow = PillModel()
        afterglow.state = .listening
        afterglow.setLevels(levels.map { $0 * 0.45 }, peaks: levels)
        await capturePill(afterglow, name: "pill-listening-afterglow", scheme: scheme, directory: directory)
    }

    private static func capturePill(_ pill: PillModel, name: String, scheme: ColorScheme, directory: URL) async {
        let view = PillView(model: pill)
            .padding(40)
            .background(Theme.bgSunken)
            .environment(\.colorScheme, scheme)
        await capture(view, name: name, scheme: scheme, size: CGSize(width: 480, height: 160), directory: directory, fixedSize: true)
    }

    /// Feeds a steady RMS through the real `PillModel.push(rms:)` path (and its
    /// `AdaptiveLevelMeter`) so the snapshot reflects actual whisper/loud-speech mapping rather
    /// than hand-picked bar heights.
    private static func renderLevelVariant(name: String, rms: Float, scheme: ColorScheme, directory: URL) async {
        let pill = PillModel()
        pill.state = .listening
        pill.showWhenIdle = true
        let start = Date()
        for index in 0..<PillModel.barCount {
            pill.push(rms: rms, now: start.addingTimeInterval(Double(index) * 2 * PillModel.levelUpdateInterval))
        }
        let view = PillView(model: pill)
            .padding(40)
            .background(Theme.bgSunken)
            .environment(\.colorScheme, scheme)
        await capture(view, name: name, scheme: scheme, size: CGSize(width: 480, height: 160), directory: directory, fixedSize: true)
    }

    /// Renders one view to a PNG named `<name>-<light|dark>.png`.
    static func capture<V: View>(
        _ view: V, name: String, scheme: ColorScheme, size: CGSize, directory: URL, fixedSize: Bool = false
    ) async {
        // `HUSHY_SNAPSHOT_ONLY=pill-` renders just the matching names — a fast loop while
        // iterating on one surface. Unset, every page renders as before.
        if let only = ProcessInfo.processInfo.environment["HUSHY_SNAPSHOT_ONLY"], !only.isEmpty,
           !only.split(separator: ",").contains(where: { name.hasPrefix($0) }) { return }
        var dependencies = BetaGateDependencies.live()
        dependencies.keeper = AccountSessionKeeper(store: AccountSessionStore(keys: InMemoryKeyStore())) { _ in throw AccountError.requestFailed }
        dependencies.approvals = BetaApprovalStore(keys: InMemoryKeyStore())
        dependencies.client = { nil }
        let gate = BetaGateController(dependencies: dependencies)
        let framed = view
            .environment(gate)
            .environment(\.isSnapshot, true)
            .frame(width: size.width)
            .frame(minHeight: fixedSize ? nil : size.height, maxHeight: fixedSize ? size.height : nil)
            .background(Theme.bgBase)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        renderer.proposedSize = fixedSize
            ? ProposedViewSize(width: size.width, height: size.height)
            : ProposedViewSize(width: size.width, height: nil)
        NSApp?.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        guard let image = renderer.cgImage, let png = sRGBPNG(from: image) else { return }
        let fileName = "\(name)-\(scheme == .dark ? "dark" : "light").png"
        try? png.write(to: directory.appendingPathComponent(fileName))
    }

    /// Encodes as 8-bit sRGB. When a page draws real app icons (Voice & style), `ImageRenderer`
    /// returns a 16-bit BT.2100 PQ (HDR) bitmap, and writing that as-is made the whole PNG look
    /// uniformly washed out next to the sRGB captures of every other page. Reference-white tone
    /// mapping puts PQ's SDR white back at sRGB white; a plain draw would land it visibly gray.
    private static func sRGBPNG(from image: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if !context.draw(image, in: bounds, by: .referenceWhiteBased, options: nil) {
            context.draw(image, in: bounds)
        }
        guard let flattened = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:])
    }
}

/// Synthetic rows for the states the real (empty, disposable) snapshot database lacks:
/// a needs-attention dictation, a failed note, and personalization entries.
private enum Fixtures {
    @discardableResult
    static func seed(into store: Store) -> Bool {
        let now = Date()
        let dictations: [Dictation] = [
            // Own-app dictations (recorded in Hushy's own practice field/UI, like onboarding's
            // "Try it now" box) carry Hushy's own bundle ID, matching what `DictationController`
            // actually captures from the frontmost app — see `AppIcon.isOwnApp` in
            // `HistoryAudio.swift`, which shows the app icon (never the dashed placeholder) for
            // these.
            Dictation(
                createdAt: now.addingTimeInterval(-60), rawText: "let's meet at nine and bring your laptop",
                text: "Let's meet at nine and bring your laptop.", appBundleID: Insights.ownBundleID, appName: "Hushy",
                durationSeconds: 4.2, latencyMs: 180, fixes: 2, status: .inserted,
                timeSplit: DictationTimeSplit(speechMs: 90, cleanupMs: 60, insertMs: 30)),
            // A run of consecutive same-app dictations (well within the 30-minute gap window),
            // so History's list shows one "Hushy" header with a thread line joining these two
            // rows to the one above, instead of three separate app badges.
            Dictation(
                createdAt: now.addingTimeInterval(-180), rawText: "and also send the invite",
                text: "And also send the invite.", appBundleID: Insights.ownBundleID, appName: "Hushy",
                durationSeconds: 2.0, latencyMs: 150, status: .inserted),
            Dictation(
                createdAt: now.addingTimeInterval(-900), rawText: "hey is this working",
                text: "Hey, is this working?", appBundleID: Insights.ownBundleID, appName: "Hushy",
                durationSeconds: 2.1, latencyMs: 140, status: .notInserted),
            Dictation(
                createdAt: now.addingTimeInterval(-1_800), rawText: "",
                text: "", appBundleID: "com.anthropic.claude", appName: "Claude", durationSeconds: 6.4, status: .failed),
            // A burst of identical failures within the stacking window, so History collapses
            // them into one "N recordings · transcription failed" row instead of three.
            Dictation(
                createdAt: now.addingTimeInterval(-2_000), rawText: "",
                text: "", appBundleID: "com.anthropic.claude", appName: "Claude", durationSeconds: 3.1, status: .failed,
                audioPath: "/tmp/murmur-snapshot-stack-1.wav"),
            Dictation(
                createdAt: now.addingTimeInterval(-2_040), rawText: "",
                text: "", appBundleID: "com.anthropic.claude", appName: "Claude", durationSeconds: 2.8, status: .failed),
            Dictation(
                createdAt: now.addingTimeInterval(-2_080), rawText: "",
                text: "", appBundleID: "com.anthropic.claude", appName: "Claude", durationSeconds: 3.4, status: .failed,
                audioPath: "/tmp/murmur-snapshot-stack-2.wav"),
        ]
        for item in dictations { _ = try? store.save(item) }

        // One still-undoable voice action, so Home's Today feed and History both show the
        // "Added … to Calendar · Undo" timeline row from the mockup (§7).
        let actions: [ActionRecord] = [
            ActionRecord(
                createdAt: now.addingTimeInterval(-40), kind: .createEvent, title: "Dentist",
                detail: "Tomorrow · 3:00 PM", sourceText: "book a dentist appointment tomorrow at three",
                status: .completed, undoBackendID: "snapshot-undo-token"),
        ]
        for item in actions { _ = try? store.save(item) }

        // Two folders so the Notes list column's folder strip has real chips to show, with
        // one note filed into each and one left unfiled (so "Unfiled" also appears).
        let workFolder = try? store.createFolder(name: "Work")
        let personalFolder = try? store.createFolder(name: "Personal")

        var notes: [Note] = [
            Note(
                title: "Weekly sync", createdAt: now.addingTimeInterval(-3_600),
                updatedAt: now.addingTimeInterval(-3_500), durationSeconds: 612,
                transcript: "We reviewed the roadmap and agreed to ship the snapshot tooling this week.",
                summary: "- Reviewed roadmap\n- Agreed to ship snapshot tooling this week",
                actionItems: ["Ship snapshot tooling", "Follow up with design on onboarding copy"],
                status: .ready, folderId: workFolder?.id),
            Note(
                // A realistic auto-generated title: `finalizedStatus` marks a note failed
                // only when the transcript is empty or a chunk/persist step failed, so the
                // title itself never becomes "Recording incomplete" — that's shown as a
                // status badge instead (see NotesView's IncompleteNoteBanner and StatusBadge).
                title: "Note · " + now.addingTimeInterval(-7_200).formatted(date: .omitted, time: .shortened),
                createdAt: now.addingTimeInterval(-7_200),
                updatedAt: now.addingTimeInterval(-7_100), durationSeconds: 45,
                transcript: "", summary: "", actionItems: [], status: .failed),
            Note(
                title: "Grocery list ideas", createdAt: now.addingTimeInterval(-10_800),
                updatedAt: now.addingTimeInterval(-10_700), durationSeconds: 38,
                transcript: "Milk, eggs, bread, and something for dinner tomorrow night.",
                summary: "- Milk, eggs, bread\n- Plan dinner for tomorrow",
                actionItems: [], status: .ready, folderId: personalFolder?.id),
        ]
        // The first note has owners and due dates as fields (migration v18); the others stay as
        // older notes are: lines only.
        notes[0].setActionItems(ActionItemSnapshots.weeklySync.map(\.line), details: ActionItemSnapshots.weeklySync)
        for item in notes { _ = try? store.save(item) }

        let entries: [DictionaryEntry] = [
            DictionaryEntry(term: "Supabase", soundsLike: ["super base", "supa base"]),
            // Not "Priya": that one is the learned-term suggestion (`LearnedSnapshots`), and
            // Hushy never suggests a word that is already in the dictionary.
            DictionaryEntry(term: "Figma", soundsLike: ["fig ma"]),
        ]
        for entry in entries { _ = try? store.save(entry) }

        let snippets: [Snippet] = [
            Snippet(trigger: "my calendar link", expansion: "https://cal.com/your-name"),
        ]
        for snippet in snippets { _ = try? store.save(snippet) }

        return true
    }
}
