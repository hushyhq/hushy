import AppKit
import MurmurCore

extension DayClock {
    /// The app's one clock: refreshed when the calendar day rolls over, the Mac wakes, the app
    /// becomes active, the system clock is set, or the time zone changes. `AppModel` owns the
    /// only instance; every screen that shows "today" reads `now`, `day` and `calendar` from it.
    @MainActor
    static func system() -> DayClock {
        DayClock(
            sources: [
                Source(center: .default, name: .NSCalendarDayChanged),
                Source(center: .default, name: .NSSystemClockDidChange),
                Source(center: .default, name: .NSSystemTimeZoneDidChange),
                Source(center: .default, name: NSApplication.didBecomeActiveNotification),
                Source(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification),
            ],
            now: { Date() },
            calendar: { Calendar.autoupdatingCurrent })
    }
}
