import Combine
import FluidAudio
import MurmurCore
import SwiftUI

/// Hushy's own Settings window (⌘,): a left sidebar of six panes (see `SettingsPane`) in its
/// own window/scene, not a section inside the main window. Each pane is its own file under
/// `UI/Screens/Settings/` and scrolls inside one fixed window size (founder, 2026-09-28: General
/// had grown past the screen and switching panes resized the window). Cross-pane concerns (the
/// "✓ Saved" flash, the retention/encryption confirmation alerts, the recovery key sheet, Tune)
/// live here since they're triggered from more than one pane or need to float above pane
/// switches.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPane: SettingsPane
    @State private var showTune = false
    /// Retention changes that would delete data wait here until confirmed.
    @State private var pendingRetention: PendingRetention?
    @State private var savedFlash = false
    @State private var confirmEncryptionChange: EncryptionChange?
    @State private var showRecoveryKey = false
    @State private var recoveryKeyCopied = false
    @State private var savedToICloudKeychain = false

    /// The fixed sidebar width and total window width, matching the Wispr-Flow reference layout.
    static let sidebarWidth: CGFloat = 220
    static let contentWidth: CGFloat = 560
    /// The window's one size: 780 wide, 640 tall — fits a 13" MacBook Air's visible screen with
    /// the menu bar and Dock. The user may drag it taller (to `maxHeight`) or a little shorter;
    /// the width never changes, so no pane ever reflows. `MurmurApp` and the snapshots read it.
    static let windowSize = CGSize(width: sidebarWidth + contentWidth, height: 640)
    private static let minHeight: CGFloat = 520
    private static let maxHeight: CGFloat = 900

    /// Also written directly by `Snapshots.renderSettingsPanes`, which needs to force a specific
    /// starting pane per capture without a live click — kept `internal` (not `private`) for that.
    static let lastPaneDefaultsKey = "settingsLastOpenPane"

    /// Posted with a `SettingsPane` object to switch an already-open Settings window to that
    /// pane (`AppModel.openAccountSettings`); a window created afterwards reads
    /// `lastPaneDefaultsKey` instead.
    static let selectPane = Notification.Name("app.hushy.settings.selectPane")

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.lastPaneDefaultsKey).flatMap(SettingsPane.init(savedValue:))
        // The preview pane is only there while its switch is on; a window reopened with it off
        // starts on General rather than on a pane that is not in the sidebar.
        _selectedPane = State(initialValue: saved.flatMap { $0 == .notesAndMeetings ? nil : $0 } ?? .general)
    }

    enum EncryptionChange: Identifiable {
        case enable, disable
        var id: Self { self }
    }

    struct PendingRetention: Identifiable {
        let id = UUID()
        let audioDays: Int?
        let textDays: Int?
        let dictations: Int
        let recordings: Int
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            paneColumn
        }
        .frame(width: Self.windowSize.width)
        .frame(minHeight: Self.minHeight, idealHeight: Self.windowSize.height, maxHeight: Self.maxHeight)
        .background(Theme.bgBase)
        // Centred on the main window however it was opened (⌘,, the app menu, the gear, "See
        // plans") — see `WindowPlacement`.
        .background(CenteredOnMainWindow())
        .sheet(isPresented: $showTune) { TuneView() }
        .onAppear { model.permissions.refresh() }
        .onChange(of: settingsFingerprint) { _, _ in flashSaved() }
        .onChange(of: selectedPane) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.lastPaneDefaultsKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.selectPane)) { notification in
            if let pane = notification.object as? SettingsPane { selectedPane = pane }
        }
        .alert(item: $pendingRetention) { pending in
            Alert(
                title: Text("Delete older dictations?"),
                message: Text(retentionMessage(pending)),
                primaryButton: .destructive(Text("Delete")) {
                    model.settings.textRetentionDays = pending.textDays
                    model.settings.audioRetentionDays = pending.audioDays
                },
                secondaryButton: .cancel(Text("Keep them")))
        }
        .alert(item: $confirmEncryptionChange) { change in
            switch change {
            case .enable:
                Alert(
                    title: Text("Encrypt recordings on this Mac?"),
                    message: Text("Every saved audio recording will be encrypted with a key stored in your login Keychain. Transcripts and notes stay protected by FileVault and are not encrypted by Hushy yet. This can take a moment for a large history. You'll be shown a one-time recovery key afterward — save it somewhere safe: losing both the Keychain item and the recovery key means this data can't be recovered."),
                    primaryButton: .default(Text("Encrypt")) { Task { await model.encryption.enable(); showRecoveryKey = true } },
                    secondaryButton: .cancel())
            case .disable:
                Alert(
                    title: Text("Turn off encryption?"),
                    message: Text("Every saved recording will be decrypted back to plain files. Your existing recovery key will no longer work once this finishes."),
                    primaryButton: .destructive(Text("Decrypt")) { Task { await model.encryption.disable() } },
                    secondaryButton: .cancel())
            }
        }
        .sheet(isPresented: $showRecoveryKey) { RecoveryKeySheet(model: model, copied: $recoveryKeyCopied, savedToICloud: $savedToICloudKeychain) }
    }

    /// The pane, scrolling inside the window. Each pane gets its own scroll view (`.id`), so it
    /// opens at its top and the switch is a short cross-fade with a 6 pt rise — opacity and
    /// transform only, nothing reflows — or a plain fade under Reduce Motion.
    private var paneColumn: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical) {
                SettingsPaneContent(
                    pane: selectedPane, needsAttentionBadge: needsAttentionBadge, savedFlash: savedFlash,
                    showTune: $showTune, confirmEncryptionChange: $confirmEncryptionChange,
                    showRecoveryKey: $showRecoveryKey, retentionBinding: retentionBindingFactory)
                    .frame(width: Self.contentWidth, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .id(selectedPane)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)),
                removal: .opacity))
        }
        .frame(width: Self.contentWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .animation(Theme.Motion.spatial(Theme.Motion.snappy, reduceMotion: reduceMotion), value: selectedPane)
    }

    private var sidebar: some View {
        SettingsSidebar(
            panes: SettingsPane.visible(showsNotesAndMeetings: model.settings.notesAndMeetingsPreview),
            selected: selectedPane, needsAttentionBadge: needsAttentionBadge
        ) { selectedPane = $0 }
    }

    private var needsAttentionBadge: Bool {
        !model.permissions.allGranted || (Permissions.globeKeyAction.conflicts && model.settings.triggerKey == .fn)
    }

    /// `PrivacySettingsPane` and `AdvancedSettingsPane` call back into this to run the "would this delete
    /// something?" check before committing a retention change, since the confirmation alert
    /// lives here (shared, not per-pane, so it can float above pane switches).
    private func retentionBindingFactory(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int?>) -> Binding<Int?> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var audio = model.settings.audioRetentionDays
                var text = model.settings.textRetentionDays
                if keyPath == \AppSettings.audioRetentionDays { audio = newValue } else { text = newValue }
                let impact = (try? model.store.retentionImpact(audioDays: audio, textDays: text))
                    ?? (dictations: 0, recordings: 0)
                let current = (try? model.store.retentionImpact(
                    audioDays: model.settings.audioRetentionDays, textDays: model.settings.textRetentionDays))
                    ?? (dictations: 0, recordings: 0)
                if impact.dictations > current.dictations || impact.recordings > current.recordings {
                    pendingRetention = PendingRetention(audioDays: audio, textDays: text,
                                                        dictations: impact.dictations, recordings: impact.recordings)
                } else {
                    model.settings[keyPath: keyPath] = newValue
                }
            })
    }

    private func retentionMessage(_ pending: PendingRetention) -> String {
        var parts: [String] = []
        if pending.dictations > 0 { parts.append("\(pending.dictations) dictation\(pending.dictations == 1 ? "" : "s")") }
        if pending.recordings > 0 { parts.append("\(pending.recordings) saved recording\(pending.recordings == 1 ? "" : "s")") }
        return "This removes \(parts.joined(separator: " and ")) from this Mac. It can't be undone. Notes are not affected."
    }

    /// Changes apply instantly (the Mac convention); a brief "Saved" confirms each one.
    private var settingsFingerprint: String {
        let s = model.settings
        return "\(s.triggerKey)|\(s.toneSettings.fingerprint)|\(s.soundsEnabled)|\(s.showIdlePill)|\(String(describing: s.audioRetentionDays))|\(String(describing: s.textRetentionDays))|\(String(describing: s.inputDeviceName))|\(s.exportNotesToMarkdown)|\(s.saveNotesToAppleNotes)|\(s.speechLanguageMode)|\(s.userName)|\(s.appearance)|\(s.appLockEnabled)|\(s.appLockAutoLockMinutes)"
    }

    private func flashSaved() {
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { savedFlash = false }
    }
}

/// One pane's content: serif title + "Saved" flash, the permissions banner when something needs
/// attention, then the pane itself — laid out flat; the live window wraps it in a scroll view
/// (`SettingsView.paneColumn`) and snapshots render it whole.
///
/// A standalone view (not a method on `SettingsView`) so `Snapshots.renderSettingsPanes` can
/// render one pane directly at a time, the same way it captures Voice Lab/Tune — wrapping this
/// in a live sidebar selection for a snapshot crashes `ImageRenderer` for AppKit-backed
/// interaction machinery, since off-screen rendering never provides a live window/scene update
/// transaction.
struct SettingsPaneContent: View {
    let pane: SettingsPane
    let needsAttentionBadge: Bool
    let savedFlash: Bool
    @Binding var showTune: Bool
    @Binding var confirmEncryptionChange: SettingsView.EncryptionChange?
    @Binding var showRecoveryKey: Bool
    let retentionBinding: (ReferenceWritableKeyPath<AppSettings, Int?>) -> Binding<Int?>

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(alignment: .firstTextBaseline) {
                Text(pane.title).font(Theme.Font.section).foregroundStyle(Theme.textPrimary)
                Spacer()
                Label("Saved", systemImage: "checkmark")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.success)
                    .opacity(savedFlash ? 1 : 0)
                    .animation(Theme.fade, value: savedFlash)
                    .accessibilityHidden(!savedFlash)
            }

            if pane == .general, needsAttentionBadge { PermissionsCard() }

            switch pane {
            case .general: GeneralSettingsPane()
            case .privacy: PrivacySettingsPane(retentionBinding: retentionBinding)
            case .voiceActions: VoiceActionsSettingsPane()
            case .notesAndMeetings: NotesAndMeetingsSettingsPane(showTune: $showTune)
            case .account: AccountSettingsPane()
            case .about: AboutSettingsPane()
            case .advanced:
                AdvancedSettingsPane(
                    showTune: $showTune, retentionBinding: retentionBinding,
                    confirmEncryptionChange: $confirmEncryptionChange, showRecoveryKey: $showRecoveryKey)
            #if DEBUG
            case .developer: DeveloperSettingsPane()
            #endif
            }
        }
        .padding(Theme.Space.xxl)
    }
}

/// Sidebar + one pane's content, for `Snapshots.renderSettingsPanes` — shows the real window
/// shape (not just the content column) without needing `SettingsView`'s live `@State` selection,
/// which off-screen `ImageRenderer` rendering can't drive interactively anyway. A fixed pane
/// (not a live selection) is all a static capture needs.
struct SettingsSnapshotPage: View {
    @Environment(AppModel.self) private var model
    let pane: SettingsPane
    let needsAttentionBadge: Bool
    let retentionBinding: (ReferenceWritableKeyPath<AppSettings, Int?>) -> Binding<Int?>

    var body: some View {
        // Top-aligned so the sidebar starts at the top when the page is clipped at the window's
        // height (`settings-<pane>-window`), where the pane content is taller than the clip.
        HStack(alignment: .top, spacing: 0) {
            SettingsSidebar(
                panes: SettingsPane.visible(showsNotesAndMeetings: model.settings.notesAndMeetingsPreview || pane == .notesAndMeetings),
                selected: pane, needsAttentionBadge: needsAttentionBadge) { _ in }

            Divider()

            SettingsPaneContent(
                pane: pane, needsAttentionBadge: needsAttentionBadge, savedFlash: false,
                showTune: .constant(false), confirmEncryptionChange: .constant(nil),
                showRecoveryKey: .constant(false), retentionBinding: retentionBinding)
                .frame(width: SettingsView.contentWidth, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Theme.bgBase)
    }
}
