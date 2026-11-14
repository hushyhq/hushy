import MurmurCore
import SwiftUI

/// Settings people open rarely, in one pane: tuning Hushy to your voice, the clipboard choice,
/// how long audio is kept, recording encryption, letting AI apps read Hushy, and the switch that
/// brings back the frozen Notes and meetings settings. The Assistant chat settings are here too,
/// but only for someone who already turned the Assistant on or is previewing notes and meetings.
///
/// The encryption confirmations (alert and recovery-key sheet) are owned by `SettingsView`,
/// which needs them to float above pane switches. Encryption rows only show when
/// `FeatureFlags.recordingEncryption` is on (see `.claude/DECISIONS.md`) or it is already
/// enabled on this machine.
struct AdvancedSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Binding var showTune: Bool
    let retentionBinding: (ReferenceWritableKeyPath<AppSettings, Int?>) -> Binding<Int?>
    @Binding var confirmEncryptionChange: SettingsView.EncryptionChange?
    @Binding var showRecoveryKey: Bool

    private var showsEncryption: Bool { FeatureFlags.recordingEncryption || model.encryption.isEnabled }

    /// Parked, so it is hidden unless it is already on (someone must be able to turn it off) or the
    /// preview is.
    private var showsAssistant: Bool {
        FeatureFlags.meetings && (model.assistant.isEnabled || model.settings.notesAndMeetingsPreview)
    }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup {
                SettingsRow(
                    title: "Tune Hushy to your voice",
                    detail: model.settings.voiceCalibration == nil
                        ? TuneCopy.settingsRowDetail
                        : "Last tuned \(model.settings.voiceCalibration!.calibratedAt.formatted(date: .abbreviated, time: .omitted))."
                ) {
                    Button("Tune →") { showTune = true }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsRow(
                    title: "Keep dictations on the clipboard",
                    detail: "What you said stays on the clipboard after a paste, so ⌘V pastes it again. Off: your earlier clipboard comes back."
                ) {
                    SwitchToggle(isOn: $settings.keepDictationsOnClipboard)
                        .accessibilityLabel("Keep dictations on the clipboard")
                }
                SettingsRow(title: "Keep dictation audio", detail: "For replay and retry from History.", showsDivider: showsEncryption) {
                    Picker("", selection: retentionBinding(\.audioRetentionDays)) {
                        Text("Don't keep").tag(Int?.some(0))
                        Text("1 day").tag(Int?.some(1))
                        Text("7 days").tag(Int?.some(7))
                        Text("30 days").tag(Int?.some(30))
                        Text("Forever").tag(Int?.none)
                    }
                    .labelsHidden().frame(width: 140)
                }
                if showsEncryption { encryptionRows }
            }

            AIAppsSettingsSection(showsAssistant: showsAssistant)

            if showsAssistant { AssistantSettingsSection() }

            if FeatureFlags.meetings {
                SettingsGroup {
                    SettingsRow(
                        title: "Notes and meetings (preview)",
                        detail: "Adds the Notes & meetings settings to this window. Recording calls into notes is not finished.",
                        showsDivider: false
                    ) {
                        SwitchToggle(isOn: $settings.notesAndMeetingsPreview)
                            .accessibilityLabel("Notes and meetings (preview)")
                    }
                }
            }
        }
    }

    @ViewBuilder private var encryptionRows: some View {
        SettingsRow(
            title: "Encrypt recordings on this Mac",
            detail: encryptionDetail,
            showsDivider: model.encryption.isEnabled
        ) {
            if case .running(let progress) = model.encryption.migrationState {
                HStack(spacing: 8) {
                    ProgressView(value: progress.filesTotal > 0 ? Double(progress.filesDone) / Double(progress.filesTotal) : 0)
                        .frame(width: 90)
                    Text("\(progress.filesDone)/\(progress.filesTotal)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            } else {
                SwitchToggle(isOn: encryptionToggleBinding)
            }
        }
        if model.encryption.isEnabled {
            SettingsRow(title: "Recovery key", detail: "Shown once. Save it somewhere safe: losing both this and Keychain access means your data can't be recovered.", showsDivider: false) {
                Button("Show…") { showRecoveryKey = true }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var encryptionToggleBinding: Binding<Bool> {
        Binding(
            get: { model.encryption.isEnabled },
            set: { newValue in confirmEncryptionChange = newValue ? .enable : .disable })
    }

    private var encryptionDetail: String {
        switch model.encryption.migrationState {
        case .running: "Encrypting your saved recordings…"
        case .failed(let message): "Last attempt failed: \(message)"
        case .idle:
            model.encryption.isEnabled
                ? "Recordings on disk are encrypted with a key in your login Keychain."
                : "Recordings are stored as plain files on this Mac's disk."
        }
    }
}
