import Foundation
import Testing
@testable import MurmurCore

@Suite("Passive throughput and ETA smoothing")
struct DownloadEstimateTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Feeds one sample per second at a constant `rate` for `seconds`.
    private func meter(rate: Int64, seconds: Int, start: ThroughputMeter = ThroughputMeter(), from offset: Int = 0) -> ThroughputMeter {
        var meter = start
        for second in 0...seconds {
            meter = meter.observing(totalBytes: rate * Int64(second + offset), at: t0.addingTimeInterval(Double(second + offset)))
        }
        return meter
    }

    @Test("no rate before the warm-up, then the steady rate")
    func warmUp() {
        let one = meter(rate: 1_000_000, seconds: 1)
        #expect(one.bytesPerSecond == nil)
        let steady = meter(rate: 1_000_000, seconds: 10)
        #expect(abs((steady.bytesPerSecond ?? 0) - 1_000_000) < 1)
    }

    @Test("a stall pulls the rate down instead of freezing it")
    func stallDecays() {
        var stalled = meter(rate: 2_000_000, seconds: 10)
        for second in 11...20 {
            stalled = stalled.observing(totalBytes: 20_000_000, at: t0.addingTimeInterval(Double(second)))
        }
        let rate = stalled.bytesPerSecond ?? 0
        #expect(rate < 2_000_000 * 0.35)
        #expect(rate > 0)
    }

    @Test("bursty callbacks closer than the minimum interval are merged")
    func burstsMerged() {
        let meter = ThroughputMeter()
            .observing(totalBytes: 0, at: t0)
            .observing(totalBytes: 5_000_000, at: t0.addingTimeInterval(0.01))
        #expect(meter.smoothedBytesPerSecond == nil)
    }

    @Test("a byte count that restarts re-anchors without a negative rate")
    func counterReset() {
        let restarted = meter(rate: 1_000_000, seconds: 5)
            .observing(totalBytes: 0, at: t0.addingTimeInterval(6))
            .observing(totalBytes: 1_000_000, at: t0.addingTimeInterval(7))
        #expect((restarted.bytesPerSecond ?? -1) > 0)
    }

    @Test("seconds remaining is capped and zero when done")
    func secondsRemaining() {
        let steady = meter(rate: 1_000_000, seconds: 10)
        #expect(steady.secondsRemaining(forBytes: 60_000_000).map { abs($0 - 60) < 0.5 } == true)
        #expect(steady.secondsRemaining(forBytes: 0) == 0)
        #expect(ThroughputMeter().secondsRemaining(forBytes: 10) == nil)
    }

    @Test("the smoothed ETA counts down between samples and never jumps")
    func smoothing() {
        var smoother = ETASmoother().observing(rawSeconds: 120, at: t0)
        #expect(smoother.seconds == 120)
        // Same underlying rate: raw ETA falls by one each second; shown value tracks it.
        smoother = smoother.observing(rawSeconds: 119, at: t0.addingTimeInterval(1))
        #expect(abs((smoother.seconds ?? 0) - 119) < 0.001)
        // A one-second dip in throughput doubles the raw ETA; the shown one moves only a bit.
        smoother = smoother.observing(rawSeconds: 236, at: t0.addingTimeInterval(2))
        let afterSpike: Double = smoother.seconds ?? 0
        let ceiling: Double = 118 + 0.21 * 118 + 1
        #expect(afterSpike < ceiling)
        #expect(afterSpike > 118)
        // Good news is taken faster than bad.
        let good = ETASmoother().observing(rawSeconds: 100, at: t0).observing(rawSeconds: 40, at: t0.addingTimeInterval(1))
        let bad = ETASmoother().observing(rawSeconds: 100, at: t0).observing(rawSeconds: 160, at: t0.addingTimeInterval(1))
        let goodDrop: Double = 99 - (good.seconds ?? 0)
        let badRise: Double = (bad.seconds ?? 0) - 99
        #expect(goodDrop > badRise)
    }

    @Test("a sustained slowdown shows up within seconds")
    func sustainedSlowdownConverges() {
        var smoother = ETASmoother().observing(rawSeconds: 60, at: t0)
        for second in 1...20 {
            smoother = smoother.observing(rawSeconds: 300 - Double(second), at: t0.addingTimeInterval(Double(second)))
        }
        #expect(abs((smoother.seconds ?? 0) - 280) < 10)
    }

    @Test("without a raw estimate the shown value keeps counting down")
    func countdownWithoutRate() {
        let smoother = ETASmoother().observing(rawSeconds: 30, at: t0).observing(rawSeconds: nil, at: t0.addingTimeInterval(10))
        #expect(smoother.seconds == 20)
        #expect(ETASmoother().observing(rawSeconds: nil, at: t0).seconds == nil)
    }

    @Test("speed buckets")
    func buckets() {
        #expect(SpeedBucket.from(bytesPerSecond: 50_000_000) == .fast)
        #expect(SpeedBucket.from(bytesPerSecond: 10_000_000) == .fast)
        #expect(SpeedBucket.from(bytesPerSecond: 4_000_000) == .moderate)
        #expect(SpeedBucket.from(bytesPerSecond: 600_000) == .slow)
        #expect(SpeedBucket.from(bytesPerSecond: 100_000) == .verySlow)
    }

    @Test("the compact progress line reads bytes and a coarse ETA")
    func compactLine() {
        let progress = ModelDownloadProgress(fraction: 312.0 / 632.0, expectedBytes: 632_000_000, estimatedSecondsRemaining: 55)
        #expect(progress.compactLine(title: "Speech model") == "Speech model · 312 of ~632 MB · about 55 s")
        let longer = ModelDownloadProgress(fraction: 0.5, expectedBytes: 632_000_000, estimatedSecondsRemaining: 230)
        #expect(longer.compactLine(title: "Speech model") == "Speech model · 316 of ~632 MB · about 4 min")
        let early = ModelDownloadProgress(fraction: 0.01, expectedBytes: 632_000_000)
        #expect(early.compactLine(title: "Speech model") == "Speech model · 6.3 of ~632 MB")
    }
}

@Suite("Download queue")
struct AssetQueueTests {
    private let speech = DownloadableAsset(
        id: "speech", title: "Speech model", kind: .speechModel, importance: .required,
        expectedBytes: 632_000_000, source: .external)
    private let vocabulary = DownloadableAsset(
        id: "vocabulary", title: "Vocabulary model", kind: .vocabularyModel, importance: .optional,
        expectedBytes: 98_000_000, source: .external)
    private let cleanup = DownloadableAsset(
        id: "cleanup-2b", title: "Cleanup model", kind: .cleanupModel, importance: .optional,
        startPolicy: .whenAccepted, expectedBytes: 1_200_000_000, minimumMemoryGB: 16, source: .files([]))

    @Test("required first; optional only after every required asset is ready")
    func ordering() {
        var queue = AssetQueue(assets: [vocabulary, speech])
        #expect(queue.nextToStart?.id == "speech")
        queue = queue.updating("speech", state: .downloading)
        #expect(queue.nextToStart == nil)
        queue = queue.updating("speech", state: .paused)
        #expect(queue.nextToStart == nil)  // paused required asset still blocks optional ones
        queue = queue.updating("speech", state: .ready)
        #expect(queue.nextToStart?.id == "vocabulary")
    }

    @Test("recommended download follows required and precedes optional without gating readiness")
    func recommendedOrdering() {
        let meeting = DownloadableAsset(
            id: "meeting-4b", title: "Meeting model", kind: .cleanupModel,
            importance: .recommended, expectedBytes: 2_000_000_000, source: .files([]))
        var queue = AssetQueue(assets: [vocabulary, meeting, speech])
        #expect(queue.nextToStart?.id == "speech")
        queue = queue.updating("speech", state: .ready)
        #expect(queue.requiredReady)
        #expect(queue.nextToStart?.id == "meeting-4b")
        queue = queue.updating("meeting-4b", state: .ready)
        #expect(queue.nextToStart?.id == "vocabulary")
    }

    @Test("offered assets wait for acceptance and don't count toward the ETA")
    func offers() {
        let queue = AssetQueue(assets: [speech, cleanup], physicalMemoryGB: 16).updating("speech", state: .ready)
        #expect(queue["cleanup-2b"]?.state == .offered)
        #expect(queue.nextToStart == nil)
        #expect(queue.queuedRemainingBytes == 0)
    }

    @Test("the RAM tier rule leaves big models out on small Macs")
    func ramTier() {
        let small = AssetQueue(assets: [speech, cleanup], physicalMemoryGB: 8)
        #expect(small["cleanup-2b"] == nil)
        #expect(small.adding(cleanup, physicalMemoryGB: 8)["cleanup-2b"] == nil)
    }

    @Test("time remaining for the required set and for everything queued")
    func estimates() {
        let queue = AssetQueue(assets: [speech, vocabulary]).updating("speech", state: .downloading, receivedBytes: 312_000_000)
        #expect(queue.requiredSecondsRemaining(bytesPerSecond: 4_000_000) == 80)
        #expect(queue.allSecondsRemaining(bytesPerSecond: 4_000_000) == 104.5)
        #expect(queue.requiredSecondsRemaining(bytesPerSecond: nil) == nil)
        #expect(queue.updating("speech", state: .ready).requiredSecondsRemaining(bytesPerSecond: nil) == 0)
    }

    @Test("adding is idempotent")
    func adding() {
        let queue = AssetQueue(assets: [speech]).adding(vocabulary).adding(vocabulary)
        #expect(queue.entries.count == 2)
    }
}

@Suite("Metered networks and backoff")
struct DownloadGateTests {
    @Test("big downloads ask first on expensive or Low Data Mode networks")
    func metered() {
        let hotspot = NetworkConditions(isReachable: true, isExpensive: true)
        let lowData = NetworkConditions(isReachable: true, isConstrained: true)
        #expect(DownloadGate.decide(conditions: hotspot, remainingBytes: 632_000_000, approvedOnMetered: false) == .askFirst)
        #expect(DownloadGate.decide(conditions: lowData, remainingBytes: 632_000_000, approvedOnMetered: false) == .askFirst)
        #expect(DownloadGate.decide(conditions: hotspot, remainingBytes: 632_000_000, approvedOnMetered: true) == .proceed)
        // A nearly-finished download isn't worth an interruption.
        #expect(DownloadGate.decide(conditions: hotspot, remainingBytes: 5_000_000, approvedOnMetered: false) == .proceed)
    }

    @Test("unmetered proceeds; offline waits")
    func plain() {
        #expect(DownloadGate.decide(conditions: .unmetered, remainingBytes: 632_000_000, approvedOnMetered: false) == .proceed)
        #expect(DownloadGate.decide(conditions: .offline, remainingBytes: 632_000_000, approvedOnMetered: true) == .waitForNetwork)
    }

    @Test("backoff doubles, caps, stops, and jitters within bounds")
    func backoff() {
        let backoff = RetryBackoff(initialDelay: 2, multiplier: 2, maximumDelay: 30, maximumAttempts: 5, jitter: 0.2)
        let mid = { 0.5 }
        func close(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool { value.map { abs($0 - expected) < 1e-9 } ?? false }
        #expect(close(backoff.delay(beforeRetry: 1, random: mid), 2))
        #expect(close(backoff.delay(beforeRetry: 2, random: mid), 4))
        #expect(close(backoff.delay(beforeRetry: 4, random: mid), 16))
        #expect(close(backoff.delay(beforeRetry: 5, random: mid), 30))
        #expect(backoff.delay(beforeRetry: 6, random: mid) == nil)
        #expect(backoff.delay(beforeRetry: 0, random: mid) == nil)
        #expect(close(backoff.delay(beforeRetry: 3, random: { 0 }), 6.4))
        #expect(close(backoff.delay(beforeRetry: 3, random: { 1 }), 9.6))
    }
}
