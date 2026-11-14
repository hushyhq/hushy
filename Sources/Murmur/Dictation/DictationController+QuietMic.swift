import Foundation
import MurmurCore
import os

struct MicrophoneRecoveryOffer {
    var mac: String?
    var automatic: Bool

    static func choose(choice: MicrophoneResolution?, used: String?, builtIn: String?, automatic: String?) -> Self {
        let pickedApart = choice?.rule == .picked && automatic != nil && automatic != used
        let mac = used == builtIn || (pickedApart && automatic == builtIn) ? nil : builtIn
        return Self(mac: mac, automatic: pickedApart && mac == nil)
    }
}

/// A dictation that produced no text because the microphone delivered hardly any sound: the pill
/// says which microphone, and offers the Mac's own when that is another one.
///
/// Everything here runs after a dictation has already failed, so nothing is added between a key
/// release and a paste. It reads the recording's numbers and two device names; it never changes
/// the speech gate's answer, the recognition or the system's audio settings.
extension DictationController {
    /// What the quiet-microphone row needs to know about the Mac's inputs.
    struct MicFacts {
        /// The microphone the recording used (`AudioCapture.device`).
        var device: InputDeviceInfo?
        /// The Mac's built-in microphone by device name, when it has one that can be used now
        /// (not with the lid closed, and not after it sent nothing earlier in this launch).
        var builtInInput: String?
        /// How the recording's device was chosen (`AudioCapture.choice`).
        var choice: MicrophoneResolution?
        /// The Mac's sound input right now, by device name.
        var systemInput: String?
        /// What Automatic would use now, by device name.
        var automaticInput: String?
    }

    private static let micLog = Logger(subsystem: "app.hushy", category: "dictation")

    /// The failure to show for a dictation with no text. `base` is what it would have said; when
    /// the recording held hardly any sound (`InputHearing.heardLittle`) and the microphone is
    /// known, it is the quiet-microphone row instead. The hearing numbers are logged either way.
    ///
    /// No row is a dead end. A microphone taken from the row's own offer is on trial for one
    /// recording: if it too delivers hardly any sound, the setting goes back where it was and the
    /// row says so. A microphone picked in Settings that delivers nothing is offered Automatic.
    ///
    /// `micFacts` replaces the lookups in tests, and `microphones` the device list, so a test never
    /// asks the Mac about its devices.
    func noTextFailure(_ base: DictationFailure, samples: [Float]) -> DictationFailure {
        let hearing = InputHearing.measure(samples)
        Self.micLog.notice("hearing \(hearing.logSummary, privacy: .public)")
        let facts = micFacts?() ?? liveMicFacts()
        if let undone = settleTrial(hearing: hearing, device: facts.device) { return undone }
        guard hearing.heardLittle else { return base }
        // A microphone that has just failed its trial is not offered a second time.
        let builtIn = facts.builtInInput.flatMap { microphones.failedTrials.contains($0) ? nil : $0 }
        let offer = MicrophoneRecoveryOffer.choose(choice: facts.choice, used: facts.device?.name, builtIn: builtIn,
                                                   automatic: facts.automaticInput)
        return QuietMic.failure(base, hearing: hearing, device: facts.device, builtInInput: offer.mac,
                                pickedApartFromSystemInput: offer.automatic)
    }

    /// What a dictation with no text shows (`EmptyDictationTriage`): nothing for an accidental tap,
    /// one line that leaves for a real attempt the microphone heard, the persistent row for a
    /// microphone that sent next to nothing. Runs after the dictation has already failed. One
    /// numbers-only log line says which and why.
    func triageEmpty(gate: SpeechGate.Decision, samples: [Float], duration: TimeInterval) -> EmptyDictationTriage.Outcome {
        let hearing = InputHearing.measure(samples)
        let speech = EmptyDictationTriage.speechSeconds(gate, duration: duration)
        let outcome = EmptyDictationTriage.outcome(duration: duration, speechSeconds: speech, hearing: hearing)
        let numbers = String(format: "%.2f s held, speech %.2f s", duration, speech)
        Self.micLog.notice("no text: \(outcome.rawValue, privacy: .public) (\(numbers, privacy: .public))")
        return outcome
    }

    /// Settles a microphone taken from the row's offer, on the first recording that used it.
    /// Returns the row to show when the pick was undone.
    private func settleTrial(hearing: InputHearing, device: InputDeviceInfo?) -> DictationFailure? {
        guard let trial = microphones.trial, device?.name == trial.picked else { return nil }
        microphones.trial = nil
        guard hearing.heardLittle else { return nil }   // it delivers sound: the pick stays
        microphones.failedTrials.insert(trial.picked)
        settings.inputDeviceName = trial.previous
        Self.micLog.error("microphone taken from the quiet-microphone row delivered hardly any sound: setting put back")
        return .pickUndone(mic: trial.picked, backTo: trial.previous)
    }

    /// The failure for a recording that is a faulty read of the device (`AudioReadFault`) and could
    /// not be repaired (`repairedRead`), or nil for one that could be sound. Such a recording never
    /// reaches the recogniser. The row names
    /// the microphone and is not a dead end: a pick taken from the row's offer is put back, and a
    /// microphone picked in Settings is offered Automatic.
    func unreadableFailure(_ samples: [Float]) -> DictationFailure? {
        guard let fault = AudioReadFault.find(in: samples) else { return nil }
        Self.micLog.error("capture read fault: \(fault.logSummary, privacy: .public) · not sent to the recogniser")
        let facts = micFacts?() ?? liveMicFacts()
        let name = facts.device?.name
        if let trial = microphones.trial, name == trial.picked {
            microphones.trial = nil
            microphones.failedTrials.insert(trial.picked)
            settings.inputDeviceName = trial.previous
            return .micUnreadable(mic: name, next: .putBack)
        }
        let automatic = facts.automaticInput
        let pickedApart = facts.choice?.rule == .picked && automatic != nil && automatic != name
        return .micUnreadable(mic: name, next: pickedApart ? .offerAutomatic : .dictateAgain)
    }

    /// The recording with its faulty stretches silenced (`AudioReadRepair`), or nil when it needs no
    /// repair or cannot be repaired. One numbers-only line says how much was silenced.
    func repairedRead(_ samples: [Float]) -> [Float]? {
        guard let repair = AudioReadRepair.attempt(samples) else { return nil }
        Self.micLog.notice("capture read repaired: \(repair.logSummary, privacy: .public)")
        return repair.samples
    }

    func liveMicFacts() -> MicFacts {
        let devices = microphones.probe()
        return MicFacts(device: audio.device, builtInInput: devices.inputs.first(where: { $0.isBuiltIn && $0.isUsable })?.name,
                        choice: audio.choice, systemInput: devices.systemDefault?.name,
                        automaticInput: MicrophoneResolution.resolve(picked: nil, inventory: devices.inventory,
                            followsSystemInput: microphones.followsSystemInput()).using?.name)
    }

    /// The quiet-microphone row's "Use Mac mic": the named device becomes the Microphone setting,
    /// as if picked in Settings → General, and the next recording opens it. Hushy's own setting
    /// only; the system's default input is left alone. The pick is on trial until a recording
    /// shows it delivers sound (`settleTrial`).
    func useMicrophone(named name: String) {
        Self.micLog.notice("microphone setting changed from the quiet-microphone row")
        microphones.trial = MicrophoneSelector.Trial(picked: name, previous: settings.inputDeviceName)
        settings.inputDeviceName = name
    }

    /// The quiet-microphone row's "Use Automatic": restore Automatic selection.
    func useAutomaticMicrophone() {
        Self.micLog.notice("microphone setting put back on Automatic from the quiet-microphone row")
        microphones.trial = nil
        settings.inputDeviceName = nil
    }
}
