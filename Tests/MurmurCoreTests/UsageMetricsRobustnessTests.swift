import Foundation
import Testing
@testable import MurmurCore

/// Crashes, switch-off races, damaged files and clock changes for usage numbers.
@Suite("Usage metrics: robustness", .timeLimit(.minutes(1)))
struct UsageMetricsRobustnessTests {
    typealias F = UsageMetricsFixtures

    private final class ZoneBox: @unchecked Sendable {
        private let lock = NSLock()
        private var zone: TimeZone
        init(_ zone: TimeZone) { self.zone = zone }
        var current: TimeZone { lock.withLock { zone } }
        func set(_ new: TimeZone) { lock.withLock { zone = new } }
    }

    private func service(
        in directory: URL, gate: MetricsSwitch, zone: ZoneBox = ZoneBox(F.utc.timeZone)
    ) -> UsageMetricsService {
        UsageMetricsService(
            directory: directory, appBuild: 412, firstRunDay: nil, environment: F.environment,
            timeZone: { zone.current }, gate: gate)
    }

    private let dictation = MetricEvent.dictation(F.dictation())

    // MARK: crash window

    @Test("a crash after queueing but before the journal is rewritten rebuilds the same batch, not a second one")
    func crashWindowDoesNotDoubleCount() async throws {
        let directory = try F.tempDirectory()
        let gate = MetricsSwitch(isOn: true)
        let first = service(in: directory, gate: gate)
        await first.record(dictation, at: F.noonOct3)
        await first.record(dictation, at: F.noonOct3)
        // The crash: the rewrite of the journal fails, after the IDs were saved and the batch queued.
        let journal = first.directory.appendingPathComponent(UsageMetricsService.journalName)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: journal.path)
        #expect(await first.closeDays(now: F.noonOct4) == 0)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: journal.path)
        let queuedBefore = try await first.queue.nextBatchesToSend(limit: 10, now: F.noonOct4)
        let originalID = try #require(queuedBefore.first?.batchID)
        #expect(queuedBefore.count == 1)
        #expect(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent(UsageMetricsService.batchIDsName).path))
        // Recovery after a restart: the same day closes again.
        let restarted = service(in: directory, gate: gate)
        #expect(await restarted.closeDays(now: F.noonOct4.addingTimeInterval(60)) == 1)
        let after = try await restarted.queue.nextBatchesToSend(limit: 10, now: F.noonOct4)
        #expect(after.count == 1)
        #expect(after.first?.batchID == originalID)
        #expect(after.first?.combinedDictations.count == 2)
        #expect(await restarted.closeDays(now: F.noonOct5) == 0)       // and the day has left the journal for good
    }

    @Test("IDs are saved before the batch is queued, and dropped once the journal no longer holds the day")
    func idsLifecycle() async throws {
        let directory = try F.tempDirectory()
        let gate = MetricsSwitch(isOn: true)
        let svc = service(in: directory, gate: gate)
        await svc.record(dictation, at: F.noonOct3)
        #expect(await svc.closeDays(now: F.noonOct4) == 1)
        #expect(!FileManager.default.fileExists(atPath: svc.directory.appendingPathComponent(UsageMetricsService.batchIDsName).path))
    }

    // MARK: switch off

    @Test("switching off cancels the request in flight, and a late answer changes nothing")
    func inFlightIsCancelled() async throws {
        let directory = try F.tempDirectory()
        let queue = MetricsBatchQueue(directory: directory)
        try await queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let gate = MetricsSwitch(isOn: true)
        let transport = HangingTransport()
        let uploader = MetricsUploader(
            queue: queue, stateURL: directory.appendingPathComponent("upload-state.json"), transport: transport,
            endpoint: URL(string: "https://metrics.example.com/b"), gate: gate, timeZone: { F.utc.timeZone })
        let run = Task { await uploader.uploadIfDue(now: F.noonOct5) }
        for _ in 0..<200 where !transport.started { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.started)
        gate.isOn = false                                   // the person switches sharing off mid-request
        let report = await run.value
        #expect(transport.wasCancelled)
        #expect(report.accepted == 0)
        #expect(try await queue.pendingCount() == 1)        // not acknowledged: the wipe deletes it
    }

    @Test("two runs of one uploader overlap: switching off cancels both requests, not only the newer one")
    func overlappingRunsAreBothCancelled() async throws {
        let directory = try F.tempDirectory()
        let queue = MetricsBatchQueue(directory: directory)
        try await queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let gate = MetricsSwitch(isOn: true)
        let transport = HangingTransport()
        let uploader = MetricsUploader(
            queue: queue, stateURL: directory.appendingPathComponent("upload-state.json"), transport: transport,
            endpoint: URL(string: "https://metrics.example.com/b"), gate: gate, timeZone: { F.utc.timeZone })
        let first = Task { await uploader.uploadIfDue(now: F.noonOct5) }
        for _ in 0..<200 where transport.starts < 1 { try await Task.sleep(for: .milliseconds(10)) }
        // The actor lets a second run in while the first awaits its request: a day later, the batch is due again.
        let second = Task { await uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(86_400)) }
        for _ in 0..<200 where transport.starts < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.starts == 2)
        gate.isOn = false
        let reports = [await first.value, await second.value]
        #expect(transport.cancellations == 2)
        #expect(reports.map(\.accepted) == [0, 0])
        #expect(try await queue.pendingCount() == 1)
    }

    @Test("a request is never started after the switch is off")
    func noStartAfterOff() async throws {
        let directory = try F.tempDirectory()
        let queue = MetricsBatchQueue(directory: directory)
        try await queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let gate = MetricsSwitch(isOn: false)
        let transport = FakeMetricsTransport()
        let uploader = MetricsUploader(
            queue: queue, stateURL: directory.appendingPathComponent("upload-state.json"), transport: transport,
            endpoint: URL(string: "https://metrics.example.com/b"), gate: gate, timeZone: { F.utc.timeZone })
        _ = await uploader.uploadIfDue(now: F.noonOct5)
        #expect(transport.calls.isEmpty)
    }

    // MARK: damaged upload state

    @Test("a damaged upload-state file reads as 'already ran today': no extra send, then it recovers tomorrow")
    func corruptStateCannotCauseExtraSend() async throws {
        let directory = try F.tempDirectory()
        let queue = MetricsBatchQueue(directory: directory)
        try await queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let stateURL = directory.appendingPathComponent("upload-state.json")
        try Data("{ not json".utf8).write(to: stateURL)
        let transport = FakeMetricsTransport()
        let uploader = MetricsUploader(
            queue: queue, stateURL: stateURL, transport: transport, endpoint: URL(string: "https://metrics.example.com/b"),
            gate: MetricsSwitch(isOn: true), timeZone: { F.utc.timeZone })
        #expect(await uploader.uploadIfDue(now: F.noonOct5).skipped == .alreadyRanToday)
        #expect(transport.calls.isEmpty)
        #expect(await uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(86_400)).accepted == 1)
    }

    @Test("a clock set back never allows a second run on an earlier day")
    func clockRollbackNoExtraRun() async throws {
        let directory = try F.tempDirectory()
        let queue = MetricsBatchQueue(directory: directory)
        try await queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let transport = FakeMetricsTransport([.retryLater])
        let uploader = MetricsUploader(
            queue: queue, stateURL: directory.appendingPathComponent("upload-state.json"), transport: transport,
            endpoint: URL(string: "https://metrics.example.com/b"), gate: MetricsSwitch(isOn: true), timeZone: { F.utc.timeZone })
        _ = await uploader.uploadIfDue(now: F.noonOct5)
        #expect(await uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(-3 * 86_400)).skipped == .alreadyRanToday)
        #expect(transport.calls.count == 1)
    }

    @Test("upload state is written atomically: no temporary file is left and the file always decodes")
    func stateWriteIsAtomic() async throws {
        let directory = try F.tempDirectory()
        let queue = MetricsBatchQueue(directory: directory)
        try await queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let stateURL = directory.appendingPathComponent("upload-state.json")
        let uploader = MetricsUploader(
            queue: queue, stateURL: stateURL, transport: FakeMetricsTransport([.retryLater]),
            endpoint: URL(string: "https://metrics.example.com/b"), gate: MetricsSwitch(isOn: true), timeZone: { F.utc.timeZone })
        _ = await uploader.uploadIfDue(now: F.noonOct5)
        #expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))) != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    // MARK: days

    @Test("an event keeps the day it had when it happened, whatever the time zone becomes later")
    func timeZoneChange() async throws {
        let directory = try F.tempDirectory()
        let gate = MetricsSwitch(isOn: true)
        let zone = ZoneBox(F.utc.timeZone)
        let first = service(in: directory, gate: gate, zone: zone)
        await first.record(dictation, at: F.noonOct3)                 // Oct 3 in UTC
        zone.set(try #require(TimeZone(identifier: "Pacific/Auckland")))
        await first.record(dictation, at: F.noonOct3)                 // 01:00 on Oct 4 in Auckland
        let honolulu = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        let restarted = service(in: directory, gate: gate, zone: ZoneBox(honolulu))
        #expect(await restarted.closeDays(now: F.noonOct5.addingTimeInterval(2 * 86_400)) == 2)
        let days = try await restarted.queue.nextBatchesToSend(limit: 10, now: F.noonOct5).map(\.day.isoString).sorted()
        #expect(days == ["2026-10-03", "2026-10-04"])
    }

    @Test("a clock set back never reopens a closed day: the event lands on the next open day")
    func clockRollbackDoesNotReopen() async throws {
        let directory = try F.tempDirectory()
        let svc = service(in: directory, gate: MetricsSwitch(isOn: true))
        await svc.record(dictation, at: F.noonOct3)
        #expect(await svc.closeDays(now: F.noonOct4) == 1)           // Oct 3 closed
        await svc.record(dictation, at: F.noonOct3)                  // the clock now says Oct 3 again
        #expect(await svc.closeDays(now: F.noonOct3) == 0)           // still "Oct 3": nothing closes
        #expect(await svc.closeDays(now: F.noonOct5) == 1)
        let batches = try await svc.queue.nextBatchesToSend(limit: 10, now: F.noonOct5)
        #expect(batches.map(\.day.isoString).sorted() == ["2026-10-03", "2026-10-04"])
    }

    @Test("the journal holds a day and no time of day")
    func journalIsDayOnly() async throws {
        let directory = try F.tempDirectory()
        let svc = service(in: directory, gate: MetricsSwitch(isOn: true))
        await svc.record(dictation, at: F.noonOct3.addingTimeInterval(1_234))
        let text = try String(contentsOf: svc.directory.appendingPathComponent(UsageMetricsService.journalName), encoding: .utf8)
        #expect(text.contains("\"day\":\"2026-10-03\""))
        #expect(!text.contains("occurredAt"))
    }

    // MARK: transport

    @Test("the transport itself refuses anything but https with a host, before any request is made")
    func transportRevalidates() async throws {
        let transport = URLSessionMetricsTransport(protocolClasses: [CountingURLProtocol.self])
        CountingURLProtocol.reset()
        for raw in ["http://metrics.example.com/b", "file:///etc/passwd", "https:///nohost", "https://u:p@metrics.example.com/b"] {
            let url = try #require(URL(string: raw))
            #expect(await transport.post(Data("{}".utf8), to: url) == .retryLater)
        }
        #expect(CountingURLProtocol.count == 0)
    }
}

/// Never answers until its task is cancelled (or ten seconds pass, so a request nothing cancels fails
/// the test instead of hanging it); counts the requests started and the ones cancelled.
private final class HangingTransport: MetricsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var cancelCount = 0
    var starts: Int { lock.withLock { startCount } }
    var cancellations: Int { lock.withLock { cancelCount } }
    var started: Bool { starts > 0 }
    var wasCancelled: Bool { cancellations > 0 }

    func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
        lock.withLock { startCount += 1 }
        try? await Task.sleep(for: .seconds(10))
        if Task.isCancelled { lock.withLock { cancelCount += 1 } }
        return .accepted    // a late "success" must still change nothing
    }
}

private final class CountingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hits = 0
    static var count: Int { lock.withLock { hits } }
    static func reset() { lock.withLock { hits = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.hits += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
