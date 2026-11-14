import Foundation
import Testing
@testable import MurmurCore

/// Covers the History header's whole-history aggregates: `Store.appDictationCounts` (the app
/// chips, including "All apps · N") and `Store.dictationDayActivity` (the week strip). Uses an
/// in-memory store, never the user's real database.
@Suite("Store app counts and day activity")
struct StoreAppCountsTests {
    private func save(_ store: Store, app: String?, name: String?, at date: Date, status: Dictation.Status = .inserted) throws {
        _ = try store.save(Dictation(
            createdAt: date, rawText: "x", text: status == .inserted ? "x" : "",
            appBundleID: app, appName: name, durationSeconds: 1, status: status))
    }

    @Test("counts every app across the whole table, most-used first, skipping rows with no app")
    func countsAllApps() throws {
        let store = try Store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<3 { try save(store, app: "com.anthropic.claude", name: "Claude", at: base.addingTimeInterval(Double(index))) }
        try save(store, app: "com.mitchellh.ghostty", name: "Ghostty", at: base)
        try save(store, app: nil, name: nil, at: base)

        let counts = try store.appDictationCounts()
        #expect(counts.map(\.bundleID) == ["com.anthropic.claude", "com.mitchellh.ghostty"])
        #expect(counts.map(\.count) == [3, 1])
    }

    @Test("an app's display name is the one on its newest dictation")
    func newestNameWins() throws {
        let store = try Store()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try save(store, app: "com.example.app", name: "Old Name", at: base)
        try save(store, app: "com.example.app", name: "New Name", at: base.addingTimeInterval(60))

        #expect(try store.appDictationCounts().first?.appName == "New Name")
    }

    @Test("empty history has no apps")
    func emptyHistory() throws {
        #expect(try Store().appDictationCounts().isEmpty)
    }

    @Test("day activity buckets by local day and counts anything not inserted as needing attention")
    func dayActivity() throws {
        let store = try Store()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        try save(store, app: nil, name: nil, at: today.addingTimeInterval(3600))
        try save(store, app: nil, name: nil, at: today.addingTimeInterval(7200), status: .failed)
        try save(store, app: nil, name: nil, at: yesterday.addingTimeInterval(60))
        try save(store, app: nil, name: nil, at: tomorrow.addingTimeInterval(60)) // outside the window

        let activity = try store.dictationDayActivity(start: yesterday, end: tomorrow, calendar: calendar)
        #expect(activity.entries == [today: 2, yesterday: 1])
        #expect(activity.attention == [today: 1])
    }
}
