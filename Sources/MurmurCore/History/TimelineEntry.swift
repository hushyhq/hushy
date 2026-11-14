import Foundation

/// One row in the shared Home/History timeline: a dictation, a note, or a voice action
/// (calendar/reminder/shortcut), unified so both screens can group and render them with the
/// same component (see `.claude/DECISIONS.md`, "shared timeline"). Pure data — no SwiftUI —
/// so the merge/group/chip logic here is unit-testable from MurmurCore alone.
public enum TimelineEntry: Identifiable, Equatable, Sendable {
    case dictation(Dictation)
    case note(Note)
    case action(ActionRecord)

    public var id: String {
        switch self {
        case .dictation(let item): Self.id(forDictation: item.id ?? 0)
        case .note(let item): "n\(item.id ?? 0)"
        case .action(let item): "a\(item.id ?? 0)"
        }
    }

    /// The `id` a dictation entry with this row id has — lets a view match a selected dictation
    /// id against timeline entries without rebuilding an entry.
    public static func id(forDictation dictationID: Int64) -> String { "d\(dictationID)" }

    public var createdAt: Date {
        switch self {
        case .dictation(let item): item.createdAt
        case .note(let item): item.createdAt
        case .action(let item): item.createdAt
        }
    }

    /// The app an entry is attributed to for grouping/header purposes. Actions and notes have
    /// no source app of their own today, so they group under a synthetic "Hushy" bucket — still
    /// broken into a new group by the day/gap rules below, just without a real bundle id.
    public var appBundleID: String? {
        switch self {
        case .dictation(let item): item.appBundleID
        case .note, .action: nil
        }
    }

    public var appName: String? {
        switch self {
        case .dictation(let item): item.appName
        case .note, .action: "Hushy"
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .dictation(let item): item.needsAttention
        case .note(let item): item.status == .failed
        case .action(let item): item.status == .failed || item.status == .uncertain
        }
    }
}

extension TimelineEntry: HistoryGroupable {
    public var groupID: Int64 {
        switch self {
        case .dictation(let item): item.id ?? 0
        case .note(let item): -(item.id ?? 0) - 1 // disjoint id space from dictations
        case .action(let item): (item.id ?? 0) << 32 | 1 // disjoint from both
        }
    }

    public var groupCreatedAt: Date { createdAt }
    public var groupAppBundleID: String? { appBundleID }
}

/// One header-plus-entries group in the timeline: a run of entries under a single app icon
/// (or the "Hushy" fallback for notes/actions) within one calendar day, broken by app change,
/// day change, or a >30-minute gap — reusing `HistoryGrouping`'s exact break rule so History and
/// Home never disagree on where a new group starts.
public struct TimelineGroup: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let day: Date
    public let appBundleID: String?
    public let appName: String?
    public let entries: [TimelineEntry]

    public init(day: Date, appBundleID: String?, appName: String?, entries: [TimelineEntry]) {
        self.id = entries.first?.groupID ?? 0
        self.day = day
        self.appBundleID = appBundleID
        self.appName = appName
        self.entries = entries
    }
}

/// Pure merge + group logic for the shared timeline. Kept entirely separate from
/// `HistoryPager`'s pagination concerns: this operates on an already-loaded, newest-first slice
/// of entries (a page, or "today's" items) and produces day-grouped, app-grouped output.
public enum Timeline {
    /// Merges dictations, notes and actions into one newest-first list of entries.
    public static func merge(dictations: [Dictation], notes: [Note] = [], actions: [ActionRecord] = []) -> [TimelineEntry] {
        var entries: [TimelineEntry] = dictations.map(TimelineEntry.dictation)
        entries += notes.map(TimelineEntry.note)
        entries += actions.map(TimelineEntry.action)
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Groups already-merged, newest-first entries into per-day sections of app-runs, using
    /// `HistoryGrouping`'s break rule (app change, or a gap over `maxGap`) within each day.
    public static func groups(
        from entries: [TimelineEntry], calendar: Calendar = .current, maxGap: TimeInterval = HistoryGrouping.defaultMaxGap
    ) -> [TimelineGroup] {
        var dayOrder: [Date] = []
        var byDay: [Date: [TimelineEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if byDay[day] == nil { dayOrder.append(day) }
            byDay[day, default: []].append(entry)
        }

        var result: [TimelineGroup] = []
        for day in dayOrder {
            let dayEntries = byDay[day] ?? []
            let runs = HistoryGrouping.runs(from: dayEntries, maxGap: maxGap)
            for run in runs {
                result.append(TimelineGroup(day: day, appBundleID: run.appBundleID, appName: run.items.first?.appName, entries: run.items))
            }
        }
        return result
    }
}
