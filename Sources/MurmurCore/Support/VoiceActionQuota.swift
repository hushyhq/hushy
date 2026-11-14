import Foundation

/// The Free plan's voice-action allowance: 100 completed chord uses per calendar month, counted in
/// the user's local calendar — (founder, 2026-09-28: "assign 100
/// voice actions in free mode and then lock it"). Pure: the count comes from
/// `Store.voiceActionsThisMonth` (one `VoiceActionUse` row per use that did something); this type
/// only turns "now + a count" into a status the pill, Settings and the gate act on.
///
/// What counts: one per chord use that *did something* — a Tier-1 action that ran, a confirm card
/// the user confirmed (once, however many rows), an answer shown, an AI hand-off opened. Cancels,
/// esc, errors, refusals, "not an action" fallbacks and the practice in Settings never count, and an
/// action the user Undoes gives its use back (`Store.markVoiceActionUseUndone`). Pro is unlimited.
public enum VoiceActionQuota {
    /// Voice actions per calendar month on the Free plan.
    public static let freeMonthlyLimit = 100

    /// From this many used on, the pill shows a quiet "N left this month" hint after a use.
    public static let headsUpFrom = 90

    public struct Status: Equatable, Sendable {
        public let used: Int
        public let limit: Int
        /// The calendar month the count covers; `month.end` is when the allowance resets.
        public let month: DateInterval

        public var remaining: Int { max(0, limit - used) }
        public var isExhausted: Bool { used >= limit }
        /// `used >= headsUpFrom` and not yet exhausted.
        public var isNearLimit: Bool { used >= VoiceActionQuota.headsUpFrom && !isExhausted }
        public var resetsOn: Date { month.end }
    }

    /// The local calendar month containing `now` (`[start of month, start of next month)`).
    public static func monthInterval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: now)
            ?? DateInterval(start: now, duration: 31 * 86_400)
    }

    public static func status(
        now: Date, calendar: Calendar = .current, usedThisMonth: Int, limit: Int = freeMonthlyLimit
    ) -> Status {
        Status(used: max(0, usedThisMonth), limit: limit, month: VoiceActionQuota.monthInterval(containing: now, calendar: calendar))
    }

    /// Whether one more voice action may run given `usedThisMonth` already counted. The 100th
    /// runs (99 used); the 101st doesn't (100 used).
    public static func canUse(usedThisMonth: Int, limit: Int = freeMonthlyLimit) -> Bool {
        usedThisMonth < limit
    }
}
