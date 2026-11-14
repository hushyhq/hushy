import MurmurCore
import SwiftUI

/// Settings → Voice actions · beta: the action key and a "Practice" row that opens the rehearsal
/// onboarding used to run (`VoiceActionRehearsalView`, which also lists what you can say), then
/// `ActionPolicy`'s "Ask before doing" and Apple Notes search. Voice actions are free and have no
/// monthly allowance (founder, 2026-11-11).
struct VoiceActionsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotActionTriggerClash) private var snapshotClash
    @State private var showPractice = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup {
                SettingsRow(title: "Action key", detail: Self.triggerDetail(model.settings.effectiveActionTrigger)) {
                    Picker("", selection: $settings.actionTrigger) {
                        ForEach(ActionTriggerKey.choices(dictation: settings.triggerKey)) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                }
                ForEach(triggerNotes, id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.warning)
                        Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if note == Self.clashNote(for: model.settings.effectiveActionTrigger) {
                            Button("Keyboard settings") { Permissions.openKeyboardSettings() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                }
                SettingsRow(title: VoiceActionRehearsal.settingsRowTitle, detail: VoiceActionRehearsal.settingsRowDetail, showsDivider: false) {
                    Button("Practice") { showPractice = true }.buttonStyle(SecondaryButtonStyle())
                }
            }

            if FeatureFlags.taskHandoff {
                SettingsGroup(title: "Background AI tasks") {
                    SettingsRow(title: "Tasks", detail: "Review waiting, running and completed Codex tasks.") {
                        Button("Open tasks") { model.openMainWindow(); model.handoff.openList() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }

            VoiceActionsSettingsSection(askBeforeDoing: $settings.askBeforeDoing, searchAppleNotes: $settings.searchAppleNotes)
        }
        .sheet(isPresented: $showPractice) {
            VoiceActionRehearsalView.sheetContent(onDone: { showPractice = false })
        }
    }

    /// Notes under the key row: the choice fell back because it is the dictation key, and macOS
    /// Dictation listening for the same double press.
    private var triggerNotes: [String] {
        let chosen = model.settings.actionTrigger
        let effective = model.settings.effectiveActionTrigger
        var notes: [String] = []
        if chosen != effective {
            notes.append("\(chosen.title.replacingOccurrences(of: ", twice", with: "")) is your dictation key, so voice actions use \(effective.phrase).")
        }
        if snapshotClash ?? Permissions.macDictationClashes(with: effective) { notes.append(Self.clashNote(for: effective)) }
        return notes
    }

    /// Both action gestures and the cancellation gesture, using the configured action key.
    static func triggerDetail(_ key: ActionTriggerKey) -> String {
        "Tap \(key.keyCap) twice to talk, once more to cancel."
    }

    static func clashNote(for key: ActionTriggerKey) -> String {
        "macOS Dictation also starts when you press \(key.phrase). Change its shortcut in Keyboard settings, or choose another key here, or both will start."
    }
}

/// The two policy rows: "Ask before doing" (the `ActionPolicy` setting) and whether "ask about
/// your own stuff" may search Apple Notes. Self-contained — it only needs the two bindings.
struct VoiceActionsSettingsSection: View {
    @Binding var askBeforeDoing: ActionPolicy.AskBeforeDoing
    @Binding var searchAppleNotes: Bool
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotAppleNotesResult) private var snapshotResult
    /// Turning Apple Notes on checks access first (`AppleNotesToggle`); it stays off, with a
    /// notice saying why, unless access was granted.
    @State private var notes = AppleNotesToggle()

    var body: some View {
        SettingsGroup {
            SettingsRow(
                title: "Ask before doing",
                detail: detail
            ) {
                Picker("", selection: $askBeforeDoing) {
                    ForEach(ActionPolicy.AskBeforeDoing.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 190)
            }
            SettingsRow(
                title: "Search Apple Notes",
                detail: "Lets “what groceries do I need” look in Apple Notes too, on this Mac. macOS asks once for permission."
            ) {
                SwitchToggle(isOn: Binding(
                    get: { searchAppleNotes || snapshotResult == .granted },
                    set: { setSearchAppleNotes($0) }))
            }
            if let shown = snapshotResult ?? notes.problem, !shown.isGranted {
                AppleNotesAccessNotice(result: shown) { setSearchAppleNotes(true) }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            }
        }
    }

    /// Never runs the script in snapshot mode, so a render can't trigger the Automation prompt.
    private func setSearchAppleNotes(_ on: Bool) {
        guard !isSnapshot else { return }
        notes.turn(on) { searchAppleNotes = $0 }
    }

    private var detail: String {
        switch askBeforeDoing {
        case .always:
            "Every action shows a card first."
        case .risky:
            "Reminders and links happen at once, with Undo. Messages and Shortcuts ask first."
        case .never:
            "Hushy acts without asking. Messages and Shortcuts still need your tap."
        }
    }
}
