import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Cross-meeting memory (Ask, People and Companies, the prep brief) is unreachable unless a test
/// build turns it on; what one meeting records and the commitments across meetings stay.
@MainActor
@Suite("Cross-meeting Ask hidden for launch")
struct MeetingAskHiddenTests {
    private func model(memory: Bool?) async throws -> (MeetingsModel, now: Date) {
        let store = try Store()
        let now = Date()
        MeetingFixtures.seed(into: store, now: now)
        let suite = "app.hushy.test.meeting-ask.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let meetings = MeetingsModel(
            store: store, settings: AppSettings(defaults: defaults),
            calendar: StaticCalendarReader(events: [MeetingFixtures.upcoming(now: now)]),
            reminders: FakeCalendarBackend())
        if let memory { meetings.crossMeetingMemory = memory }
        await meetings.refreshOverview(now: now)
        return (meetings, now)
    }

    @Test("a default model has no way to ask, no people and no prep brief")
    func hiddenByDefault() async throws {
        let (meetings, now) = try await model(memory: nil)
        #expect(!meetings.crossMeetingMemory)
        meetings.question = "What did we decide with Dana about the pilot?"
        await meetings.ask(now: now)
        #expect(meetings.answer == nil)
        #expect(meetings.overview.people.isEmpty)
        #expect(meetings.overview.companies.isEmpty)
        #expect(meetings.overview.prep == nil)
    }

    @Test("what each meeting records still reaches the overview")
    func commitmentsRemain() async throws {
        let (meetings, _) = try await model(memory: nil)
        #expect(meetings.overview.upcoming != nil)
        #expect(!(meetings.overview.commitments.iOwe.isEmpty && meetings.overview.commitments.owedToMe.isEmpty))
    }

    @Test("a test build that turns it on gets answers, people and the prep brief")
    func onWhenEnabled() async throws {
        let (meetings, now) = try await model(memory: true)
        meetings.question = "What did we decide with Dana about the pilot?"
        await meetings.ask(now: now)
        #expect(meetings.answer != nil)
        #expect(!meetings.overview.people.isEmpty)
        #expect(meetings.overview.prep != nil)
    }
}
