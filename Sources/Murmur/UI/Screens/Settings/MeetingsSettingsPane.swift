import AppKit
import MurmurCore
import SwiftUI

/// Everything about turning a recorded call/meeting into a note: capturing the other side of
/// the call, where notes are mirrored to, and (once wired up) automatic call detection.
struct MeetingsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotAppleNotesResult) private var snapshotResult
    @State private var systemAudioPermission = SystemAudioCapture.permissionState()
    /// Turning "Also save notes to Apple Notes" on checks access first; it stays off, with a
    /// notice saying why, unless access was granted.
    @State private var notes = AppleNotesToggle()

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup {
                SettingsRow(title: "Record call audio", detail: recordCallAudioDetail) {
                    HStack(spacing: 8) {
                        if systemAudioPermission == .denied || systemAudioPermission == .unsupported {
                            Button("Open Settings…", action: Permissions.openScreenRecordingSettings)
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        SwitchToggle(isOn: $settings.recordCallAudio)
                            .disabled(systemAudioPermission == .unsupported)
                    }
                }

            }

            CallDetectionSettings()

            CalendarNamingSettings()

            SettingsGroup {
                SettingsRow(title: "Also save notes to Apple Notes", detail: "Into a “Hushy” folder, so they sync to your iPhone. macOS asks once for permission.") {
                    SwitchToggle(isOn: Binding(
                        get: { settings.saveNotesToAppleNotes || snapshotResult == .granted },
                        set: { setSaveToAppleNotes($0) }))
                }
                if let shown = snapshotResult ?? notes.problem, !shown.isGranted {
                    AppleNotesAccessNotice(result: shown) { setSaveToAppleNotes(true) }
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                }
                SettingsRow(title: "Export notes as Markdown", detail: settings.exportDirectory.path) {
                    HStack {
                        Button("Change…", action: chooseFolder).buttonStyle(SecondaryButtonStyle())
                        SwitchToggle(isOn: $settings.exportNotesToMarkdown)
                    }
                }
            }
        }
        .onAppear { systemAudioPermission = SystemAudioCapture.permissionState() }
    }

    /// Explains what "Record call audio" does and, when it can't work right now, why — matching
    /// the task's contract to "handle permission request/denial gracefully (clear message + link
    /// to System Settings; never change settings yourself)". The toggle itself stays interactive
    /// even when permission is missing (macOS prompts for Screen Recording the first time a note
    /// actually tries to capture), except when the OS feature itself is unsupported.
    private var recordCallAudioDetail: String {
        systemAudioPermission.userMessage
            ?? "Captures the other side of your calls (Zoom, FaceTime, any app) alongside your mic, labelled as separate speakers."
    }

    /// Never runs the script in snapshot mode, so a render can't trigger the Automation prompt.
    private func setSaveToAppleNotes(_ on: Bool) {
        guard !isSnapshot else { return }
        notes.turn(on) { model.settings.saveNotesToAppleNotes = $0 }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.settings.exportDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.exportDirectory = url
        }
    }
}
