import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// No microphone row is a dead end: a microphone taken from the row's offer is on trial for one
/// recording, and a picked microphone that delivers nothing is offered the way back to Automatic.
/// Through `DictationController` with the recording's facts supplied by the test.
@Suite("Microphone rows are never a dead end", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MicrophoneNoDeadEndTests {
    typealias Harness = DictationRecoveryControllerTests.Harness
    typealias Facts = DictationController.MicFacts

    static let macName = "MacBook Pro Microphone"
    static let headset = InputDeviceInfo(name: "Dana's Headphones", transport: .bluetooth, sampleRate: 16_000, channels: 1)
    static let mac = InputDeviceInfo(name: macName, transport: .builtIn, sampleRate: 48_000, channels: 1)
    static let silence = [Float](repeating: 0, count: 32_000)
    static let pickedMac = MicrophoneResolution(
        rule: .picked, deviceName: macName, using: MicrophoneCandidate(name: macName, transport: .builtIn))

    /// A silent headset as the Mac's sound input, the offer taken: Hushy is now on the Mac's microphone, on trial.
    private func harnessAfterTakingTheOffer() throws -> Harness {
        let harness = try Harness()
        harness.controller.micFacts = { Facts(device: Self.headset, builtInInput: Self.macName, systemInput: Self.headset.name) }
        harness.controller.finishForTests(samples: Self.silence)
        #expect(harness.pill.state.recoveryActions == [.useMacMic, .dismiss])
        harness.pill.useOfferedMic()
        #expect(harness.settings.inputDeviceName == Self.macName)
        #expect(harness.controller.microphones.trial == .init(picked: Self.macName, previous: nil))
        harness.controller.micFacts = {
            Facts(device: Self.mac, builtInInput: Self.macName, choice: Self.pickedMac, systemInput: Self.headset.name)
        }
        return harness
    }

    @Test("the offered microphone sends nothing either: Hushy puts the setting back itself and says so")
    func offeredMicrophoneThatFailsIsUndone() throws {
        let harness = try harnessAfterTakingTheOffer()
        harness.controller.finishForTests(samples: Self.silence)
        #expect(harness.pill.state == .failed(.pickUndone(mic: Self.macName, backTo: nil)))
        #expect(harness.settings.inputDeviceName == nil, "back on Automatic, not stuck on a microphone that does not work")
        #expect(harness.controller.microphones.trial == nil)
        #expect(DictationFailure.pickUndone(mic: Self.macName, backTo: nil).line
            == "MacBook Pro Microphone sent no sound · back to Automatic")
        #expect(!harness.controller.isBusy, "the next dictation is not blocked")
    }

    @Test("a microphone that failed its trial is not offered again in this launch")
    func failedMicrophoneIsNotOfferedAgain() throws {
        let harness = try harnessAfterTakingTheOffer()
        harness.controller.finishForTests(samples: Self.silence)
        harness.controller.micFacts = { Facts(device: Self.headset, builtInInput: Self.macName, systemInput: Self.headset.name) }
        harness.controller.finishForTests(samples: Self.silence)
        #expect(harness.pill.state == .failed(.quietMic(
            QuietMic(micName: Self.headset.name, isSilent: true, betterInput: nil, soundsError: true, headsetSilence: true))))
        #expect(harness.pill.state.recoveryActions == [.dismiss])
    }

    @Test("the offered microphone delivers speech: the pick stays and is no longer on trial")
    func offeredMicrophoneThatWorksStays() async throws {
        let harness = try harnessAfterTakingTheOffer()
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(harness.controller.microphones.trial == nil)
        #expect(harness.settings.inputDeviceName == Self.macName)
        #expect(await harness.eventually { harness.pill.state == .failed(.transcription(recordingKept: true)) },
                "the harness has no model; reaching recognition is the proof it went on")
        #expect(harness.settings.inputDeviceName == Self.macName)
    }

    @Test("sound came in and no words were found: the microphone works, so the pick stays")
    func soundWithoutWordsKeepsThePick() throws {
        let harness = try harnessAfterTakingTheOffer()
        #expect(harness.controller.noTextFailure(.noWords, samples: Harness.speech) == .noWords)
        #expect(harness.controller.microphones.trial == nil)
        #expect(harness.settings.inputDeviceName == Self.macName)
    }

    @Test("the previous pick comes back, not Automatic, when the trial replaced a pick")
    func undoRestoresThePreviousPick() throws {
        let harness = try Harness()
        harness.settings.inputDeviceName = Self.headset.name
        harness.controller.useMicrophone(named: Self.macName)
        harness.controller.micFacts = { Facts(device: Self.mac, builtInInput: Self.macName, choice: Self.pickedMac) }
        harness.controller.finishForTests(samples: Self.silence)
        #expect(harness.settings.inputDeviceName == Self.headset.name)
        #expect(harness.pill.state == .failed(.pickUndone(mic: Self.macName, backTo: Self.headset.name)))
        #expect(DictationFailure.pickUndone(mic: Self.macName, backTo: Self.headset.name).detail == "back to your pick")
    }

    @Test("a picked Mac microphone that sends nothing is not offered Automatic when Automatic uses it too")
    func pickedMacHasNoAutomaticOffer() throws {
        let harness = try Harness()
        harness.settings.inputDeviceName = Self.macName
        harness.controller.micFacts = {
            Facts(device: Self.mac, builtInInput: Self.macName, choice: Self.pickedMac,
                  systemInput: Self.headset.name, automaticInput: Self.macName)
        }
        harness.controller.finishForTests(samples: Self.silence)
        let row = QuietMic(micName: Self.macName, isSilent: true, betterInput: nil, soundsError: true)
        #expect(harness.pill.state == .failed(.quietMic(row)))
        #expect(DictationFailure.quietMic(row).line == "No sound came in · check MacBook Pro Microphone")
        #expect(harness.pill.state.recoveryActions == [.dismiss])
        #expect(RecoveryAction.useAutomatic.title == "Use Automatic")
        harness.pill.perform(.useAutomatic)
        #expect(harness.settings.inputDeviceName == Self.macName)
        #expect(harness.pill.state == .failed(.quietMic(row)))
        #expect(DictationFailure.usingAutomatic.line == "Using Automatic · dictate again")
        #expect(DictationFailure.usingAutomatic.isGoodNews)
        #expect(harness.pill.state.recoveryActions == [.dismiss])
    }

    @Test("a picked microphone that is also the Mac's sound input: Automatic would change nothing, so it is not offered")
    func noOfferWhenAutomaticIsTheSameMicrophone() throws {
        let harness = try Harness()
        harness.settings.inputDeviceName = Self.macName
        harness.controller.micFacts = {
            Facts(device: Self.mac, builtInInput: Self.macName, choice: Self.pickedMac, systemInput: Self.macName)
        }
        harness.controller.finishForTests(samples: Self.silence)
        #expect(harness.pill.state == .failed(.quietMic(
            QuietMic(micName: Self.macName, isSilent: true, betterInput: nil, soundsError: true))))
        #expect(harness.pill.state.recoveryActions == [.dismiss])
        harness.pill.useAutomatic()
        #expect(harness.settings.inputDeviceName == Self.macName, "nothing was offered, so nothing changes")
    }

    @Test("Automatic on a silent microphone is not offered Automatic")
    func automaticIsNotOfferedAutomatic() throws {
        let harness = try Harness()
        let automatic = MicrophoneResolution(rule: .followsSystem, deviceName: nil, using: MicrophoneCandidate(name: Self.macName, transport: .builtIn))
        harness.controller.micFacts = { Facts(device: Self.mac, builtInInput: Self.macName, choice: automatic, systemInput: Self.macName) }
        harness.controller.finishForTests(samples: Self.silence)
        #expect(harness.pill.state.recoveryActions == [.dismiss])
    }
}

/// A recording that is a faulty read of the device never reaches the recogniser, and its row is
/// not a dead end either.
@Suite("A faulty read of the microphone is never recognised", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct UnreadableRecordingTests {
    typealias Harness = DictationRecoveryControllerTests.Harness
    typealias Facts = DictationController.MicFacts
    typealias Rows = MicrophoneNoDeadEndTests

    /// Two seconds of a clear tone, as speech would pass the gate, with a burst no microphone delivers
    /// in a small part of it: it is repaired (`AudioReadRepair`) and the recording goes on.
    static let confinedBurst: [Float] = {
        var samples = Harness.speech
        for index in 8_000..<8_400 { samples[index] = index.isMultiple(of: 2) ? 11.7 : -9.3 }
        return samples
    }()

    /// The same tone with bursts all through it: too much of it is bad to repair, so it is a fault.
    static let burst: [Float] = {
        var samples = Harness.speech
        for index in stride(from: 1_000, to: samples.count, by: 700) { samples[index] = index.isMultiple(of: 2) ? 11.7 : -9.3 }
        return samples
    }()

    @Test("a burst in a small part of the recording is repaired: it reaches recognition, and no unreadable row is shown")
    func confinedBurstIsRepaired() async throws {
        let harness = try Harness()
        harness.controller.micFacts = { Facts(device: Rows.mac, builtInInput: Rows.macName, systemInput: Rows.macName) }
        #expect(AudioReadFault.find(in: Self.confinedBurst) != nil)
        harness.controller.finishForTests(samples: Self.confinedBurst)
        // The test engine has no model, so recognition throws; the row is that one, not "Couldn't read".
        #expect(await harness.eventually { harness.pill.state == .failed(.transcription(recordingKept: true)) && harness.rows.count == 1 })
        #expect(!harness.controller.isBusy)
    }

    @Test("a burst far above full scale on a picked Mac microphone is not recognised or offered the same input")
    func burstOnAPickedMicrophone() async throws {
        let harness = try Harness()
        harness.settings.inputDeviceName = Rows.macName
        harness.controller.micFacts = {
            Facts(device: Rows.mac, builtInInput: Rows.macName, choice: Rows.pickedMac,
                  systemInput: Rows.headset.name, automaticInput: Rows.macName)
        }
        #expect(SpeechGate.evaluate(Self.burst).hasSpeech, "the gate alone would have let it through, as it did")
        harness.controller.finishForTests(samples: Self.burst)
        #expect(harness.pill.state == .failed(.micUnreadable(mic: Rows.macName, next: .dictateAgain)))
        #expect(DictationFailure.micUnreadable(mic: Rows.macName, next: .dictateAgain).line
                == "Couldn't read MacBook Pro Microphone · dictate again")
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.pill.state == .failed(.micUnreadable(mic: Rows.macName, next: .dictateAgain)),
                "recognition never ran, so its failure never replaced the row")
        #expect(harness.rows.isEmpty)
        #expect(!harness.controller.isBusy)
        #expect(harness.pill.state.recoveryActions == [.dismiss])
        harness.pill.perform(.useAutomatic)
        #expect(harness.settings.inputDeviceName == Rows.macName)
    }

    @Test("the same on the Mac's sound input: the row says so and there is nothing to switch")
    func burstOnTheSystemInput() throws {
        let harness = try Harness()
        harness.controller.micFacts = { Facts(device: Rows.mac, builtInInput: Rows.macName, systemInput: Rows.macName) }
        harness.controller.finishForTests(samples: Self.burst)
        #expect(harness.pill.state == .failed(.micUnreadable(mic: Rows.macName, next: .dictateAgain)))
        #expect(DictationFailure.micUnreadable(mic: Rows.macName, next: .dictateAgain).line
            == "Couldn't read MacBook Pro Microphone · dictate again")
    }

    @Test("a microphone just taken from the row's offer that reads as garbage is put back, and not offered again")
    func burstOnATrialPick() throws {
        let harness = try Harness()
        harness.controller.useMicrophone(named: Rows.macName)
        harness.controller.micFacts = {
            Facts(device: Rows.mac, builtInInput: Rows.macName, choice: Rows.pickedMac, systemInput: Rows.headset.name)
        }
        harness.controller.finishForTests(samples: Self.burst)
        #expect(harness.pill.state == .failed(.micUnreadable(mic: Rows.macName, next: .putBack)))
        #expect(harness.settings.inputDeviceName == nil)
        #expect(harness.controller.microphones.failedTrials == [Rows.macName])
    }

    @Test("values that are not numbers are a faulty read too, with no microphone known")
    func notNumbers() throws {
        let harness = try Harness()
        var samples = Harness.speech
        for index in stride(from: 100, to: samples.count, by: 500) { samples[index] = .nan }
        harness.controller.finishForTests(samples: samples)
        #expect(harness.pill.state == .failed(.micUnreadable(mic: nil, next: .dictateAgain)))
        #expect(DictationFailure.micUnreadable(mic: nil, next: .dictateAgain).line == "Couldn't read the microphone · dictate again")
    }

    @Test("the recogniser itself refuses audio that is not numbers, whoever recorded it")
    func recogniserRefusesNotNumbers() async throws {
        let harness = try Harness()
        await #expect(throws: SpeechEngine.EngineError.unreadableAudio) {
            _ = try await harness.controller.speech.transcribe([0.1, .nan, 0.2])
        }
    }
}
