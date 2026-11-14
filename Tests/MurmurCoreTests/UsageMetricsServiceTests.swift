import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: collection service", .timeLimit(.minutes(1)))
struct UsageMetricsServiceTests {
    typealias F = UsageMetricsFixtures

    private func makeService(
        isOn: Bool = true, environment: MetricsEnvironment? = F.environment
    ) throws -> (UsageMetricsService, MetricsSwitch, URL) {
        let directory = try F.tempDirectory()
        let gate = MetricsSwitch(isOn: isOn)
        let service = UsageMetricsService(
            directory: directory, appBuild: 412, firstRunDay: try MetricsDay(year: 2026, month: 9, day: 1),
            environment: environment, timeZone: { F.utc.timeZone }, gate: gate, makeBatchID: F.sequentialIDs())
        return (service, gate, directory)
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private let dictation = MetricEvent.dictation(F.dictation())

    @Test("with the switch off, nothing is recorded, nothing is queued and nothing touches the disk")
    func offRecordsNothing() async throws {
        let (service, _, directory) = try makeService(isOn: false)
        await service.record(dictation, at: F.noonOct3)
        await service.record(.funnel(.firstDictation), at: F.noonOct3)
        #expect(await service.closeDays(now: F.noonOct5) == 0)
        #expect(await service.previewToday(now: F.noonOct3) == nil)
        #expect(try await service.queue.pendingCount() == 0)
        #expect(files(in: directory).isEmpty)
    }

    @Test("with the switch on, an event is journalled and the next day's close queues one batch with retention")
    func onRecordsAndCloses() async throws {
        let (service, _, directory) = try makeService()
        await service.record(dictation, at: F.noonOct3)
        await service.record(dictation, at: F.noonOct3.addingTimeInterval(60))
        #expect(files(in: service.directory).contains(UsageMetricsService.journalName))
        #expect(await service.closeDays(now: F.noonOct3) == 0)               // the day has not elapsed
        #expect(await service.closeDays(now: F.noonOct4) == 1)
        let queued = try await service.queue.nextBatchesToSend(limit: 10, now: F.noonOct4)
        let batch = try #require(queued.first)
        #expect(queued.count == 1)
        #expect(batch.combinedDictations.count == 2)
        #expect(batch.retention == (try MetricsRetention(daysSinceFirstRun: .days30to89, activeDaysLast7: 1)))
        #expect(batch.appBuild == 412)
        // The closed day left the journal.
        #expect(await service.closeDays(now: F.noonOct5) == 0)
    }

    @Test("an event recorded on an open day stays in the journal across a close")
    func openDayStays() async throws {
        let (service, _, _) = try makeService()
        await service.record(dictation, at: F.noonOct3)
        await service.record(dictation, at: F.noonOct4)
        #expect(await service.closeDays(now: F.noonOct4.addingTimeInterval(60)) == 1)   // Oct 3 closes, Oct 4 stays
        #expect(await service.closeDays(now: F.noonOct5) == 1)                           // then Oct 4 closes
    }

    @Test("active days survive a restart: a second service on the same folder counts the earlier days")
    func activeDaysSurviveRestart() async throws {
        let (first, gate, directory) = try makeService()
        await first.record(dictation, at: F.noonOct3)
        await first.record(dictation, at: F.noonOct4)
        let restarted = UsageMetricsService(
            directory: directory, appBuild: 412, firstRunDay: try MetricsDay(year: 2026, month: 9, day: 1),
            environment: F.environment, timeZone: { F.utc.timeZone }, gate: gate, makeBatchID: F.sequentialIDs())
        #expect(await restarted.closeDays(now: F.noonOct5) == 2)
        let batches = try await restarted.queue.nextBatchesToSend(limit: 10, now: F.noonOct5)
        #expect(batches.compactMap(\.retention?.activeDaysLast7).sorted() == [1, 2])
    }

    @Test("turning the switch off makes the earlier numbers unreachable at once; tidying then deletes them")
    func offMakesEverythingUnreachable() async throws {
        let (service, gate, directory) = try makeService()
        await service.record(dictation, at: F.noonOct3)
        #expect(await service.closeDays(now: F.noonOct4) == 1)
        await service.record(dictation, at: F.noonOct4)
        try Data("{}".utf8).write(to: service.directory.appendingPathComponent(UsageMetricsService.uploadStateName))
        #expect(try await service.queue.pendingCount() == 1)
        let before = service.directory
        gate.isOn = false
        gate.isOn = true                                   // straight back on: a new, empty folder
        #expect(service.directory != before)
        #expect(try await service.queue.pendingCount() == 0)   // before any deletion ran
        #expect(await service.previewToday(now: F.noonOct4.addingTimeInterval(60)) == nil)
        service.collectGarbage()
        #expect(!FileManager.default.fileExists(atPath: before.path))
        #expect(files(in: directory).isEmpty)
    }

    @Test("turning it back on starts fresh: earlier days and events are gone")
    func onAgainStartsFresh() async throws {
        let (service, gate, _) = try makeService()
        await service.record(dictation, at: F.noonOct3)
        gate.isOn = false
        gate.isOn = true
        await service.record(dictation, at: F.noonOct4)
        #expect(await service.closeDays(now: F.noonOct5) == 1)
        let batch = try #require(try await service.queue.nextBatchesToSend(limit: 10, now: F.noonOct5).first)
        #expect(batch.day.isoString == "2026-10-04")
        #expect(batch.retention?.activeDaysLast7 == 1)
    }

    @Test("a close racing a switch-off leaves nothing queued")
    func closeAfterOffQueuesNothing() async throws {
        let (service, gate, _) = try makeService()
        await service.record(dictation, at: F.noonOct3)
        gate.isOn = false
        #expect(await service.closeDays(now: F.noonOct5) == 0)
        #expect(try await service.queue.pendingCount() == 0)
    }

    @Test("today's preview shows only today's events and is never queued")
    func previewToday() async throws {
        let (service, _, _) = try makeService()
        await service.record(dictation, at: F.noonOct3)
        await service.record(dictation, at: F.noonOct4)
        await service.record(.funnel(.firstDictation), at: F.noonOct4)
        let preview = try #require(await service.previewToday(now: F.noonOct4.addingTimeInterval(120)))
        #expect(preview.day.isoString == "2026-10-04")
        #expect(preview.combinedDictations.count == 1)
        #expect(preview.funnel.total == 1)
        #expect(try await service.queue.pendingCount() == 0)
        #expect(await service.previewToday(now: F.noonOct5) == nil)
    }

    @Test("without a readable environment no batch is built and nothing throws")
    func noEnvironment() async throws {
        let (service, _, _) = try makeService(environment: nil)
        await service.record(dictation, at: F.noonOct3)
        #expect(await service.closeDays(now: F.noonOct5) == 0)
    }

    @Test("a failing disk never throws or crashes: the record is dropped")
    func failingDiskIsHarmless() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-metrics-block-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)                       // a file where the folder should be
        defer { try? FileManager.default.removeItem(at: blocker) }
        let service = UsageMetricsService(
            directory: blocker, appBuild: 412, firstRunDay: nil, environment: F.environment, timeZone: { F.utc.timeZone },
            gate: MetricsSwitch(isOn: true))
        await service.record(dictation, at: F.noonOct3)
        #expect(await service.closeDays(now: F.noonOct5) == 0)
        service.collectGarbage()
    }

    @Test("the journal on disk holds numbers and enum names only: no free text")
    func journalHoldsNoText() async throws {
        let (service, _, directory) = try makeService()
        await service.record(.meeting(MeetingMetricEvent(outcome: .completed, minutesRecorded: 30)), at: F.noonOct3)
        await service.record(dictation, at: F.noonOct3)
        let text = try String(contentsOf: service.directory.appendingPathComponent(UsageMetricsService.journalName), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["day", "appBuild", "event"])
        }
    }

    @Test("an event read back from a damaged journal is clamped, and unreadable lines are skipped")
    func damagedJournal() async throws {
        let (service, _, directory) = try makeService()
        await service.record(.meeting(MeetingMetricEvent(outcome: .completed, minutesRecorded: 30)), at: F.noonOct3)
        let url = service.directory.appendingPathComponent(UsageMetricsService.journalName)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"minutesRecorded\":30", with: "\"minutesRecorded\":9999999") + "not json\n"
        try Data(text.utf8).write(to: url)
        #expect(await service.closeDays(now: F.noonOct5) == 1)
        let batch = try #require(try await service.queue.nextBatchesToSend(limit: 1, now: F.noonOct5).first)
        #expect(batch.meetings.minutesRecorded == MetricsLimits.maximumMeetingMinutes)
    }
}
