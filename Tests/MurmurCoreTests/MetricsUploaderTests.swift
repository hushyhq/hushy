import Foundation
import Testing
@testable import MurmurCore

/// A transport that never touches the network: records every call and answers from a script.
final class FakeMetricsTransport: MetricsTransport, @unchecked Sendable {
    struct Call: Equatable { let body: Data; let endpoint: URL }
    private let lock = NSLock()
    private var scripted: [MetricsTransportOutcome]
    private var recorded: [Call] = []

    init(_ outcomes: [MetricsTransportOutcome] = []) { scripted = outcomes }

    var calls: [Call] { lock.withLock { recorded } }

    func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
        lock.withLock {
            recorded.append(Call(body: body, endpoint: endpoint))
            return scripted.isEmpty ? .accepted : scripted.removeFirst()
        }
    }
}

@Suite("Usage metrics: uploader")
struct MetricsUploaderTests {
    typealias F = UsageMetricsFixtures

    private let endpoint = URL(string: "https://metrics.example.com/v1/batches")

    private struct Rig {
        let uploader: MetricsUploader
        let queue: MetricsBatchQueue
        let transport: FakeMetricsTransport
        let gate: MetricsSwitch
        let directory: URL
    }

    private func rig(
        isOn: Bool = true, endpoint: URL?, outcomes: [MetricsTransportOutcome] = [], limits: MetricsUploader.Limits = .standard
    ) throws -> Rig {
        let directory = try F.tempDirectory()
        let queue = MetricsBatchQueue(directory: directory)
        let transport = FakeMetricsTransport(outcomes)
        let gate = MetricsSwitch(isOn: isOn)
        let uploader = MetricsUploader(
            queue: queue, stateURL: directory.appendingPathComponent("upload-state.json"), transport: transport,
            endpoint: endpoint, gate: gate, timeZone: { F.utc.timeZone }, limits: limits)
        return Rig(uploader: uploader, queue: queue, transport: transport, gate: gate, directory: directory)
    }

    @Test("with no endpoint configured there is no transport call at all, and batches wait in the queue")
    func noEndpointNoCall() async throws {
        let rig = try rig(endpoint: nil)
        try await rig.queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let report = await rig.uploader.uploadIfDue(now: F.noonOct5)
        #expect(report.skipped == .noEndpoint)
        #expect(rig.transport.calls.isEmpty)
        #expect(try await rig.queue.pendingCount() == 1)
    }

    @Test("with the switch off there is no transport call, even with an endpoint and queued batches")
    func offNoCall() async throws {
        let rig = try rig(isOn: false, endpoint: endpoint)
        try await rig.queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let report = await rig.uploader.uploadIfDue(now: F.noonOct5)
        #expect(report.skipped == .switchedOff)
        #expect(rig.transport.calls.isEmpty)
    }

    @Test("it sends exactly the batch's encoded body to the configured endpoint, then removes the batch")
    func sendsExactBody() async throws {
        let rig = try rig(endpoint: endpoint)
        let batch = try F.simpleBatch()
        try await rig.queue.enqueue([batch], now: F.noonOct5)
        let report = await rig.uploader.uploadIfDue(now: F.noonOct5)
        #expect(report == MetricsUploader.Report(skipped: nil, attempted: 1, accepted: 1, dropped: 0))
        #expect(rig.transport.calls == [FakeMetricsTransport.Call(body: try batch.encodedBody(), endpoint: try #require(endpoint))])
        #expect(try await rig.queue.pendingCount() == 0)
    }

    @Test("a second run on the same day makes no attempt, even for a failed batch")
    func atMostOncePerDay() async throws {
        let rig = try rig(endpoint: endpoint, outcomes: [.retryLater])
        try await rig.queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        _ = await rig.uploader.uploadIfDue(now: F.noonOct5)
        let again = await rig.uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(3 * 3_600))
        #expect(again.skipped == .alreadyRanToday)
        #expect(rig.transport.calls.count == 1)
    }

    @Test("a restart on the same day does not allow a second attempt: the attempt is recorded before it is made")
    func restartDoesNotRepeat() async throws {
        let rig = try rig(endpoint: endpoint, outcomes: [.retryLater])
        try await rig.queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        _ = await rig.uploader.uploadIfDue(now: F.noonOct5)
        let restarted = MetricsUploader(
            queue: rig.queue, stateURL: rig.directory.appendingPathComponent("upload-state.json"), transport: rig.transport,
            endpoint: endpoint, gate: rig.gate, timeZone: { F.utc.timeZone })
        #expect(await restarted.uploadIfDue(now: F.noonOct5.addingTimeInterval(600)).skipped == .alreadyRanToday)
        #expect(rig.transport.calls.count == 1)
    }

    @Test("a retry is byte-identical, and waits 1 day, then 2, then 4, with a bounded number of attempts")
    func retriesBackOffAndStayIdentical() async throws {
        let rig = try rig(endpoint: endpoint, outcomes: Array(repeating: .retryLater, count: 10))
        let batch = try F.simpleBatch()
        try await rig.queue.enqueue([batch], now: F.noonOct5)
        let day: TimeInterval = 86_400
        // Attempt 1 on day 0; attempt 2 is not due on day 0 or... it is due the next day (1-day backoff).
        #expect(await rig.uploader.uploadIfDue(now: F.noonOct5).attempted == 1)
        #expect(await rig.uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(day)).attempted == 1)    // attempt 2
        #expect(await rig.uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(2 * day)).skipped == .nothingDue)   // waits 2 days
        #expect(await rig.uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(3 * day)).attempted == 1)    // attempt 3
        #expect(await rig.uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(6 * day)).skipped == .nothingDue)   // waits 4 days
        let bodies = Set(rig.transport.calls.map(\.body))
        #expect(rig.transport.calls.count == 3)
        #expect(bodies == [try batch.encodedBody()])
    }

    @Test("after the last allowed attempt the batch is dropped, not retried forever")
    func boundedAttempts() async throws {
        let limits = MetricsUploader.Limits(maximumAttempts: 2, maximumBatchesPerRun: 7)
        let rig = try rig(endpoint: endpoint, outcomes: Array(repeating: .retryLater, count: 10), limits: limits)
        try await rig.queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        _ = await rig.uploader.uploadIfDue(now: F.noonOct5)
        let last = await rig.uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(86_400))
        #expect(last.dropped == 1)
        #expect(try await rig.queue.pendingCount() == 0)
        #expect(await rig.uploader.uploadIfDue(now: F.noonOct5.addingTimeInterval(10 * 86_400)).skipped == .nothingDue)
    }

    @Test("a server that refuses a batch for good has it dropped on the spot")
    func rejectedIsDropped() async throws {
        let rig = try rig(endpoint: endpoint, outcomes: [.rejected])
        try await rig.queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let report = await rig.uploader.uploadIfDue(now: F.noonOct5)
        #expect(report.dropped == 1 && report.accepted == 0)
        #expect(try await rig.queue.pendingCount() == 0)
    }

    @Test("when the server struggles the run stops: one failure means no more requests that day")
    func stopsAfterFailure() async throws {
        let rig = try rig(endpoint: endpoint, outcomes: [.retryLater, .accepted, .accepted])
        try await rig.queue.enqueue(
            [F.simpleBatch(id: UUID(), dayOffset: 0), F.simpleBatch(id: UUID(), dayOffset: 1), F.simpleBatch(id: UUID(), dayOffset: 2)],
            now: F.noonOct5)
        let report = await rig.uploader.uploadIfDue(now: F.noonOct5)
        #expect(report.attempted == 1)
        #expect(rig.transport.calls.count == 1)
    }

    @Test("several waiting batches go out oldest first within one run, up to the per-run cap")
    func severalBatches() async throws {
        let limits = MetricsUploader.Limits(maximumAttempts: 4, maximumBatchesPerRun: 2)
        let rig = try rig(endpoint: endpoint, limits: limits)
        try await rig.queue.enqueue((0..<3).map { try F.simpleBatch(id: UUID(), dayOffset: $0) }, now: F.noonOct5)
        let report = await rig.uploader.uploadIfDue(now: F.noonOct5)
        #expect(report.accepted == 2)
        #expect(try await rig.queue.pendingCount() == 1)
    }

    @Test("a batch queued by an older build (schema 1) is sent as the same bytes it was stored with")
    func versionOneBatchSentUnchanged() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: F.simpleBatch().encodedBody()) as? [String: Any])
        object["schemaVersion"] = 1
        object["retention"] = nil
        object["tones"] = nil
        object["editRate"] = nil
        let stored = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let idText = try #require(object["batchID"] as? String)
        let id = try #require(UUID(uuidString: idText))
        let rig = try rig(endpoint: endpoint)
        try FileManager.default.createDirectory(at: rig.directory, withIntermediateDirectories: true)
        let url = rig.directory.appendingPathComponent(id.uuidString + ".batch.json")
        try stored.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: F.noonOct5], ofItemAtPath: url.path)
        _ = await rig.uploader.uploadIfDue(now: F.noonOct5)
        #expect(rig.transport.calls.map(\.body) == [stored])
    }

    @Test("turning the switch off after batches are queued stops the next run")
    func offAfterQueued() async throws {
        let rig = try rig(endpoint: endpoint)
        try await rig.queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        rig.gate.isOn = false
        #expect(await rig.uploader.uploadIfDue(now: F.noonOct5).skipped == .switchedOff)
        #expect(rig.transport.calls.isEmpty)
    }
}
