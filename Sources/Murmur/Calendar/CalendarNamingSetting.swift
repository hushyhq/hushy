import MurmurCore

/// The rules behind Settings → Meetings → "Name notes from your calendar", kept out of the view so
/// they can be tested: when the toggle may ask macOS for access, and what the row says when access
/// is missing. Starting a recording never asks; only turning this on does.
enum CalendarNamingSetting {
    struct Outcome: Equatable {
        let isOn: Bool
        let access: CalendarAuthorization
    }

    /// Turning the setting on. Asks macOS only while it has never been asked (`canPrompt`); the toggle
    /// ends up on only if calendar access can actually be read.
    static func turnOn(reader: any CalendarReading) async -> Outcome {
        var access = await reader.authorization()
        if access.canPrompt { access = await reader.requestAccess() }
        return Outcome(isOn: access.canRead, access: access)
    }

    static func offersSystemSettings(for access: CalendarAuthorization) -> Bool {
        switch access {
        case .denied, .restricted, .writeOnly: true
        case .notDetermined, .fullAccess: false
        }
    }

    static func detail(for access: CalendarAuthorization) -> String {
        switch access {
        case .denied:
            "Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars."
        case .restricted:
            "This Mac restricts calendar access. If you can, allow Hushy in System Settings → Privacy & Security → Calendars."
        case .writeOnly:
            "Hushy has write-only calendar access. Choose Full Access in System Settings → Privacy & Security → Calendars."
        case .notDetermined, .fullAccess:
            "When you start a note during a meeting on your calendar, Hushy names it after the meeting. Your calendar is read on this Mac only."
        }
    }
}
