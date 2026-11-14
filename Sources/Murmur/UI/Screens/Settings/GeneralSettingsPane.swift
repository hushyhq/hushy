import AppKit
import MurmurCore
import SwiftUI

/// What most people ever change, six switches and pickers in two groups: how you start talking
/// (dictation key, microphone, language) and how Hushy sits on the Mac (launch at login, the pill:
/// Mini, Large or Hidden, sounds). Everything else lives in Privacy, Voice actions, Account, About or Advanced.
struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var launchAtLogin = false
    /// The Mac's inputs as last read: when the pane appears and when Hushy comes to the front.
    @State private var devices = MicrophoneSelector.Devices(inputs: [], systemDefault: nil)

    /// The copy won a blind two-judge comparison against longer and vaguer wordings (decision.tsv, 2026-11-04).
    static let hidePillTitle = "Hide the pill during video and full screen"
    static let hidePillDetail = "It hides, then comes back as soon as you start dictating."

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup {
                SettingsRow(title: "Dictation key", detail: "Double-tap to talk, Enter to paste. Or hold while you talk.", detailBelow: true) {
                    Picker("", selection: $settings.triggerKey) {
                        ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                if FeatureFlags.restyleSelection {
                    SettingsRow(title: RestyleCopy.shortcutSettingTitle, detail: RestyleCopy.shortcutSettingDetail, detailBelow: true) {
                        Picker("", selection: $settings.restyleShortcut) {
                            ForEach(RestyleShortcut.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
                MicrophoneSettingRow(
                    selection: $settings.inputDeviceName,
                    state: MicrophoneSettingState(
                        picked: settings.inputDeviceName, devices: isSnapshot ? .snapshot : devices))
                SettingsRow(
                    title: "Language",
                    detail: AppSettings.SpeechLanguageMode.settingsDetail,
                    showsDivider: false,
                    detailBelow: true
                ) {
                    Picker("", selection: $settings.speechLanguageMode) {
                        ForEach(AppSettings.SpeechLanguageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 190)
                }
            }

            SettingsGroup {
                SettingsRow(title: "Launch at login", detail: "So the dictation key is always ready.") {
                    SwitchToggle(isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, value in settings.launchAtLogin = value }
                }
                PillPresencePicker(
                    selection: Binding(get: { settings.pillPresence }, set: { settings.pillPresence = $0 }),
                    isLowPower: isSnapshot ? false : ProcessInfo.processInfo.isLowPowerModeEnabled)
                SettingsRow(title: Self.hidePillTitle, detail: Self.hidePillDetail) {
                    SwitchToggle(isOn: $settings.hideIdlePillDuringVideoOrFullScreen)
                }
                SettingsRow(title: "Sounds", detail: "Quiet ticks when listening starts and stops.", showsDivider: false) {
                    SwitchToggle(isOn: $settings.soundsEnabled)
                }
            }
        }
        .onAppear {
            launchAtLogin = model.settings.launchAtLogin
            readDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readDevices() }
    }

    /// A read of the device list, never a change. Stills use a fixed list instead.
    private func readDevices() {
        guard !isSnapshot else { return }
        devices = MicrophoneSelector.shared.probe()
    }
}
