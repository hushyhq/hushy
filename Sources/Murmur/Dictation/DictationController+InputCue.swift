import Foundation
import MurmurCore
import os

extension DictationController {
    /// Starts the "is it heard yet" cue for the recording that has just opened its input, and
    /// plays the start sound: at once on most microphones, and on a Bluetooth headset when sound
    /// first arrives, so the sound means "speak now" there too (`InputCueTracker`).
    func beginInputCue() {
        let transport = audio.device?.transport
        let waitsForSound = InputCueTracker.waitsForSound(on: transport)
        if !waitsForSound { sounds.start() }
        inputCue.begin(
            transport: transport, show: { [weak self] in self?.pill.inputCue = $0 },
            onHeard: { [weak self] in if waitsForSound { self?.sounds.start() } },
            // Five seconds of nothing but zeros from a headset: the recording ends here, with the
            // row that says so, instead of taking more of what the person is saying into nothing.
            onGaveUp: { [weak self] in
                Logger(subsystem: "app.hushy", category: "dictation").error(
                    "headset link: no sound after \(Int(InputCueTracker.giveUp.components.seconds)) s · recording ended")
                self?.finish()
            })
    }

    /// Whether a finished recording is only a headset's link coming up (`HeadsetLinkHold`): the
    /// key was released before any sound arrived, or a moment after. Such a recording is not sent
    /// to the recogniser; the pill says the headset was still connecting.
    ///
    /// The silence is read from the recording itself: a Bluetooth input delivers exact zeros
    /// until its link is live, and they are the first samples of what was captured.
    func headsetWasStillConnecting(_ samples: [Float]) -> Bool {
        let transport = (micFacts?().device ?? audio.device)?.transport
        guard transport == .bluetooth else { return false }
        let lead = samples.firstIndex { $0 != 0 }
        let held = HeadsetLinkHold.linkWasStillConnecting(
            transport: transport, recorded: Self.duration(ofSamples: samples.count),
            silenceBeforeSound: lead.map(Self.duration(ofSamples:)))
        let recorded = CaptureTiming.milliseconds(Self.duration(ofSamples: samples.count))
        let first = lead.map { "first sound after \(CaptureTiming.milliseconds(Self.duration(ofSamples: $0))) ms" } ?? "no sound"
        Logger(subsystem: "app.hushy", category: "dictation").notice(
            "headset link: recorded \(recorded) ms · \(first, privacy: .public) · \(held ? "held, nothing sent to the recogniser" : "long enough to recognise", privacy: .public)")
        return held
    }

    private static func duration(ofSamples count: Int) -> Duration {
        .milliseconds(Int((Double(count) / AudioCapture.sampleRate * 1_000).rounded()))
    }
}
