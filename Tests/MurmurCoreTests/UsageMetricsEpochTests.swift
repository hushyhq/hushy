import Foundation
import Testing
@testable import MurmurCore

/// Switching off makes earlier numbers unreachable by construction: every file lives in the folder
/// of a data epoch, and the epoch goes up whenever the switch goes off.
@Suite("Usage metrics: data epochs", .timeLimit(.minutes(1)))
struct UsageMetricsEpochTests {
    typealias F = UsageMetricsFixtures

    private let dictation = MetricEvent.dictation(F.dictation())
    private let endpoint = URL(string: "https://metrics.example.com/b")

    private func service(
        _ store: MetricsDataStore, gate: MetricsSwitch, makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) -> UsageMetricsService {
        UsageMetricsService(
            store: store, appBuild: 412, firstRunDay: nil, environment: F.environment, timeZone: { F.utc.timeZone },
            gate: gate, makeBatchID: makeID)
    }

    private func uploader(_ store: MetricsDataStore, gate: MetricsSwitch, transport: MetricsTransport) -> MetricsUploader {
        MetricsUploader(store: store, transport: transport, endpoint: endpoint, gate: gate, timeZone: { F.utc.timeZone })
    }

    private func names(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    // MARK: by construction

    @Test("off then straight back on starts in a new, empty folder: nothing from before is reachable, deleted or not")
    func newFolderAfterOffOn() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let svc = service(store, gate: gate)
        await svc.record(dictation, at: F.noonOct3)
        #expect(await svc.closeDays(now: F.noonOct4) == 1)
        await svc.record(dictation, at: F.noonOct4)
        #expect(try await svc.queue.pendingCount() == 1)
        gate.isOn = false
        gate.isOn = true
        #expect(try await svc.queue.pendingCount() == 0)
        #expect(await svc.previewToday(now: F.noonOct4.addingTimeInterval(60)) == nil)
        #expect(names(store.root) == ["e0"])                                  // still on disk, and never read again
        let transport = FakeMetricsTransport()
        #expect(await uploader(store, gate: gate, transport: transport).uploadIfDue(now: F.noonOct5).skipped == .nothingDue)
        #expect(transport.calls.isEmpty)
        #expect(await svc.closeDays(now: F.noonOct5) == 0)                    // the old journal is not read, and the old folder is tidied
        #expect(!names(store.root).contains("e0"))
        #expect(svc.collectGarbage() == 0)
        await svc.record(dictation, at: F.noonOct5)                           // and recording continues in the new one
        #expect(names(store.root).contains("e1") && !names(store.root).contains("e0"))
    }

    @Test("an event handed over before an off is dropped, not written after the switch is back on")
    func staleEventDropped() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let svc = service(store, gate: gate)
        let before = gate.epoch
        gate.isOn = false
        gate.isOn = true
        await svc.record(dictation, at: F.noonOct3, epoch: before)
        await svc.record(dictation, onDay: try MetricsDay(year: 2026, month: 10, day: 3), epoch: before)
        #expect(names(store.root).isEmpty)                                    // nothing was written anywhere
        await svc.record(dictation, at: F.noonOct3, epoch: gate.epoch)
        #expect(names(store.root) == ["e1"])
    }

    @Test("deleting old folders fails: only disk is wasted, nothing old is reachable and recording is unaffected")
    func tidyFailureIsHarmless() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let svc = service(store, gate: gate)
        await svc.record(dictation, at: F.noonOct3)
        let oldJournal = store.directory(for: 0).appendingPathComponent(UsageMetricsService.journalName)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: oldJournal.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: oldJournal.path) }
        gate.isOn = false
        gate.isOn = true
        #expect(svc.collectGarbage() > 0)                                     // could not delete
        #expect(await svc.closeDays(now: F.noonOct5) == 0)                    // yet the old numbers are not read
        #expect(try await svc.queue.pendingCount() == 0)
        await svc.record(dictation, at: F.noonOct5)
        #expect(await svc.closeDays(now: F.noonOct5.addingTimeInterval(86_400)) == 1)
        let batch = try #require(try await svc.queue.nextBatchesToSend(limit: 5, now: F.noonOct5).first)
        #expect(batch.day.isoString == "2026-10-05")
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: oldJournal.path)
        #expect(svc.collectGarbage() == 0)                                    // the next tidy finishes the job
        #expect(!names(store.root).contains("e0"))
    }

    @Test("a second off while the first tidy is running cannot expose or delete current data")
    func secondOffDuringTidy() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let svc = service(store, gate: gate)
        await svc.record(dictation, at: F.noonOct3)
        gate.isOn = false
        gate.isOn = true
        async let firstTidy: Int = Task.detached { svc.collectGarbage() }.value
        gate.isOn = false                                                     // a second off while it runs
        gate.isOn = true
        await svc.record(dictation, at: F.noonOct4, epoch: gate.epoch)
        _ = await firstTidy
        svc.collectGarbage()
        #expect(names(store.root) == ["e2"])                                  // only the newest epoch survives
        #expect(await svc.closeDays(now: F.noonOct5) == 1)
        let batch = try #require(try await svc.queue.nextBatchesToSend(limit: 5, now: F.noonOct5).first)
        #expect(batch.day.isoString == "2026-10-04" && batch.combinedDictations.count == 1)
    }

    @Test("a relaunch after a crash: a new epoch starts, the old folder is unreachable and tidied")
    func relaunchAfterCrash() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let first = MetricsSwitch(isOn: true, epoch: 4)
        let svc = service(store, gate: first)
        await svc.record(dictation, at: F.noonOct3)
        #expect(await svc.closeDays(now: F.noonOct4) == 1)
        // The process dies. The relaunch restores the stored epoch and, if the stored switch is off,
        // starts a new one (AppSettings does this); here it is the same sequence on a fresh gate.
        let relaunched = MetricsSwitch(isOn: false)
        relaunched.restoreEpoch(4)
        relaunched.advanceEpoch()
        relaunched.isOn = true
        let again = service(store, gate: relaunched)
        #expect(try await again.queue.pendingCount() == 0)
        #expect(await again.closeDays(now: F.noonOct5) == 0)
        again.collectGarbage()
        #expect(names(store.root).isEmpty)
    }

    @Test("tidying deletes only folders numbered lower than the epoch it was given, never equal or higher")
    func tidyOnlyLower() throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        for number in [2, 3, 4, 5] { try FileManager.default.createDirectory(at: store.directory(for: number), withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: store.root.appendingPathComponent("stray.json"))
        #expect(store.scan() == .readable(highest: 5))
        #expect(store.collectGarbage(keeping: 4) == 0)
        #expect(names(store.root) == ["e4", "e5"])                            // lower ones and the stray file gone
        #expect(!store.hasGarbage(keeping: 4))
        #expect(MetricsDataStore.epochNumber(ofFolder: "e12") == 12 && MetricsDataStore.epochNumber(ofFolder: "e") == nil)
        #expect(MetricsDataStore.epochNumber(ofFolder: "e1x") == nil && MetricsDataStore.epochNumber(ofFolder: "journal.jsonl") == nil)
    }

    @Test("a folder that does not exist yet is nothing to scan; one that exists but cannot be listed is unreadable, and tidying it fails")
    func scanDistinguishesMissingFromUnreadable() throws {
        let missing = MetricsDataStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("hushy-missing-\(UUID().uuidString)"))
        #expect(missing.scan() == .readable(highest: nil))
        #expect(missing.collectGarbage(keeping: 0) == 0)
        let root = try F.tempDirectory()
        let store = MetricsDataStore(root: root)
        try FileManager.default.createDirectory(at: store.directory(for: 3), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        #expect(store.scan() == .unreadable)
        #expect(store.collectGarbage(keeping: 9) == 1)                         // cannot list: a failure, not "nothing to clean"
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(store.scan() == .readable(highest: 3))
    }

    @Test("a folder named with a huge number is not an epoch: it neither traps nor becomes one, and it is tidied as stray")
    func hugeFolderNumber() throws {
        for name in ["e9223372036854775807", "e1000000001", "e99999999999999999999", "e٣"] {
            #expect(MetricsDataStore.epochNumber(ofFolder: name) == nil, "\(name)")
        }
        #expect(MetricsDataStore.epochNumber(ofFolder: "e1000000000") == 1_000_000_000)
        let store = MetricsDataStore(root: try F.tempDirectory())
        for name in ["e9223372036854775807", "e5"] { try FileManager.default.createDirectory(at: store.root.appendingPathComponent(name), withIntermediateDirectories: true) }
        #expect(store.scan() == .readable(highest: 5))                         // the huge one is ignored
        #expect(store.collectGarbage(keeping: 6) == 0)
        #expect(names(store.root).isEmpty)                                     // and both are gone
        let gate = MetricsSwitch()
        gate.restoreEpoch(Int.max)                                             // a damaged saved epoch cannot overflow later
        #expect(gate.epoch == MetricsDataStore.maximumEpoch)
        gate.isOn = true
        gate.isOn = false
        #expect(gate.epoch == MetricsDataStore.maximumEpoch + 1)
    }

    @Test("a tidy that captured an old epoch cannot delete the folder the switch has since moved to")
    func staleTidyCannotDeleteNewFolder() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let svc = service(store, gate: gate)
        let captured = gate.epoch                                              // 0
        gate.isOn = false; gate.isOn = true; gate.isOn = false; gate.isOn = true   // two offs happen meanwhile: epoch 2
        await svc.record(dictation, at: F.noonOct5)
        #expect(names(store.root) == ["e2"])
        #expect(store.collectGarbage(keeping: captured) == 0)                 // the stale tidy runs late
        #expect(names(store.root) == ["e2"])                                  // the current folder is untouched
        #expect(await svc.closeDays(now: F.noonOct5.addingTimeInterval(86_400)) == 1)
    }

    // MARK: starting a request

    @Test("an off that lands after the last check, as the request starts, cancels it and its answer changes nothing")
    func offAsRequestStarts() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        try await store.queue(for: 0).enqueue([F.simpleBatch()], now: F.noonOct5)
        let transport = OffAtPostTransport(gate: gate)
        let report = await uploader(store, gate: gate, transport: transport).uploadIfDue(now: F.noonOct5)
        // The epoch had already moved when the request began: no check can be atomic with a request
        // leaving the Mac, so the promise is the cancel, not "never in a later epoch".
        #expect(transport.seen == [OffAtPostTransport.Seen(epoch: 1, cancelled: true)])
        #expect(report.attempted == 1 && report.accepted == 0)
        #expect(try await store.queue(for: 0).pendingCount() == 1)           // not acknowledged; the old folder is unreachable
    }

    @Test("a request is either never made or cancelled by the off that follows, however the two interleave")
    func offCannotMissAStartingRequest() async {
        for _ in 0..<300 {
            let gate = MetricsSwitch(isOn: true)
            let box = InFlightRequest()
            gate.whenTurnedOff { box.cancel() }
            let epoch = gate.epoch
            async let started: Task<MetricsTransportOutcome?, Never>? = Task.detached {
                box.start(gate: gate, epoch: epoch) { Task { try? await Task.sleep(for: .seconds(5)); return .accepted } }
            }.value
            async let turnedOff: Void = Task.detached { gate.isOn = false }.value
            let task = await started
            _ = await turnedOff
            if let task {
                #expect(task.isCancelled)                                     // registered before the off, so the off cancelled it
                task.cancel()
            }
            #expect(!gate.isOn)
        }
    }

    // MARK: across awaits

    @Test("the uploader resolves its epoch, then the switch is cycled: the batch it read is never sent")
    func uploaderHoldingABatch() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let queue = store.queue(for: 0)
        try await queue.enqueue([F.simpleBatch()], now: F.noonOct5)
        let transport = FakeMetricsTransport([.accepted])
        let sender = MetricsUploader(
            locate: { epoch in
                gate.isOn = false                               // off and back on while the run is under way
                gate.isOn = true
                return (store.queue(for: epoch), store.uploadStateURL(for: epoch))
            },
            transport: transport, endpoint: endpoint, gate: gate, timeZone: { F.utc.timeZone }, limits: .standard)
        let report = await sender.uploadIfDue(now: F.noonOct5)
        #expect(report.skipped == .switchedOff && report.attempted == 0)
        #expect(transport.calls.isEmpty)
    }

    @Test("day closing is cut short when the switch is cycled part-way, and nothing reaches the new epoch")
    func closeAcrossOffOn() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let svc = service(store, gate: gate) { gate.isOn = false; gate.isOn = true; return UUID() }   // cycles while batches are being built
        await svc.record(dictation, at: F.noonOct3)
        #expect(await svc.closeDays(now: F.noonOct4) == 0)
        #expect(try await svc.queue.pendingCount() == 0)                      // the current epoch has nothing
        #expect(await svc.previewToday(now: F.noonOct3.addingTimeInterval(60)) == nil)
        #expect(names(store.directory(for: gate.epoch)).isEmpty)
    }

    // MARK: held dictations

    @Test("a dictation held before an off-and-on is dropped when it is released")
    func heldDictationDropped() async throws {
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let svc = service(store, gate: gate)
        var held = PendingDictationMetrics(calendar: F.utc)
        let input = DictationMetricInput(
            result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 9,
            audioSeconds: 3, speechMilliseconds: 200, cleanupMilliseconds: 400, releaseToDeliveryMilliseconds: 700)
        let id = held.hold(input, at: F.noonOct3, epoch: gate.epoch)
        gate.isOn = false
        gate.isOn = true
        let maybeReleased = held.resolve(id, observation: .kept, coverage: .observed, at: F.noonOct3.addingTimeInterval(8))
        let released = try #require(maybeReleased)
        #expect(released.epoch != gate.epoch)
        await svc.record(.dictation(released.event), onDay: released.day, epoch: released.epoch)
        #expect(names(store.root).isEmpty)
    }

    // MARK: random interleavings

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Events recorded in epoch `e` at step `n` carry day `2026-10-03 + 100e + n`, so a day tells which
    /// epoch an event was recorded in. Whatever order off, on, record,
    /// close, upload and a crash happen in, no batch file may hold a day from another epoch's folder,
    /// and a batch reaches the transport in a later epoch than its own only when the off between them
    /// landed while its request was starting, and then that off cancelled the request.
    @Test("random orders of off, on, record, close, upload and crash never carry earlier numbers forward", arguments: Array(0..<30))
    func randomInterleavings(seed: Int) async throws {
        var rng = SeededGenerator(state: UInt64(seed) &* 7_919 &+ 13)
        let store = MetricsDataStore(root: try F.tempDirectory())
        let gate = MetricsSwitch(isOn: true)
        let base = F.noonOct3
        let days = try (0..<4_300).map { try MetricsDay(date: base.addingTimeInterval(Double($0) * 86_400), calendar: F.utc) }
        func day(of epoch: Int, step: Int) -> MetricsDay { days[min(epoch * 100 + step, days.count - 1)] }
        let transport = EpochTransport(gate: gate, firstDay: days[0])
        var svc = service(store, gate: gate)
        var sender = MetricsUploader(store: store, transport: transport, endpoint: endpoint, gate: gate, timeZone: { F.utc.timeZone })
        var running: [Task<Void, Never>] = []
        var staleEpochs: [Int] = []
        var uploadDay = 0
        for step in 0..<40 {
            switch Int.random(in: 0..<8, using: &rng) {
            case 0: gate.isOn = false
            case 1: gate.isOn = true
            case 2, 3:
                let epoch = gate.epoch
                staleEpochs.append(epoch)
                await svc.record(dictation, onDay: day(of: epoch, step: step), epoch: epoch)
            case 4:
                if let old = staleEpochs.randomElement(using: &rng) {       // an event still in flight from an earlier epoch
                    await svc.record(dictation, onDay: day(of: old, step: step), epoch: old)
                }
            case 5:
                let service = svc
                running.append(Task { _ = await service.closeDays(now: base.addingTimeInterval(1_000 * 86_400)) })
            case 6:
                uploadDay += 1
                let sender = sender, now = base.addingTimeInterval(Double(1_000 + uploadDay) * 86_400)
                running.append(Task { _ = await sender.uploadIfDue(now: now) })
            default:
                for task in running { await task.value }                    // a crash: in-memory state is lost, files stay
                running = []
                svc = service(store, gate: gate)
                sender = MetricsUploader(store: store, transport: transport, endpoint: endpoint, gate: gate, timeZone: { F.utc.timeZone })
            }
            if Bool.random(using: &rng) { await Task.yield() }
        }
        for task in running { await task.value }
        // Every batch ever queued sits in the folder of its own epoch and holds only that epoch's day.
        for name in names(store.root) {
            guard name.hasPrefix("e"), let epoch = Int(name.dropFirst()) else { Issue.record("unexpected entry \(name)"); continue }
            let batches = try await store.queue(for: epoch).nextBatchesToSend(limit: 100, now: base.addingTimeInterval(1_000 * 86_400))
            for batch in batches {
                #expect(batch.day.days(since: days[0]) / 100 == epoch, "epoch \(epoch) holds day \(batch.day.isoString)")
            }
        }
        // And nothing from an earlier epoch got through: a batch is sent in its own epoch, or the off
        // that ended that epoch cancelled its request.
        for sent in transport.sent {
            #expect(sent.dayOffset / 100 == sent.epochAtPost || sent.cancelled, "day +\(sent.dayOffset) sent in epoch \(sent.epochAtPost), not cancelled")
        }
    }
}

/// Records, for every body handed to it, which day the batch holds (as an offset from the first
/// day), which epoch the switch was in at that moment and whether the request ended cancelled.
/// A batch from an older epoch is held, as a slow request would be, until the off that moved the
/// epoch cancels it; ten seconds without that cancel records it as not cancelled.
private final class EpochTransport: MetricsTransport, @unchecked Sendable {
    struct Sent { let dayOffset: Int; let epochAtPost: Int; let cancelled: Bool }
    private let lock = NSLock()
    private var recorded: [Sent] = []
    private let gate: MetricsSwitch
    private let firstDay: MetricsDay

    init(gate: MetricsSwitch, firstDay: MetricsDay) { self.gate = gate; self.firstDay = firstDay }

    var sent: [Sent] { lock.withLock { recorded } }

    func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
        let epoch = gate.epoch
        guard let batch = try? JSONDecoder().decode(DailyMetricsBatch.self, from: body) else { return .accepted }
        let dayOffset = batch.day.days(since: firstDay)
        if dayOffset / 100 != epoch { try? await Task.sleep(for: .seconds(10)) }
        let cancelled = Task.isCancelled
        lock.withLock { recorded.append(Sent(dayOffset: dayOffset, epochAtPost: epoch, cancelled: cancelled)) }
        return .accepted
    }
}

/// Turns the switch off at the start of the request, after every check the uploader makes, and
/// records the epoch it then sees and whether its request was cancelled.
private final class OffAtPostTransport: MetricsTransport, @unchecked Sendable {
    struct Seen: Equatable { let epoch: Int; let cancelled: Bool }
    private let lock = NSLock()
    private var recorded: [Seen] = []
    private let gate: MetricsSwitch

    init(gate: MetricsSwitch) { self.gate = gate }

    var seen: [Seen] { lock.withLock { recorded } }

    func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
        gate.isOn = false
        let observed = Seen(epoch: gate.epoch, cancelled: Task.isCancelled)
        lock.withLock { recorded.append(observed) }
        return .accepted
    }
}
