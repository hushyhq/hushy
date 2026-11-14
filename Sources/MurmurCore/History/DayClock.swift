import Foundation
import Observation

/// "What day is it" as observable state, so a screen that shows today's figures redraws when
/// the day changes instead of keeping yesterday's until something else happens to touch it.
///
/// It owns no timer. It listens for the system's own hints that the date may have moved (a
/// calendar-day change, wake from sleep, the app becoming active, a clock or time-zone change)
/// and re-reads the clock then. `now` is refreshed on every hint; `day` changes only when the
/// calendar day does, so views that key off `day` don't redraw needlessly. The app builds the
/// real one in one place (`AppModel.dayClock`); tests inject their own notification centre,
/// clock and calendar.
@MainActor
@Observable
public final class DayClock {
    /// A notification that means "the date may have changed".
    public struct Source {
        public let center: NotificationCenter
        public let name: Notification.Name

        public init(center: NotificationCenter, name: Notification.Name) {
            self.center = center
            self.name = name
        }
    }

    /// The instant of the last refresh.
    public private(set) var now: Date
    /// Start of the calendar day containing `now`.
    public private(set) var day: Date

    /// Called once each time the calendar day changes (after `day` has moved), so the app can
    /// refresh figures it computes elsewhere, such as the insights streak.
    @ObservationIgnored public var onDayChange: (() -> Void)?

    @ObservationIgnored private let readNow: () -> Date
    @ObservationIgnored private let readCalendar: () -> Calendar
    @ObservationIgnored nonisolated(unsafe) private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// The calendar to use for "today" figures: re-read on each call so a time-zone change counts.
    public var calendar: Calendar { readCalendar() }

    public init(
        sources: [Source],
        now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }
    ) {
        readNow = now
        readCalendar = calendar
        let current = now()
        self.now = current
        day = calendar().startOfDay(for: current)
        for source in sources {
            let token = source.center.addObserver(forName: source.name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append((source.center, token))
        }
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    /// Re-reads the clock and calendar.
    public func refresh() {
        now = readNow()
        let today = readCalendar().startOfDay(for: now)
        if today != day {
            day = today
            onDayChange?()
        }
    }
}
