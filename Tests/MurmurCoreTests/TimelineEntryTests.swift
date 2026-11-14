import Foundation
import Testing
@testable import MurmurCore

@Suite("Timeline merge and grouping")
struct TimelineEntryTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func dictation(_ id: Int64, offset: TimeInterval, app: String? = "com.a", appName: String? = "App A") -> Dictation {
        Dictation(id: id, createdAt: Self.base.addingTimeInterval(offset), rawText: "hi", text: "Hi.",
                  appBundleID: app, appName: appName, durationSeconds: 1)
    }

    private func note(_ id: Int64, offset: TimeInterval) -> Note {
        Note(id: id, title: "Note", createdAt: Self.base.addingTimeInterval(offset), updatedAt: Self.base.addingTimeInterval(offset),
             durationSeconds: 30, transcript: "t", summary: "s", status: .ready)
    }

    private func action(_ id: Int64, offset: TimeInterval) -> ActionRecord {
        ActionRecord(id: id, createdAt: Self.base.addingTimeInterval(offset), kind: .createEvent, title: "Dentist", sourceText: "book dentist")
    }

    @Test("merge sorts dictations, notes and actions newest first")
    func mergeSortsNewestFirst() {
        let entries = Timeline.merge(
            dictations: [dictation(1, offset: 0)],
            notes: [note(1, offset: 60)],
            actions: [action(1, offset: 120)])
        #expect(entries.map(\.createdAt) == entries.map(\.createdAt).sorted(by: >))
        #expect(entries.first?.id == "a1")
    }

    @Test("a dictation entry's id matches id(forDictation:), so selection by dictation id finds it")
    func dictationIDHelperMatchesEntryID() {
        #expect(TimelineEntry.dictation(dictation(42, offset: 0)).id == TimelineEntry.id(forDictation: 42))
        #expect(TimelineEntry.id(forDictation: 42) != TimelineEntry.note(note(42, offset: 0)).id)
    }

    @Test("groups break on app change, matching HistoryGrouping")
    func groupsBreakOnAppChange() {
        let entries: [TimelineEntry] = [
            .dictation(dictation(1, offset: 0, app: "com.a")),
            .dictation(dictation(2, offset: 60, app: "com.a")),
            .dictation(dictation(3, offset: 120, app: "com.b")),
        ]
        let groups = Timeline.groups(from: entries)
        #expect(groups.count == 2)
        #expect(groups[0].appBundleID == "com.a")
        #expect(groups[0].entries.count == 2)
        #expect(groups[1].appBundleID == "com.b")
    }

    @Test("groups break across a day boundary even with no gap otherwise")
    func groupsBreakOnDayChange() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let entries: [TimelineEntry] = [
            .dictation(Dictation(id: 1, createdAt: yesterday.addingTimeInterval(3600), rawText: "a", text: "a", appBundleID: "com.a", durationSeconds: 1)),
            .dictation(Dictation(id: 2, createdAt: today.addingTimeInterval(3600), rawText: "b", text: "b", appBundleID: "com.a", durationSeconds: 1)),
        ]
        let groups = Timeline.groups(from: entries)
        #expect(groups.count == 2)
        #expect(groups[0].day != groups[1].day)
    }

    @Test("a note and an action group under the Hushy fallback app")
    func noteAndActionUseHushyFallback() {
        let entries: [TimelineEntry] = [.note(note(1, offset: 0)), .action(action(1, offset: -60))]
        let groups = Timeline.groups(from: entries)
        #expect(groups.count == 1)
        #expect(groups[0].appName == "Hushy")
    }

    @Test("a gap over 30 minutes breaks a group even for the same app")
    func gapBreaksGroup() {
        let entries: [TimelineEntry] = [
            .dictation(dictation(1, offset: 0, app: "com.a")),
            .dictation(dictation(2, offset: -1_900, app: "com.a")),
        ]
        let groups = Timeline.groups(from: entries)
        #expect(groups.count == 2)
    }
}
