import AppKit
import HushyModelsApple
import MurmurCore
import SwiftUI
import UserNotifications

/// The process entry point. Debug builds can start the headless mock-microphone mode (no windows,
/// no menu bar item), and `--pill-preview` plays the pill's states with invented text in a small
/// application of its own (`PillPreviewLauncher`); everything else starts the app exactly as before.
@main
@MainActor
enum EntryPoint {
    static func main() {
        #if DEBUG
        if MockMicArguments.requested(CommandLine.arguments) { MockMicLauncher.launch(CommandLine.arguments) }
        if MeetingJournalTrial.requested(CommandLine.arguments) { MeetingJournalTrial.launch(CommandLine.arguments) }
        #endif
        if PillPreviewArguments.requested(CommandLine.arguments) { PillPreviewLauncher.launch(CommandLine.arguments) }
        MurmurApp.main()
    }
}

struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Hushy", id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.gate)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 880)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.model.updates.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                if FeatureFlags.meetings {
                    Button("Transcribe a File…") { delegate.model.presentImportPanel() }
                        .keyboardShortcut("o", modifiers: .command)
                        .disabled(!delegate.gate.isOpen)
                }
            }
            CommandGroup(after: .sidebar) {
                if FeatureFlags.meetings {
                    Button(delegate.model.settings.assistantCollapsed ? "Show Assistant" : "Hide Assistant") {
                        if delegate.model.settings.assistantCollapsed {
                            delegate.model.showAssistant(hasRoom: nil)
                        } else {
                            delegate.model.settings.assistantCollapsed = true
                        }
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(!delegate.gate.isOpen)
                }
            }
            CommandMenu(MenuBarCopy.dictateMenu) {
                if FeatureFlags.meetings {
                    Button(delegate.model.recorder.isRecording ? "Stop Note Recording" : "Record a Note") {
                        delegate.model.toggleNoteRecording()
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!delegate.gate.isOpen)
                }
                // Not while the app lock is on: both hand over dictated words (`LockedCopy`).
                Button("Paste Last Transcript") { delegate.model.dictation.pasteLast() }
                    .disabled(!delegate.gate.isOpen || delegate.model.appLock.isLocked)
                Button("Copy Last Transcript") { delegate.model.dictation.copyLast() }
                    .disabled(!delegate.gate.isOpen || delegate.model.appLock.isLocked)
                if FeatureFlags.meetings {
                    Divider()
                    Button("Transcribe a File…") { delegate.model.presentImportPanel() }
                        .disabled(!delegate.gate.isOpen)
                }
            }
        }

        // A real macOS Settings window (⌘,, and the standard app-menu item), Wispr-Flow-style: a
        // left sidebar of grouped panes rather than a section inside the main window. See
        // `SettingsView`. SwiftUI supplies the ⌘, shortcut and the "Hushy → Settings…" menu item
        // automatically for a `Settings` scene, so no explicit `CommandGroup` is needed for it.
        Settings {
            Group {
                if delegate.gate.isOpen { SettingsView().environment(delegate.model) }
                else { BetaGateView(gate: delegate.gate) }
            }
            .environment(delegate.gate)
            .tint(Theme.phosphor)
        }
        // One window size for every pane (the panes scroll inside it); the user may make it
        // taller within `SettingsView`'s limits, never wider.
        .defaultSize(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
        .windowResizability(.contentSize)

        // Send Feedback from the menu bar menu, which cannot hold a sheet. Never reopened at launch.
        Window(FeedbackCopy.windowTitle, id: FeedbackSheet.windowID) {
            FeedbackSheet(showsTitle: false).environment(delegate.model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        // Snapshot runs render off-screen and quit; they must not look like a second Hushy.
        MenuBarExtra(isInserted: Binding(get: { Snapshots.requestedDirectory == nil && delegate.gate.isOpen }, set: { _ in })) {
            MenuBarContent()
                .environment(delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: AppModel
    let gate = BetaGateController()
    private var lastPlanReturnRefresh: Date?

    override init() {
        // Must happen before AppModel() opens the database, so snapshot rendering reads and
        // writes a disposable fixture database instead of the user's real one.
        Snapshots.prepareEnvironmentIfNeeded()
        // One-time Murmur → Hushy data migration (folder + UserDefaults). Also must run before
        // AppModel() touches AppPaths/UserDefaults. No-ops once migrated, and no-ops under the
        // snapshot override above since that points both old/new lookups at a disposable dir.
        AppDataMigration.migrateIfNeeded()
        // The on-device model behind modes, actions and summaries, and the Apple leg of dictation
        // cleanup (whose backend is `CleanupModelController.backend`: Apple / local MLX / rules,
        // Settings → Writing). Must be set before AppModel() builds its services, which capture it.
        LanguageModels.current = AppleFoundationModel()
        model = AppModel()
        super.init()
        // A session the Keychain would not save lives only in the gate; model downloads may use it.
        model.cleanupModel.currentAccountSession = { [weak gate] in gate?.currentSession }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon, menu bar or windows for snapshot runs (agents render these while the
        // founder is using the real app).
        if Snapshots.requestedDirectory != nil { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let now = Date()
        guard PlanReturnRefresh.shouldRefresh(last: lastPlanReturnRefresh, now: now,
                                              signedIn: gate.currentSession != nil) else { return }
        lastPlanReturnRefresh = now
        Task { await refreshPlanAfterReturn() }
    }

    private func refreshPlanAfterReturn() async {
        guard let account = gate.currentSession,
              let configuration = AccountConfiguration(),
              let session = try? await AccountSessionKeeper.shared.usable(fallback: account),
              session.userID == account.userID,
              let value = try? await AccountClient(configuration: configuration).entitlement(
                  session.accessToken, userID: session.userID),
              gate.currentSession?.userID == session.userID else { return }
        try? AccountEntitlementStore().save(value)
        model.refreshEntitlementSnapshot()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = Snapshots.requestedDirectory {
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task { await Snapshots.render(model: model, to: directory) }
            return
        }
        if SingleInstance.yieldIfAnotherInstanceIsRunning() { return }
        // Not `UNUserNotificationCenter.current()` here: it traps without an app bundle. The
        // notifier asks for it only in a real app, and only when a task notification could exist.
        TaskHandoffNotifier.responder = self
        TaskHandoffNotifier.listenForTaps()
        InstalledAppCatalog.shared.start()
        RankedInstalledApps.shared.start(store: model.store)
        // Before the gate decides: a person stuck at the gate must still be able to receive a fix.
        model.startUpdateChecker()
        model.dictation.restyle.servicesProvider.register()
        gate.start(host: model)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier.hasPrefix("app.hushy.task.") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.openMainWindow()
                self.model.handoff.openList()
            }
        }
        completionHandler()
    }

    /// The browser returning from the website's sign-in page (`hushy://sign-in?id=…`). Anything that
    /// is not that, or that nothing is waiting for, is ignored; the addresses are never logged.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where gate.handleOpenURL(url) { model.openMainWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Once an uninstall has removed things, an ordinary quit would save settings and window
    /// positions back, so the uninstall is asked to do the quitting. It says no when it is not
    /// running any more, is a test run, or has taken too long (`UninstallFlow.handleAppQuit`),
    /// and then this is an ordinary quit: ⌘Q is never left dead.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isUninstalling, model.quitAfterUninstall?() == true { return .terminateCancel }
        // A recording in progress reaches the disk sealed first, so the next launch finishes it (notes audit B3);
        // a session that made a task queue stops its child. Either is bounded, so a quit is never left hanging.
        let recording = model.recorder.isRecording
        guard recording || model.handoff.hasLiveQueue else { return .terminateNow }
        Task { @MainActor in
            if recording { await QuitDeadline.run(within: .milliseconds(1_500)) { await self.model.recorder.flushForQuit() } }
            if model.handoff.hasLiveQueue { await model.handoff.shutdown() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // An uninstall has removed the data folder; saving anything now would bring it back.
        guard !model.isUninstalling else { return }
        // Stops a running agent request and removes the conversation's scratch directory.
        model.assistant.shutdown()
        // A voice action's question still open on the pill counts as not answered.
        model.voiceActions.settleForQuit()
        // Dictations still waiting for an edit verdict are recorded as not checked.
        model.usageMetrics.flushForQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An uninstall closed the main window on purpose; a click on the Dock must not reopen it.
        guard !model.isUninstalling else { return false }
        if !flag { model.openMainWindow() }
        return true
    }
}

/// Our own mark (five bars) as a template image, so it tints with the menu bar like system icons.
private struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        let active: Bool = switch model.pill.state {
        case .listening, .handsFree, .recordingNote, .processing(_), .actionListening, .actionProcessing: true
        default: false
        }
        Image(nsImage: MenuBarGlyph.image(active: active, needsAttention: !model.permissions.allGranted))
            .accessibilityLabel(!model.permissions.allGranted ? "Hushy, permissions needed" : active ? "Hushy, listening" : "Hushy")
    }
}

enum MenuBarGlyph {
    /// The Wave-H at menu-bar size (handbook design/brand): five slots, 2 pt wide on a 3 pt pitch,
    /// heights in points on a 16 pt canvas. Resting is the mark itself: dots, stems, crossbar.
    private static let resting = draw(heights: [2, 14, 6, 14, 2])
    /// Listening: the same five slots, lit — the dots rise into bars and the crossbar grows. The
    /// silhouette change is what tells the states apart in a template image (no colour available).
    private static let listening = draw(heights: [6, 14, 10, 14, 6])
    private static let attention = draw(heights: [2, 14, 6, 14, 2], needsAttention: true)

    static func image(active: Bool, needsAttention: Bool = false) -> NSImage {
        needsAttention ? attention : active ? listening : resting
    }

    private static func draw(heights: [CGFloat], needsAttention: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2
            let pitch: CGFloat = 3
            let total = pitch * CGFloat(heights.count - 1) + barWidth
            var x = ((rect.width - total) / 2).rounded()
            NSColor.black.setFill()
            for height in heights {
                let bar = NSRect(x: x, y: ((rect.height - height) / 2).rounded(), width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                x += pitch
            }
            if needsAttention {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 7, height: 7)).fill()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12, y: 1, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Runs quit work for at most `limit`: whichever comes first, the work finishing or the limit, lets the quit go on.
@MainActor
enum QuitDeadline {
    static func run(within limit: Duration, _ work: @escaping @MainActor () async -> Void) async {
        final class Once {
            var continuation: CheckedContinuation<Void, Never>?
            func fire() {
                continuation?.resume()
                continuation = nil
            }
        }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.continuation = continuation
            Task { @MainActor in
                await work()
                once.fire()
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.fire()
            }
        }
    }
}
