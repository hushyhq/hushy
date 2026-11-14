import Foundation

/// Which of Home's expanders are open. It belongs to one calendar day: asking for it on another
/// day (`rolledOver(to:)`) gives a fresh, collapsed state, so yesterday's "Show 12 more" doesn't
/// carry into today. Value type with copy-on-change helpers; the view keeps one in `@State`.
public struct HomeExpansion: Equatable, Sendable {
    /// When today has nothing yet, show the most recent earlier day open instead of collapsed, so
    /// Home is never blank. One switch for the founder's call on the default (not yet decided).
    public static let earlierDayOpenWhenTodayEmpty = true

    /// Start of the day this state belongs to.
    public let day: Date
    public let showAllToday: Bool
    public let showAllEarlier: Bool
    /// The user's explicit choice for the earlier-day row; `nil` means "use the default".
    public let earlierDayOverride: Bool?

    public init(day: Date, showAllToday: Bool = false, showAllEarlier: Bool = false, earlierDayOverride: Bool? = nil) {
        self.day = day
        self.showAllToday = showAllToday
        self.showAllEarlier = showAllEarlier
        self.earlierDayOverride = earlierDayOverride
    }

    public func isEarlierOpen(todayIsEmpty: Bool) -> Bool {
        earlierDayOverride ?? (todayIsEmpty && Self.earlierDayOpenWhenTodayEmpty)
    }

    public func togglingShowAllToday() -> HomeExpansion {
        HomeExpansion(day: day, showAllToday: !showAllToday, showAllEarlier: showAllEarlier, earlierDayOverride: earlierDayOverride)
    }

    public func togglingShowAllEarlier() -> HomeExpansion {
        HomeExpansion(day: day, showAllToday: showAllToday, showAllEarlier: !showAllEarlier, earlierDayOverride: earlierDayOverride)
    }

    public func togglingEarlier(todayIsEmpty: Bool) -> HomeExpansion {
        HomeExpansion(
            day: day, showAllToday: showAllToday, showAllEarlier: showAllEarlier,
            earlierDayOverride: !isEarlierOpen(todayIsEmpty: todayIsEmpty))
    }

    /// This state if it is still for `day`, otherwise a fresh one for the new day.
    public func rolledOver(to newDay: Date) -> HomeExpansion {
        newDay == day ? self : HomeExpansion(day: newDay)
    }
}
