import MurmurCore
import SwiftUI

/// Settings → Meetings → "Name notes from your calendar" in its three states, driven by plain
/// values: off before access is asked, on with access, and blocked with the System Settings hint.
/// Never touches EventKit, so snapshot mode neither prompts nor reads a calendar.
extension Snapshots {
    static func renderCalendarNaming(scheme: ColorScheme, directory: URL) async {
        let states: [(String, Bool, CalendarAuthorization)] = [
            ("off", false, .notDetermined),
            ("on", true, .fullAccess),
            ("blocked", false, .denied),
        ]
        for (name, isOn, access) in states {
            let section = CalendarNamingSettingsSection(
                isOn: .constant(isOn && access.canRead), access: access, openSystemSettings: {})
            await capture(
                section.padding(24), name: "settings-calendar-naming-\(name)", scheme: scheme,
                size: CGSize(width: 640, height: 160), directory: directory, fixedSize: true)
        }
    }
}
