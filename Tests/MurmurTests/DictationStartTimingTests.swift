import Foundation
import Testing
@testable import Murmur

/// The `dictation start` log line: three times from the key event, once per dictation.
@Suite("Dictation start timing")
struct DictationStartTimingTests {
    private let began = ContinuousClock.now

    @Test("the line gives the pill, the microphone start and the first audio in milliseconds from the key event")
    func line() {
        var timing = DictationStartTiming(began: began)
        timing.captureStarted(at: began + .milliseconds(29))
        timing.pillShown(at: began + .milliseconds(31))
        #expect(timing.audioArrived(at: began + .milliseconds(118)) == "dictation start pillMs=31 captureMs=29 audioMs=118")
    }

    @Test("counted from the key event's own time stamp, so a wait before the controller saw it shows up in pillMs")
    func countsFromTheKeyEvent() {
        let now = Date()
        let clock = ContinuousClock.now
        var timing = DictationStartTiming(keyEvent: now.addingTimeInterval(-0.012), now: now, clock: clock)
        timing.pillShown(at: clock + .milliseconds(3))
        #expect(timing.pillMs == 15)
        var future = DictationStartTiming(keyEvent: now.addingTimeInterval(5), now: now, clock: clock)
        future.pillShown(at: clock + .milliseconds(3))
        #expect(future.pillMs == 3)
    }

    @Test("it is logged once: later audio says nothing, and neither does the end of the recording")
    func once() {
        var timing = DictationStartTiming(began: began)
        timing.captureStarted(at: began + .milliseconds(10))
        timing.pillShown(at: began + .milliseconds(12))
        #expect(timing.audioArrived(at: began + .milliseconds(90)) != nil)
        #expect(timing.audioArrived(at: began + .milliseconds(120)) == nil)
        #expect(timing.ended() == nil)
        #expect(timing.audioMs == 90, "the first audio, not the latest")
    }

    @Test("a recording that ends before any audio arrives still logs, with a dash for the audio")
    func noAudio() {
        var timing = DictationStartTiming(began: began)
        timing.captureStarted(at: began + .milliseconds(40))
        timing.pillShown(at: began + .milliseconds(41))
        #expect(timing.ended() == "dictation start pillMs=41 captureMs=40 audioMs=-")
        #expect(timing.ended() == nil)
        #expect(timing.audioArrived(at: began + .milliseconds(500)) == nil, "too late to count")
    }

    @Test("each mark keeps its first reading, and a clock that reads early never gives a negative time")
    func firstReadingWins() {
        var timing = DictationStartTiming(began: began)
        timing.captureStarted(at: began + .milliseconds(20))
        timing.captureStarted(at: began + .milliseconds(70))
        timing.pillShown(at: began - .milliseconds(5))
        #expect(timing.captureMs == 20)
        #expect(timing.pillMs == 0)
    }

    @Test("the line is numbers and fixed words only", arguments: [0, 7, 250, 4_000])
    func numbersOnly(audio: Int) {
        var timing = DictationStartTiming(began: began)
        timing.captureStarted(at: began + .milliseconds(3))
        timing.pillShown(at: began + .milliseconds(4))
        let line = timing.audioArrived(at: began + .milliseconds(audio)) ?? ""
        let allowed = CharacterSet(charactersIn: "0123456789 =-").union(.letters)
        #expect(line.unicodeScalars.allSatisfy(allowed.contains))
        #expect(line.split(separator: " ").map { $0.split(separator: "=").first.map(String.init) ?? "" }
            == ["dictation", "start", "pillMs", "captureMs", "audioMs"])
    }

    @Test("the pill is told to show before the microphone is opened, and a failed microphone replaces it")
    func pillComesFirst() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Murmur/Dictation/DictationController.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let begin = try #require(source.range(of: "private func begin(mode: Mode"))
        let rest = source[begin.lowerBound...]
        let shown = try #require(rest.range(of: "starting.pillShown()"))
        let opened = try #require(rest.range(of: "continueBegin(mode: mode"))
        #expect(shown.lowerBound < opened.lowerBound, "the pill is shown in begin(), the microphone opens in continueBegin()")
        let start = try #require(source.range(of: "try audio.start"))
        #expect(source[start.lowerBound...].contains("fail(.didNotStart(PillModel.microphoneFailedMessage))"))
    }
}
