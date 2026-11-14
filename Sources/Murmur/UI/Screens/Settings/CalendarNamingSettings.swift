import AppKit
import MurmurCore
import SwiftUI

/// "Name notes from your calendar": one row in Settings → Meetings. Turning it on is the only
/// thing that ever asks macOS for calendar access; after a refusal the row says where to allow it.
/// Self-contained like `CallDetectionSettings`, so the Meetings pane knows nothing about EventKit.
struct CalendarNamingSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var access = EventKitCalendarReader.currentAuthorization()

    var body: some View {
        CalendarNamingSettingsSection(
            isOn: Binding(
                get: { model.settings.nameNotesFromCalendar && access.canRead },
                set: { setOn($0) }),
            access: access, openSystemSettings: Permissions.openCalendarSettings)
            .onAppear(perform: refreshAccess)
            // Back from System Settings after allowing (or revoking) access.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshAccess()
            }
    }

    private func refreshAccess() {
        if !isSnapshot { access = EventKitCalendarReader.currentAuthorization() }
    }

    private func setOn(_ on: Bool) {
        guard on else {
            model.settings.nameNotesFromCalendar = false
            return
        }
        let reader = model.calendarReader
        Task {
            let outcome = await CalendarNamingSetting.turnOn(reader: reader)
            access = outcome.access
            model.settings.nameNotesFromCalendar = outcome.isOn
        }
    }
}

/// The row itself, driven by plain values so it renders the same in the app and in tests.
struct CalendarNamingSettingsSection: View {
    /// Reads as off whenever access cannot be read, whatever was stored.
    @Binding var isOn: Bool
    let access: CalendarAuthorization
    let openSystemSettings: () -> Void

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Name notes from your calendar", detail: CalendarNamingSetting.detail(for: access)) {
                HStack(spacing: 8) {
                    if CalendarNamingSetting.offersSystemSettings(for: access) {
                        Button("Open Settings…", action: openSystemSettings)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    SwitchToggle(isOn: $isOn)
                        .disabled(!access.canRead && !access.canPrompt)
                }
            }
        }
    }
}
