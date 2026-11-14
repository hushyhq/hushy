import MurmurCore
import SwiftUI

/// Snapshot-only: the data and expander state Home renders instead of the library's, so the
/// capped, expanded and earlier-day states can be captured from synthetic fixtures at a fixed
/// moment. `HomeView` reads it from the environment (see `snapshotHomeFeed`).
struct SnapshotHomeFeed {
    let dictations: [Dictation]
    let notes: [Note]
    let actions: [ActionRecord]
    let now: Date
    let calendar: Calendar
    let expansion: HomeExpansion

    var selection: HomeTimelineSelection {
        HomeTimeline.select(dictations: dictations, notes: notes, actions: actions, now: now, calendar: calendar)
    }
}

extension EnvironmentValues {
    @Entry var snapshotHomeFeed: SnapshotHomeFeed?
}

extension Snapshots {
    /// Quick Look order for the live library as Home shows it right now, with every expander
    /// collapsed: what the `home-quicklook` capture steps through.
    @MainActor
    static func homeQuickLookOrder(library: Library, clock: DayClock) -> [Int64] {
        let selection = HomeTimeline.select(
            dictations: library.dictations, notes: library.notes, actions: library.actionRecords,
            now: clock.now, calendar: clock.calendar)
        return selection.visibleDictationIDs(expansion: HomeExpansion(day: clock.day), calendar: clock.calendar)
    }

    /// Home with Today capped, expanded and empty, and the earlier-day row closed and open.
    /// Fixed moment (Monday 5 Oct 2026, 3:30 pm) and invented text only.
    @MainActor
    static func renderHomeStates(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: HomeFixtures.now(calendar))
        let fresh = HomeExpansion(day: day)
        let few = HomeFixtures.feed(calendar: calendar, today: .few, expansion: fresh)
        let many = HomeFixtures.feed(calendar: calendar, today: .many, expansion: fresh)
        let states: [(String, SnapshotHomeFeed)] = [
            ("home-today-few", few),
            ("home-today-capped", many),
            ("home-today-expanded", many.withExpansion(fresh.togglingShowAllToday())),
            ("home-today-empty", HomeFixtures.feed(calendar: calendar, today: .none, expansion: fresh)),
            ("home-earlier-open", few.withExpansion(fresh.togglingEarlier(todayIsEmpty: false))),
        ]
        model.section = .home
        // Taller than a page: the feed is the point, and `ImageRenderer` can't scroll to it.
        let tall = CGSize(width: size.width, height: 2000)
        for (name, feed) in states {
            await capture(
                MainView().environment(model).environment(\.snapshotHomeFeed, feed),
                name: name, scheme: scheme, size: tall, directory: directory)
        }
    }
}

private extension SnapshotHomeFeed {
    func withExpansion(_ expansion: HomeExpansion) -> SnapshotHomeFeed {
        SnapshotHomeFeed(
            dictations: dictations, notes: notes, actions: actions, now: now, calendar: calendar,
            expansion: expansion)
    }
}

/// Shared with `Snapshots+HomeHistory.swift`, which adds the dictation card's states.
enum HomeFixtures {
    enum Today { case none, few, many }

    private static let phrases = [
        "Moving the review to Thursday afternoon.", "Can you send the revised budget before noon?",
        "Thanks, that works for me.", "Let's keep the draft short and add the chart.",
        "I'll follow up with the vendor tomorrow.", "Please check the spelling of the client's name.",
        "The numbers look right, ship it.", "Remind me to renew the parking permit.",
        "We should cut the second section.", "Sounds good, see you at the stand-up.",
    ]

    private static let apps: [(id: String, name: String)] = [
        ("com.apple.mail", "Mail"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.Notes", "Notes"), ("com.apple.Safari", "Safari"),
    ]

    /// Monday 5 October 2026, 3:30 pm in the caller's calendar.
    static func now(_ calendar: Calendar) -> Date {
        at(calendar, day: 5, hour: 15, minute: 30)
    }

    static func feed(calendar: Calendar, today: Today, expansion: HomeExpansion) -> SnapshotHomeFeed {
        var dictations: [Dictation] = []
        var actions: [ActionRecord] = []
        var notes: [Note] = []
        let lastToday = at(calendar, day: 5, hour: 15, minute: 12)
        switch today {
        case .none:
            break
        case .few:
            dictations += run(count: 3, latest: lastToday, firstID: 1, app: apps[0], spacing: 4)
            dictations += run(count: 2, latest: at(calendar, day: 5, hour: 13, minute: 20), firstID: 4, app: apps[1], spacing: 3)
            actions.append(action(1, at(calendar, day: 5, hour: 14, minute: 5), "Dentist", "Tomorrow · 3:00 PM"))
            notes.append(note(1, at(calendar, day: 5, hour: 9, minute: 40), "Planning sketch"))
        case .many:
            for (index, app) in [apps[0], apps[1], apps[2], apps[3], apps[0]].enumerated() {
                let latest = lastToday.addingTimeInterval(-Double(index) * 55 * 60)
                dictations += run(count: 5, latest: latest, firstID: Int64(1 + index * 5), app: app, spacing: 3)
            }
            actions.append(action(1, at(calendar, day: 5, hour: 14, minute: 5), "Dentist", "Tomorrow · 3:00 PM"))
            actions.append(action(2, at(calendar, day: 5, hour: 11, minute: 15), "Call the plumber", "Wednesday · 9:00 AM"))
        }
        dictations += run(count: 14, latest: at(calendar, day: 4, hour: 17, minute: 40), firstID: 100, app: apps[1], spacing: 6)
        actions.append(action(10, at(calendar, day: 4, hour: 12, minute: 0), "Team lunch", "Friday · 12:30 PM"))
        actions.append(action(11, at(calendar, day: 4, hour: 9, minute: 30), "Pay the invoice", "Today · 5:00 PM"))
        return SnapshotHomeFeed(
            dictations: dictations, notes: notes, actions: actions, now: now(calendar), calendar: calendar,
            expansion: expansion)
    }

    private static func at(_ calendar: Calendar, day: Int, hour: Int, minute: Int) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 10, day: day, hour: hour, minute: minute).date
            ?? Date(timeIntervalSince1970: 0)
    }

    /// `count` consecutive dictations in one app, newest at `latest`, `spacing` minutes apart.
    private static func run(count: Int, latest: Date, firstID: Int64, app: (id: String, name: String), spacing: Double) -> [Dictation] {
        (0..<count).map { index in
            let text = phrases[(Int(firstID) + index) % phrases.count]
            return Dictation(
                id: firstID + Int64(index), createdAt: latest.addingTimeInterval(-spacing * 60 * Double(index)),
                rawText: text.lowercased(), text: text, appBundleID: app.id, appName: app.name,
                durationSeconds: 3 + Double(index % 4), status: .inserted)
        }
    }

    private static func action(_ id: Int64, _ date: Date, _ title: String, _ detail: String) -> ActionRecord {
        ActionRecord(
            id: id, createdAt: date, kind: .createEvent, title: title, detail: detail, sourceText: title,
            status: .completed)
    }

    private static func note(_ id: Int64, _ date: Date, _ title: String) -> Note {
        Note(id: id, title: title, createdAt: date, updatedAt: date, status: .ready)
    }
}
