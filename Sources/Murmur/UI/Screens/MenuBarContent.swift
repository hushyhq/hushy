import MurmurCore
import SwiftUI

/// Menu words shared by the menu bar and the Dictate menu, so a test can read them.
enum MenuBarCopy {
    static let dictateMenu = "Dictate"
    static let startHandsFree = "Start hands-free"
    static let stopHandsFree = "Stop hands-free"
    static let dictateKey = "Dictate key"
    static let allowAccessibility = "Allow Accessibility…"
    static let allowMicrophone = "Allow Microphone…"

    /// The menu bar's status line. A note in progress is the one thing readiness does not know
    /// about; every other line is `DictationReadinessStatus.text`, the same words as the sidebar.
    static func statusLine(recordingNote: Bool, readiness: DictationReadinessStatus) -> String {
        recordingNote ? "Recording a note…" : readiness.text
    }

    /// Stop stays available while hands-free is running. Start waits until dictation can work.
    static func handsFreeEnabled(isBusy: Bool, readiness: DictationReadinessStatus) -> Bool {
        isBusy || readiness.kind == .ready
    }
}

/// Shared by the live menu and its snapshot: the repair action must stay the first item.
struct MenuBarPermissionItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.permissions.accessibility != .granted {
            Button(MenuBarCopy.allowAccessibility) { model.runReadinessFix(.requestAccessibility) }
        }
        if model.permissions.microphone != .granted {
            Button(MenuBarCopy.allowMicrophone) { model.runReadinessFix(.requestMicrophone) }
        }
        if !model.permissions.allGranted { Divider() }
    }
}

/// The native menu under the menu bar icon, modelled on the system's own menus.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var settings = model.settings

        let readiness = model.dictationReadiness()

        MenuBarPermissionItems()

        Text(MenuBarCopy.statusLine(recordingNote: model.recorder.isRecording, readiness: readiness))

        Button(model.dictation.isBusy ? MenuBarCopy.stopHandsFree : MenuBarCopy.startHandsFree) {
            model.dictation.toggleHandsFree()
        }
        .disabled(!MenuBarCopy.handsFreeEnabled(isBusy: model.dictation.isBusy, readiness: readiness))

        if FeatureFlags.meetings {
            Button(model.recorder.isRecording ? "Stop Recording Note" : "Record a Note") {
                model.toggleNoteRecording()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        Button("Open Hushy") { open(.home) }
        Button("History…") { open(.history) }

        Divider()

        // Neither is offered while the app lock is on: both hand over dictated words.
        let canUseLast = LockedCopy.canUseLastTranscript(
            hasTranscript: model.library.dictations.contains { $0.status != .cancelled },
            isLocked: model.appLock.isLocked)
        Button("Paste Last Transcript") { model.dictation.pasteLast() }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(!canUseLast)
        Button("Copy Last Transcript") { model.dictation.copyLast() }
            .keyboardShortcut("c", modifiers: [.control, .command])
            .disabled(!canUseLast)

        Divider()

        // Automatic first, with the microphone it resolves to now; read as the menu opens.
        let microphones = MicrophoneSettingState(
            picked: settings.inputDeviceName, devices: MicrophoneSelector.shared.probe())
        Picker("Microphone", selection: $settings.inputDeviceName) {
            Text(microphones.automaticLabel).tag(String?.none)
            ForEach(microphones.entries) { Text($0.label).tag(Optional($0.name)) }
        }

        Picker("Tone", selection: $settings.toneSettings.choice) {
            ForEach(ToneChoice.allCases) { Text($0.title).tag($0) }
        }

        Picker(MenuBarCopy.dictateKey, selection: $settings.triggerKey) {
            ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
        }

        Toggle("Show Pill When Idle", isOn: $settings.showIdlePill)

        Divider()

        // One entry point for the Assistant: the main window's right pane, beside whatever
        // section is showing (the same thing the sidebar's Assistant row does). Connecting
        // outside AI apps lives in Settings → AI connections.
        if FeatureFlags.meetings {
            Button("Assistant…") {
                model.showAssistant(hasRoom: nil)
                model.openMainWindow()
            }
        }
        Button("Settings…") { model.openSettingsWindow() }
            .keyboardShortcut(",", modifiers: .command)
        // A small window, not a sheet: a menu cannot present one.
        Button(FeedbackCopy.menuItem) {
            openWindow(id: FeedbackSheet.windowID)
            NSApp.activate()
        }

        Divider()

        Button("Quit Hushy") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
            .onAppear {
                model.openWindowHandler = { openWindow(id: "main") }
                model.openSettingsHandler = { openSettings() }
            }
    }

    private func open(_ section: AppModel.Section) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}
