import Foundation

/// One day's slice of the Home feed: every entry of the day (`all`), the subset Home shows
/// before the user asks for more (`capped`: every voice action and note, plus the day's newest
/// `cap` dictations), and the numbers the "Show N more" row and the earlier-day summary need.
/// Entries are newest first. Pure data, built by `HomeTimeline.select`.
public struct HomeDayEntries: Equatable, Sendable {
    /// Start of the day, in the calendar the selection was made with.
    public let day: Date
    /// "Today", "Yesterday", a weekday name (2 to 6 days back) or a short date.
    public let label: String
    public let dictationCount: Int
    public let actionCount: Int
    public let noteCount: Int
    public let all: [TimelineEntry]
    public let capped: [TimelineEntry]

    public init(
        day: Date, label: String, dictationCount: Int, actionCount: Int, noteCount: Int,
        all: [TimelineEntry], capped: [TimelineEntry]
    ) {
        self.day = day
        self.label = label
        self.dictationCount = dictationCount
        self.actionCount = actionCount
        self.noteCount = noteCount
        self.all = all
        self.capped = capped
    }

    /// Dictations left out of `capped`: what "Show N more" reveals.
    public var hiddenDictationCount: Int { all.count - capped.count }

    public func entries(showAll: Bool) -> [TimelineEntry] { showAll ? all : capped }

    /// "Yesterday · 14 dictations · 2 voice actions": the label plus each non-zero count.
    public var summary: String {
        let counts = [
            Self.counted(dictationCount, "dictation"),
            Self.counted(actionCount, "voice action"),
            Self.counted(noteCount, "note"),
        ].compactMap { $0 }
        return ([label] + counts).joined(separator: " · ")
    }

    private static func counted(_ count: Int, _ noun: String) -> String? {
        count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s")" : nil
    }
}

/// What Home shows: today, and the most recent earlier day that has anything in it.
public struct HomeTimelineSelection: Equatable, Sendable {
    public let today: HomeDayEntries
    /// `nil` when nothing is dated before today.
    public let earlier: HomeDayEntries?

    public init(today: HomeDayEntries, earlier: HomeDayEntries?) {
        self.today = today
        self.earlier = earlier
    }

    /// Today's entries as timeline groups, for the current expansion.
    public func todayGroups(expansion: HomeExpansion, calendar: Calendar) -> [TimelineGroup] {
        Timeline.groups(from: today.entries(showAll: expansion.showAllToday), calendar: calendar)
    }

    /// The earlier day's groups; empty while its row is collapsed (or there is no such day).
    public func earlierGroups(expansion: HomeExpansion, calendar: Calendar) -> [TimelineGroup] {
        guard let earlier, expansion.isEarlierOpen(todayIsEmpty: today.all.isEmpty) else { return [] }
        return Timeline.groups(from: earlier.entries(showAll: expansion.showAllEarlier), calendar: calendar)
    }

    /// Dictation ids in the order they appear on screen: the Quick Look arrow-key order.
    public func visibleDictationIDs(expansion: HomeExpansion, calendar: Calendar) -> [Int64] {
        QuickLookNavigation.dictationIDs(in: todayGroups(expansion: expansion, calendar: calendar))
            + QuickLookNavigation.dictationIDs(in: earlierGroups(expansion: expansion, calendar: calendar))
    }
}

public enum HomeTimeline {
    /// How many of a day's dictations Home shows before "Show N more".
    public static let dictationCap = 8

    /// Picks what Home shows. `now` and `calendar` come from the caller, so the day boundary is
    /// the caller's (and the tests') to choose. Entries dated after today are ignored.
    public static func select(
        dictations: [Dictation], notes: [Note], actions: [ActionRecord],
        now: Date, calendar: Calendar, cap: Int = dictationCap
    ) -> HomeTimelineSelection {
        let todayStart = calendar.startOfDay(for: now)
        var todayEntries: [TimelineEntry] = []
        var earlierEntries: [TimelineEntry] = []
        var earlierDay: Date?
        // Newest first, so the first day before today is the most recent one and everything
        // after its last entry is older still.
        for entry in Timeline.merge(dictations: dictations, notes: notes, actions: actions) {
            let day = calendar.startOfDay(for: entry.createdAt)
            if day > todayStart { continue }
            if day == todayStart {
                todayEntries.append(entry)
            } else if earlierDay == nil || earlierDay == day {
                earlierDay = day
                earlierEntries.append(entry)
            } else {
                break
            }
        }
        let today = dayEntries(todayEntries, day: todayStart, now: now, calendar: calendar, cap: cap)
        let earlier = earlierDay.map { dayEntries(earlierEntries, day: $0, now: now, calendar: calendar, cap: cap) }
        return HomeTimelineSelection(today: today, earlier: earlier)
    }

    private static func dayEntries(
        _ entries: [TimelineEntry], day: Date, now: Date, calendar: Calendar, cap: Int
    ) -> HomeDayEntries {
        var dictationCount = 0, actionCount = 0, noteCount = 0
        var capped: [TimelineEntry] = []
        for entry in entries {
            switch entry {
            case .dictation:
                dictationCount += 1
                if dictationCount <= max(cap, 0) { capped.append(entry) }
            case .note:
                noteCount += 1
                capped.append(entry)
            case .action:
                actionCount += 1
                capped.append(entry)
            }
        }
        return HomeDayEntries(
            day: day, label: dayLabel(day, now: now, calendar: calendar),
            dictationCount: dictationCount, actionCount: actionCount, noteCount: noteCount,
            all: entries, capped: capped)
    }

    /// "Today", "Yesterday", the weekday for 2 to 6 days back, otherwise a short date (with the
    /// year when it isn't this year).
    static func dayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
        let daysBack = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? 0
        switch daysBack {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return formatted(day, template: "EEEE", calendar: calendar)
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
            return formatted(day, template: sameYear ? "MMMd" : "MMMdy", calendar: calendar)
        }
    }

    private static func formatted(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
