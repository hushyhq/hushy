import Foundation
import Testing
@testable import MurmurCore

/// A clock the test moves by hand.
final class DailyCountClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ iso: String = "2026-11-01T10:00:00Z") { current = ISO8601DateFormatter().date(from: iso)! }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func advanceDays(_ days: Int) { advance(Double(days) * 86_400) }
}

/// Never touches the network. Cancelling a call that is waiting makes it answer `retryLater`.
final class HangingMetricsTransport: MetricsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
        lock.withLock { count += 1 }
        do { try await Task.sleep(for: .seconds(30)) } catch { return .retryLater }
        return .accepted
    }
}

@Suite("Daily count: the once-a-day message with no identifier", .timeLimit(.minutes(1)))
struct DailyCountTests {
    private struct Rig {
        let sender: DailyCountSender
        let transport: FakeMetricsTransport
        let gate: MetricsSwitch
        let clock: DailyCountClock
        let store: DailyCountStore
    }

    private func makeRig(
        outcomes: [MetricsTransportOutcome] = [], isOn: Bool = true, build: String? = "2622", store: DailyCountStore? = nil,
        clock: DailyCountClock = DailyCountClock()
    ) throws -> Rig {
        let store = try store ?? DailyCountStore(url: UsageMetricsFixtures.tempDirectory().appendingPathComponent(DailyCountStore.fileName))
        let transport = FakeMetricsTransport(outcomes)
        let gate = MetricsSwitch(isOn: isOn)
        let sender = DailyCountSender(
            store: store, endpoint: URL(string: "https://example.test/api/ping"), build: build, gate: gate,
            transport: transport, now: { clock.now })
        return Rig(sender: sender, transport: transport, gate: gate, clock: clock, store: store)
    }

    private func dictate(_ rig: Rig) async {
        rig.sender.noteDeliveredDictation()
        await rig.sender.waitUntilIdle()
    }

    private func bodies(_ rig: Rig) -> [String] { rig.transport.calls.map { String(decoding: $0.body, as: UTF8.self) } }

    // MARK: body

    @Test("the body is exactly three keys, in order, and nothing that identifies a Mac")
    func bodyShape() throws {
        #expect(DailyCountBody.text(build: "2622", first: false) == #"{"v":2,"build":"2622","first":false}"#)
        #expect(DailyCountBody.text(build: "2622", first: true) == #"{"v":2,"build":"2622","first":true}"#)
        let data = try #require(DailyCountBody.encode(build: "1.2_3-x", first: true))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["v", "build", "first"])
        #expect(object["v"] as? Int == 2)
    }

    @Test("a build the site would refuse is never sent", arguments: ["", "x y", "a\"b", String(repeating: "9", count: 17), "é1", "1}"])
    func badBuilds(_ build: String) {
        #expect(DailyCountBody.text(build: build, first: false) == nil)
    }

    @Test("the example in the sheet is the real body for this build")
    func disclosureExample() {
        #expect(DailyCountDisclosure.exampleBody(build: "2700") == #"{"v":2,"build":"2700","first":false}"#)
        #expect(DailyCountDisclosure.exampleBody(build: nil) == #"{"v":2,"build":"2622","first":false}"#)
        #expect(DailyCountDisclosure.exampleBody(build: "bad build") == #"{"v":2,"build":"2622","first":false}"#)
    }

    @Test("the words promise only what the body holds: version, first day, no id, nothing said")
    func disclosureWords() {
        let sentences = [DailyCountDisclosure.switchDetail, DailyCountDisclosure.onboardingLine, DailyCountDisclosure.summary, DailyCountDisclosure.switchNote]
        for sentence in sentences {
            #expect(!sentence.contains("!") && !sentence.contains("\u{2014}"), "\(sentence)")
        }
        #expect(DailyCountDisclosure.switchTitle == "Send a daily count")
        #expect(DailyCountDisclosure.switchDetail ==
            "Once a day, Hushy tells us this Mac used it: just the app version and whether it's your first day. No ID, nothing you said.")
        #expect(DailyCountDisclosure.onboardingLine.contains("No ID, nothing you said"))
        #expect(DailyCountDisclosure.switchNote.contains("on by default"))
        #expect(!DailyCountDisclosure.summary.contains("usage numbers"), "the count is not behind the usage-numbers switch")
    }

    @Test("the endpoint is the site's ping address over https")
    func endpoint() {
        #expect(DailyCountEndpoint.url.absoluteString == "https://tryhushy.com/api/ping")
    }

    // MARK: gate

    @Test("switch off means nothing is sent and nothing is written")
    func offSendsNothing() async throws {
        let rig = try makeRig(isOn: false)
        await dictate(rig)
        #expect(rig.transport.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.store.url.path))
    }

    @Test("no store, no endpoint or no valid build makes the sender inert")
    func inert() async throws {
        let gate = MetricsSwitch(isOn: true)
        let transport = FakeMetricsTransport()
        let directory = try UsageMetricsFixtures.tempDirectory()
        let store = DailyCountStore(url: directory.appendingPathComponent(DailyCountStore.fileName))
        let senders = [
            DailyCountSender(store: nil, endpoint: URL(string: "https://example.test/p"), build: "1", gate: gate, transport: transport),
            DailyCountSender(store: store, endpoint: nil, build: "1", gate: gate, transport: transport),
            DailyCountSender(store: store, endpoint: URL(string: "http://example.test/p"), build: "1", gate: gate, transport: transport),
            DailyCountSender(store: store, endpoint: URL(string: "https://example.test/p"), build: nil, gate: gate, transport: transport),
            DailyCountSender(store: store, endpoint: URL(string: "https://example.test/p"), build: "no good", gate: gate, transport: transport),
        ]
        for sender in senders { sender.noteDeliveredDictation(); await sender.waitUntilIdle() }
        #expect(transport.calls.isEmpty)
    }

    @Test("turning the switch off stops it at once, and on again sends the same day's message")
    func switchOffStops() async throws {
        let rig = try makeRig()
        rig.gate.isOn = false
        await dictate(rig)
        #expect(rig.transport.calls.isEmpty)
        rig.gate.isOn = true
        await dictate(rig)
        #expect(bodies(rig) == [#"{"v":2,"build":"2622","first":true}"#])
    }

    @Test("turning the switch off while a request is out cancels it and records nothing")
    func switchOffCancelsInFlight() async throws {
        let store = DailyCountStore(url: try UsageMetricsFixtures.tempDirectory().appendingPathComponent(DailyCountStore.fileName))
        let gate = MetricsSwitch(isOn: true)
        let transport = HangingMetricsTransport()
        let sender = DailyCountSender(
            store: store, endpoint: URL(string: "https://example.test/api/ping"), build: "2622", gate: gate, transport: transport)
        sender.noteDeliveredDictation()
        while transport.calls == 0 { await Task.yield() }
        gate.isOn = false
        await sender.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        #expect(store.load() == DailyCountState())
    }

    // MARK: once a day, first once

    @Test("one message per UTC day however many dictations, and a new UTC day sends again")
    func oncePerDay() async throws {
        let rig = try makeRig()
        for _ in 0..<5 { await dictate(rig) }
        #expect(rig.transport.calls.count == 1)
        rig.clock.advance(5 * 3_600)   // 15:00 UTC, same day
        await dictate(rig)
        #expect(rig.transport.calls.count == 1)
        rig.clock.advance(9 * 3_600)   // 00:00 UTC next day
        await dictate(rig)
        await dictate(rig)
        #expect(rig.transport.calls.count == 2)
    }

    @Test("first is true only on the first message ever, and the markers are all that is stored")
    func firstOnlyOnce() async throws {
        let rig = try makeRig()
        await dictate(rig)
        rig.clock.advanceDays(1)
        await dictate(rig)
        rig.clock.advanceDays(1)
        await dictate(rig)
        #expect(bodies(rig) == [
            #"{"v":2,"build":"2622","first":true}"#, #"{"v":2,"build":"2622","first":false}"#, #"{"v":2,"build":"2622","first":false}"#,
        ])
        #expect(rig.store.load() == DailyCountState(sentFirst: true, lastSentDay: "2026-11-03"))
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: rig.store.url)) as? [String: Any]
        #expect(Set(try #require(stored).keys) == ["sentFirst", "lastSentDay"])
    }

    @Test("a relaunch the same day sends nothing more, and the next day sends first false")
    func relaunchKeepsMarkers() async throws {
        let first = try makeRig()
        await dictate(first)
        let second = try makeRig(store: first.store, clock: first.clock)
        await dictate(second)
        #expect(second.transport.calls.isEmpty)
        second.clock.advanceDays(1)
        await dictate(second)
        #expect(bodies(second) == [#"{"v":2,"build":"2622","first":false}"#])
    }

    @Test("a damaged marker file never makes first go out twice")
    func damagedFile() async throws {
        let store = DailyCountStore(url: try UsageMetricsFixtures.tempDirectory().appendingPathComponent(DailyCountStore.fileName))
        try Data("not json".utf8).write(to: store.url)
        let rig = try makeRig(store: store)
        await dictate(rig)
        #expect(bodies(rig) == [#"{"v":2,"build":"2622","first":false}"#])
    }

    @Test("a clock set back never sends the same day again")
    func clockSetBack() async throws {
        let rig = try makeRig()
        await dictate(rig)
        rig.clock.advanceDays(-3)
        let relaunched = try makeRig(store: rig.store, clock: rig.clock)
        await dictate(relaunched)
        #expect(relaunched.transport.calls.isEmpty)
    }

    // MARK: failure

    @Test("a failed request is retried once, later that day, and then waits for tomorrow")
    func retryOnce() async throws {
        let rig = try makeRig(outcomes: [.retryLater, .retryLater, .accepted])
        await dictate(rig)                       // fails
        #expect(rig.transport.calls.count == 1)
        rig.clock.advance(60)
        await dictate(rig)                       // too soon
        #expect(rig.transport.calls.count == 1)
        rig.clock.advance(DailyCountSender.retryDelay)
        await dictate(rig)                       // the one retry, fails
        #expect(rig.transport.calls.count == 2)
        rig.clock.advance(3_600)
        await dictate(rig)                       // done for today
        #expect(rig.transport.calls.count == 2)
        #expect(!FileManager.default.fileExists(atPath: rig.store.url.path))
        rig.clock.advanceDays(1)
        await dictate(rig)                       // tomorrow tries again, still as the first message
        #expect(bodies(rig).last == #"{"v":2,"build":"2622","first":true}"#)
        #expect(rig.store.load().sentFirst)
    }

    @Test("a retry that works counts the day")
    func retryWorks() async throws {
        let rig = try makeRig(outcomes: [.retryLater, .accepted])
        await dictate(rig)
        rig.clock.advance(DailyCountSender.retryDelay + 1)
        await dictate(rig)
        await dictate(rig)
        #expect(rig.transport.calls.count == 2)
        #expect(rig.store.load().lastSentDay == "2026-11-01")
    }

    @Test("a refusal (the site said no) is not retried that day")
    func refusalNotRetried() async throws {
        let rig = try makeRig(outcomes: [.rejected])
        await dictate(rig)
        rig.clock.advance(7_200)
        await dictate(rig)
        #expect(rig.transport.calls.count == 1)
        #expect(!rig.store.load().sentFirst)
    }
}
