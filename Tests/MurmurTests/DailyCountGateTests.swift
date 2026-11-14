import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The daily count has a switch of its own, "Send a daily count", on by default and separate from the
/// usage-numbers switch. Throwaway defaults suites and temp folders; no network.
@Suite("Daily count: its own switch and hook", .timeLimit(.minutes(1)))
@MainActor
struct DailyCountGateTests {
    private final class RecordingTransport: MetricsTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String] = []
        var sent: [String] { lock.withLock { bodies } }
        func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
            lock.withLock { bodies.append(String(decoding: body, as: UTF8.self)) }
            return .accepted
        }
    }

    private func makeSettings(stored: [String: Bool] = [:]) -> (AppSettings, () -> Void) {
        let name = "hushy-test-dailycount-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        for (key, value) in stored { defaults.set(value, forKey: key) }
        return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private func sender(_ settings: AppSettings, _ transport: MetricsTransport, now: @escaping @Sendable () -> Date = { Date() }) -> DailyCountSender {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-dailycount-\(UUID().uuidString)", isDirectory: true)
        return DailyCountSender(
            store: DailyCountStore(url: folder.appendingPathComponent(DailyCountStore.fileName)),
            endpoint: URL(string: "https://example.test/api/ping"), build: "2622", gate: settings.dailyCountGate,
            transport: transport, now: now)
    }

    @Test("on by default: a fresh install sends the count with usage numbers off and no notice seen")
    func onByDefault() async {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        #expect(settings.sendDailyCount)
        #expect(!settings.shareUsageNumbers && !settings.usageNumbersNoticeSeen)
        let transport = RecordingTransport()
        let sender = sender(settings, transport)
        sender.noteDeliveredDictation(); await sender.waitUntilIdle()
        #expect(transport.sent == [#"{"v":2,"build":"2622","first":true}"#])
    }

    @Test("an install that predates the switch has no stored choice and so sends; a stored choice is kept")
    func existingInstalls() {
        let (fresh, cleanFresh) = makeSettings()
        defer { cleanFresh() }
        #expect(fresh.sendDailyCount && fresh.dailyCountGate.isOn)
        let (declined, cleanDeclined) = makeSettings(stored: ["sendDailyCount": false])
        defer { cleanDeclined() }
        #expect(!declined.sendDailyCount && !declined.dailyCountGate.isOn)
        let (accepted, cleanAccepted) = makeSettings(stored: ["sendDailyCount": true, "shareUsageNumbers": false])
        defer { cleanAccepted() }
        #expect(accepted.sendDailyCount && accepted.dailyCountGate.isOn)
    }

    @Test("the usage-numbers switch changes nothing about the count, either way")
    func independentOfUsageNumbers() async {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let transport = RecordingTransport()
        let clock = DailyCountClockBox()
        let sender = sender(settings, transport) { clock.now }
        settings.usageNumbersNoticeSeen = true
        settings.shareUsageNumbers = true
        sender.noteDeliveredDictation(); await sender.waitUntilIdle()
        settings.shareUsageNumbers = false
        clock.advanceDays(1)
        sender.noteDeliveredDictation(); await sender.waitUntilIdle()
        #expect(transport.sent == [#"{"v":2,"build":"2622","first":true}"#, #"{"v":2,"build":"2622","first":false}"#])
    }

    @Test("turning the switch off stops it, a later day stays quiet, and turning it on again sends")
    func settingOffStops() async {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let transport = RecordingTransport()
        let clock = DailyCountClockBox()
        let sender = sender(settings, transport) { clock.now }
        sender.noteDeliveredDictation(); await sender.waitUntilIdle()
        settings.sendDailyCount = false
        #expect(!settings.dailyCountGate.isOn)
        clock.advanceDays(1)
        sender.noteDeliveredDictation(); await sender.waitUntilIdle()
        #expect(transport.sent.count == 1)
        settings.sendDailyCount = true
        sender.noteDeliveredDictation(); await sender.waitUntilIdle()
        #expect(transport.sent.last == #"{"v":2,"build":"2622","first":false}"#)
        #expect(transport.sent.count == 2)
    }

    @Test("off from the start sends nothing, and the choice is saved")
    func offFromTheStart() async {
        let (settings, cleanup) = makeSettings(stored: ["sendDailyCount": false])
        defer { cleanup() }
        let transport = RecordingTransport()
        let sender = sender(settings, transport)
        sender.noteDeliveredDictation(); await sender.waitUntilIdle()
        #expect(transport.sent.isEmpty)
    }

    // MARK: the dictation hook

    private final class Counter: @unchecked Sendable { var delivered = 0 }

    @Test("a pasted or copied dictation with words feeds the count, whatever the usage-numbers state; nothing else does")
    func hookFiresOnlyForDelivery() {
        let counter = Counter()
        let hooks = DictationMetricsHooks(isCollecting: { false }, dictationDelivered: { counter.delivered += 1 })
        let mode = Mode.builtIns(userName: "")[0]
        for result: DictationMetricInput.Result in [.pasted, .copied] {
            hooks.report(result, nil, 12, mode, 3, LatencyBreakdown(releasedAt: Date()), Date())
        }
        #expect(counter.delivered == 2)
        for result: DictationMetricInput.Result in [.heldSecure, .noField, .failed, .cancelled] {
            hooks.report(result, nil, 12, mode, 3, LatencyBreakdown(releasedAt: Date()), Date())
        }
        hooks.report(.pasted, nil, 0, mode, 3, LatencyBreakdown(releasedAt: Date()), Date())
        #expect(counter.delivered == 2)
    }
}

/// A clock moved by hand, for the test above.
private final class DailyCountClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_527_200)   // 2026-11-01T10:00:00Z
    var now: Date { lock.withLock { current } }
    func advanceDays(_ days: Int) { lock.withLock { current = current.addingTimeInterval(Double(days) * 86_400) } }
}
