import Foundation
import Testing
@testable import MurmurCore

@Suite("AdaptiveLevelMeter")
struct AdaptiveLevelMeterTests {
    /// Feeds a constant RMS for `count` pushes and returns the final level.
    private func settle(rms: Float, count: Int, meter: inout AdaptiveLevelMeter) -> Double {
        var level: Double = 0
        for _ in 0..<count { level = meter.push(rms: rms) }
        return level
    }

    @Test("whisper-level input produces visible motion")
    func whisperIsVisible() {
        var meter = AdaptiveLevelMeter()
        // Whisper RMS ~0.002 (~-54 dBFS), per the real capture measurements in the bug report.
        let level = settle(rms: 0.002, count: 30, meter: &meter)
        #expect(level > 0.15, "a whisper should visibly move the bars, got \(level)")
    }

    @Test("silence stays near zero")
    func silenceStaysFlat() {
        var meter = AdaptiveLevelMeter()
        // Let the floor track near silence first.
        _ = settle(rms: 0.000_2, count: 60, meter: &meter)
        let level = settle(rms: 0.000_2, count: 10, meter: &meter)
        #expect(level < 0.1, "silence should stay near 0, got \(level)")
    }

    @Test("loud speech does not pin at max constantly")
    func loudSpeechIsNotAlwaysPinned() {
        var meter = AdaptiveLevelMeter()
        // Normal speech first, so the meter has an established range.
        _ = settle(rms: 0.013, count: 40, meter: &meter)
        // A brief loud moment.
        let loud = settle(rms: 0.3, count: 5, meter: &meter)
        #expect(loud > 0.7, "a loud moment should read high, got \(loud)")
        // As the peak tracker adapts upward to the new loud level, sustained loud speech should
        // settle below the absolute ceiling rather than pinning at 1.0 forever.
        let sustained = settle(rms: 0.3, count: 200, meter: &meter)
        #expect(sustained < 1.0, "sustained loud speech should not stay pinned at the max, got \(sustained)")
    }

    @Test("normal speech reads clearly louder than a whisper")
    func normalSpeechLouderThanWhisper() {
        var whisperMeter = AdaptiveLevelMeter()
        let whisperLevel = settle(rms: 0.002, count: 30, meter: &whisperMeter)

        var speechMeter = AdaptiveLevelMeter()
        let speechLevel = settle(rms: 0.013, count: 30, meter: &speechMeter)

        #expect(speechLevel > whisperLevel)
    }

    @Test("minimum span prevents amplifying pure hiss")
    func minimumSpanEnforced() {
        var meter = AdaptiveLevelMeter()
        // Feed a very narrow-range near-silent signal; floor and peak should never collapse
        // closer together than the enforced minimum span, or tiny fluctuations in room hiss
        // would read as full-scale bars.
        for _ in 0..<200 {
            _ = meter.push(rms: 0.000_15)
        }
        let level = meter.push(rms: 0.000_17)
        #expect(level < 0.5, "near-identical hiss readings should not swing to loud, got \(level)")
    }

    @Test("level is always clamped to 0...1")
    func levelIsClamped() {
        var meter = AdaptiveLevelMeter()
        for rms: Float in [0, 0.000_01, 0.001, 0.01, 0.1, 1.0, 5.0] {
            let level = meter.push(rms: rms)
            #expect(level >= 0 && level <= 1, "level \(level) out of range for rms \(rms)")
        }
    }
}

/// The bars must not show sound that is not there, and must stay lively for a whisper. Invented
/// audio at stated levels, read the way the pill is fed: the RMS of each capture buffer, at the
/// two buffer rates a 16 kHz headset and a 48 kHz microphone give.
@Suite("AdaptiveLevelMeter: a nearly silent input looks nearly silent")
struct AdaptiveLevelMeterHonestyTests {
    typealias Audio = SyntheticMicAudio

    /// What the bars did over a stretch: their mean height, the share of readings tall enough to
    /// see (15% of a bar), and the tallest.
    struct Drawn {
        var mean: Double
        var visibleShare: Double
        var top: Double
    }

    /// Feeds a whole recording, then summarises the readings after `skip` seconds.
    private func draw(_ samples: [Float], buffer: Int, skip: Double = 0) -> Drawn {
        var meter = AdaptiveLevelMeter()
        let levels = Audio.readings(samples, buffer: buffer).map { meter.push(rms: $0) }
        let from = min(levels.count - 1, Int(skip * Double(Audio.sampleRate)) / buffer)
        let part = Array(levels[from...])
        return Drawn(mean: part.reduce(0, +) / Double(part.count),
                     visibleShare: Double(part.filter { $0 >= 0.15 }.count) / Double(part.count),
                     top: part.max() ?? 0)
    }

    static let bufferSizes = [1_024, 341]

    @Test("the floor is the speech gate's, about -72 dBFS, and the top never comes under -48 dBFS")
    func anchors() {
        #expect(abs(AdaptiveLevelMeter.audibleFloorDB - -72.04) < 0.01)
        #expect(AdaptiveLevelMeter.minimumPeakDB == -48)
    }

    @Test("digital zeros draw nothing", arguments: bufferSizes)
    func zeros(buffer: Int) {
        #expect(draw(Audio.zeros(4), buffer: buffer).top == 0)
    }

    @Test("zeros and then inaudible hiss draw nothing (the old meter drew this at over half height)", arguments: bufferSizes)
    func hissAfterZeros(buffer: Int) {
        // A headset that sends zeros while its call link comes up, then its idle hiss at -78 dBFS.
        let samples = Audio.zeros(2) + Audio.hiss(4, rms: 0.000_13, seed: 1)
        #expect(draw(samples, buffer: buffer, skip: 2).top == 0)
    }

    @Test("hiss that wobbles around -74 dBFS stays out of sight", arguments: bufferSizes)
    func wobblingHiss(buffer: Int) {
        let samples = Audio.mix(Audio.hiss(6, rms: 0.000_15, seed: 2), Audio.syllables(6, rms: 0.000_15, seed: 3))
        let drawn = draw(samples, buffer: buffer, skip: 1)
        #expect(drawn.mean < 0.05, "mean \(drawn.mean)")
        #expect(drawn.visibleShare < 0.05, "visible \(drawn.visibleShare)")
    }

    @Test("an input 12 dB under a whisper barely moves the bars", arguments: bufferSizes)
    func nearlySilentInput(buffer: Int) {
        // Speech-shaped sound at -66 dBFS (RMS 0.0005) with nothing under it.
        let drawn = draw(Audio.syllables(6, rms: 0.000_5, seed: 4), buffer: buffer, skip: 1)
        #expect(drawn.mean < 0.15, "mean \(drawn.mean)")
        #expect(drawn.top < 0.5, "top \(drawn.top)")
    }

    @Test("a whisper in an ordinary room draws exactly as it did before", arguments: bufferSizes)
    func whisperInARoom(buffer: Int) {
        // Room tone at -68 dBFS, a whisper at -54 dBFS: the numbers the meter was built around.
        let samples = Audio.mix(Audio.hiss(6, rms: 0.000_4, seed: 7), Audio.syllables(6, rms: 0.002, seed: 8))
        let drawn = draw(samples, buffer: buffer, skip: 1)
        #expect(drawn.mean > 0.25, "mean \(drawn.mean)")
        #expect(drawn.visibleShare > 0.45, "visible \(drawn.visibleShare)")
        #expect(drawn.top > 0.65, "top \(drawn.top)")
    }

    @Test("a whisper over a dead-quiet input is still lively", arguments: bufferSizes)
    func whisperOverSilence(buffer: Int) {
        let drawn = draw(Audio.syllables(6, rms: 0.002, seed: 9), buffer: buffer, skip: 1)
        #expect(drawn.mean > 0.25, "mean \(drawn.mean)")
        #expect(drawn.visibleShare > 0.45, "visible \(drawn.visibleShare)")
        #expect(drawn.top > 0.75, "top \(drawn.top)")
    }

    @Test("a very soft whisper, half that level, still shows", arguments: bufferSizes)
    func softWhisper(buffer: Int) {
        let samples = Audio.mix(Audio.hiss(6, rms: 0.000_1, seed: 5), Audio.syllables(6, rms: 0.001, seed: 6))
        let drawn = draw(samples, buffer: buffer, skip: 1)
        #expect(drawn.visibleShare > 0.35, "visible \(drawn.visibleShare)")
        #expect(drawn.top > 0.5, "top \(drawn.top)")
    }

    @Test("normal speech fills the bars", arguments: bufferSizes)
    func normalSpeech(buffer: Int) {
        let samples = Audio.mix(Audio.hiss(6, rms: 0.000_4, seed: 10), Audio.syllables(6, rms: 0.013, seed: 11))
        let drawn = draw(samples, buffer: buffer, skip: 1)
        #expect(drawn.mean > 0.45, "mean \(drawn.mean)")
        #expect(drawn.top == 1)
    }

    @Test("a headset that sends zeros and one short burst draws flat with one blip", arguments: bufferSizes)
    func zerosAndABurst(buffer: Int) {
        // 2.1 s, sound only in the last 0.3 s: the bars are down for the rest of it.
        let samples = Audio.zeros(1.8) + Audio.syllables(0.3, rms: 0.025, seed: 14)
        let drawn = draw(samples, buffer: buffer)
        #expect(drawn.visibleShare < 0.2, "visible \(drawn.visibleShare)")
        #expect(drawn.top > 0.9)
    }

    @Test("the floor cannot be started under the audible floor either")
    func initialFloorIsHeld() {
        var meter = AdaptiveLevelMeter(initialFloorDB: -100, initialPeakDB: -90)
        #expect(meter.push(rms: 0.000_13) == 0, "-78 dBFS draws nothing whatever the meter was started with")
    }
}
