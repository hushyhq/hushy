import Foundation
import Testing
@testable import MurmurCore

/// How much sound a recording held, on invented audio shaped like the cases that matter: a
/// headset that delivered zeros and a short burst (the 2026-10-12 report, rebuilt from its logged
/// numbers), a whisper into a working microphone, and plain silence.
@Suite("Hardly any sound: how much of a recording the microphone delivered")
struct InputHearingTests {
    typealias Audio = SyntheticMicAudio

    /// The three reported recordings as their log lines describe them: a length, the share of
    /// frames with sound, and an overall RMS. The rest is exact zeros (their level floor was 0).
    static let reported: [(seconds: Double, soundShare: Double, rms: Float)] = [
        (2.1, 0.10, 0.0081), (1.6, 0.22, 0.0113), (6.2, 0.05, 0.0010),
    ]

    /// Zeros, then one burst of sound at the end, sized so the whole recording has the logged RMS.
    static func rebuilt(_ recording: (seconds: Double, soundShare: Double, rms: Float), seed: UInt64) -> [Float] {
        let burstSeconds = recording.seconds * recording.soundShare
        let burstRMS = recording.rms / Float(recording.soundShare.squareRoot())
        return Audio.zeros(recording.seconds - burstSeconds) + Audio.hiss(burstSeconds, rms: burstRMS, seed: seed)
    }

    @Test("the reported recordings held a fifth to a third of a second of sound each, and that is hardly any",
          arguments: Array(reported.enumerated()))
    func reportedRecordings(item: (offset: Int, element: (seconds: Double, soundShare: Double, rms: Float))) {
        let samples = Self.rebuilt(item.element, seed: UInt64(item.offset + 1))
        #expect(abs(Audio.rms(samples) - item.element.rms) < item.element.rms * 0.1, "rebuilt at the logged level")
        let hearing = InputHearing.measure(samples)
        #expect(hearing.soundSeconds >= 0.18 && hearing.soundSeconds <= 0.38, "\(hearing.logSummary)")
        #expect(hearing.heardLittle, "\(hearing.logSummary)")
        #expect(!hearing.heardNothing)
        #expect(hearing.deadSeconds > hearing.seconds * 0.7, "the rest was exact zeros")
    }

    @Test("they passed the speech gate, which is why they reached recognition and came back with no words",
          arguments: Array(reported.enumerated()))
    func reportedRecordingsPassTheGate(item: (offset: Int, element: (seconds: Double, soundShare: Double, rms: Float))) {
        let gate = SpeechGate.evaluate(Self.rebuilt(item.element, seed: UInt64(item.offset + 1)))
        #expect(gate.hasSpeech, "active \(gate.activeFrameFraction)")
        #expect(gate.metrics.noiseFloor == 0, "the level floor is exactly zero, as logged")
    }

    @Test("their overall level is no lower than a working whisper's: level alone cannot tell them apart")
    func levelDoesNotSeparate() {
        let whisper = Audio.mix(Audio.hiss(3, rms: 0.0004, seed: 7), Audio.syllables(3, rms: 0.002, seed: 8))
        #expect(Audio.rms(whisper) < Self.reported[0].rms)
        #expect(Audio.rms(whisper) < Self.reported[1].rms)
        #expect(!InputHearing.measure(whisper).heardLittle)
    }

    @Test("a whisper into the Mac's microphone in an ordinary room is heard the whole time")
    func whisperInARoom() {
        let samples = Audio.mix(Audio.hiss(3, rms: 0.0004, seed: 11), Audio.syllables(3, rms: 0.002, seed: 12))
        let hearing = InputHearing.measure(samples)
        #expect(hearing.soundSeconds > 2.9, "\(hearing.logSummary)")
        #expect(hearing.deadSeconds == 0)
        #expect(!hearing.heardLittle)
    }

    @Test("a whisper with nothing at all between its syllables is still heard")
    func whisperOverSilence() {
        let hearing = InputHearing.measure(Audio.syllables(3, rms: 0.002, seed: 13))
        #expect(hearing.soundSeconds > 1.5, "\(hearing.logSummary)")
        #expect(!hearing.heardLittle)
    }

    @Test("a very soft whisper, half the usual level, is still heard")
    func softWhisper() {
        let samples = Audio.mix(Audio.hiss(3, rms: 0.0003, seed: 14), Audio.syllables(3, rms: 0.001, seed: 15))
        #expect(!InputHearing.measure(samples).heardLittle)
    }

    @Test("normal speech is heard")
    func normalSpeech() {
        let samples = Audio.mix(Audio.hiss(2, rms: 0.0004, seed: 16), Audio.syllables(2, rms: 0.013, seed: 17))
        let hearing = InputHearing.measure(samples)
        #expect(!hearing.heardLittle)
        #expect(hearing.quietLeadSeconds == 0)
    }

    @Test("exact zeros are no sound at all")
    func zeros() {
        let hearing = InputHearing.measure(Audio.zeros(2))
        #expect(hearing.heardNothing)
        #expect(hearing.heardLittle)
        #expect(hearing.deadSeconds == 2)
        #expect(hearing.quietLeadSeconds == 2)
        #expect(hearing.logSummary == "sound 0.00 s of 2.00 s · zeros 2.00 s · no sound")
    }

    @Test("hiss under the audible floor is no sound, and is not counted as zeros either")
    func inaudibleHiss() {
        let hearing = InputHearing.measure(Audio.hiss(2, rms: 0.0001, seed: 18))
        #expect(hearing.heardNothing)
        #expect(hearing.deadSeconds == 0)
    }

    @Test("a late start is measured: zeros for 1.5 s, then speech")
    func lateStart() {
        let samples = Audio.zeros(1.5) + Audio.syllables(3, rms: 0.013, seed: 19)
        let hearing = InputHearing.measure(samples)
        #expect(abs(hearing.quietLeadSeconds - 1.5) < 0.05, "\(hearing.logSummary)")
        #expect(abs(hearing.deadSeconds - 1.5) < 0.9, "the gaps between syllables are zeros too")
        #expect(!hearing.heardLittle, "three seconds of speech were heard, whatever came before")
    }

    @Test("a recording under a second is judged against half its own length, not half a second")
    func shortRecording() {
        let heard = InputHearing.measure(Audio.hiss(0.6, rms: 0.01, seed: 20))
        #expect(!heard.heardLittle, "0.6 s of sound in a 0.6 s recording")
        let mostlyNothing = InputHearing.measure(Audio.zeros(0.5) + Audio.hiss(0.1, rms: 0.01, seed: 21))
        #expect(mostlyNothing.heardLittle)
    }

    @Test("nothing recorded is hardly any sound, and never a crash")
    func empty() {
        let hearing = InputHearing.measure([])
        #expect(hearing.seconds == 0)
        #expect(hearing.heardLittle)
        #expect(InputHearing.measure([0.5, 0.5]).heardLittle, "shorter than one frame")
    }

    @Test("the audible floor is the speech gate's own, so the two never disagree about silence")
    func sharedFloor() {
        #expect(InputHearing.audibleFloor == SpeechGate.absoluteFloor)
    }
}
