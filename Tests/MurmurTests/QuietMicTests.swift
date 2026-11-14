import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// A dictation that produced no text because the microphone delivered hardly any sound: the row
/// names the microphone, offers the Mac's own in one tap when that is another input, and never
/// says the person spoke too softly. Device names here are invented.
@Suite("The quiet-microphone row")
@MainActor
struct QuietMicTests {
    nonisolated static let headset = InputDeviceInfo(name: "Example Buds Pro", transport: .bluetooth, sampleRate: 16_000, channels: 1)
    nonisolated static let mac = InputDeviceInfo(name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 48_000, channels: 1)
    nonisolated static let deskMic = InputDeviceInfo(name: "Desk Mic", transport: .usb, sampleRate: 48_000, channels: 1)

    /// A fifth of a second of sound in two seconds, the rest exact zeros.
    nonisolated static let little = InputHearing(seconds: 2.1, soundSeconds: 0.22, deadSeconds: 1.88, quietLeadSeconds: 1.88)
    nonisolated static let none = InputHearing(seconds: 2, soundSeconds: 0, deadSeconds: 2, quietLeadSeconds: 2)
    nonisolated static let plenty = InputHearing(seconds: 3, soundSeconds: 3, deadSeconds: 0, quietLeadSeconds: 0)

    nonisolated static let bases: [DictationFailure] = [.noWords, .nothingToWrite, .heardNothing, .micSilent]

    // MARK: Which row

    @Test("hardly any sound from a headset, with the Mac's microphone there: the row names the headset and offers the Mac's",
          arguments: bases)
    func headsetWithMacMic(base: DictationFailure) {
        let failure = QuietMic.failure(base, hearing: Self.little, device: Self.headset, builtInInput: Self.mac.name)
        #expect(failure == .quietMic(QuietMic(micName: "Example Buds Pro", isSilent: false, betterInput: "MacBook Pro Microphone",
                                              soundsError: base.playsErrorSound)))
        #expect(failure.line == "Hardly any sound from Example Buds Pro")
        #expect(failure.micOffer == "MacBook Pro Microphone")
    }

    @Test("no sound at all says no sound")
    func silentHeadset() {
        let failure = QuietMic.failure(.micSilent, hearing: Self.none, device: Self.headset, builtInInput: Self.mac.name)
        #expect(failure.line == "Example Buds Pro sent only silence", "a headset's exact zeros are named for what they are")
        #expect(failure.micOffer == "MacBook Pro Microphone")
        #expect(failure.accessibilityText.contains("Check it is not muted, or reconnect it."))
        let desk = QuietMic.failure(.micSilent, hearing: Self.none, device: Self.deskMic, builtInInput: Self.mac.name)
        #expect(desk.line == "No sound from Desk Mic", "any other microphone keeps the general row")
        let alone = QuietMic.failure(.micSilent, hearing: Self.none, device: Self.headset, builtInInput: nil)
        #expect(alone.line == "Example Buds Pro sent only silence · reconnect it")
    }

    @Test("a recording that was heard keeps the failure it had, whatever the microphone", arguments: bases)
    func heardKeepsItsFailure(base: DictationFailure) {
        #expect(QuietMic.failure(base, hearing: Self.plenty, device: Self.headset, builtInInput: Self.mac.name) == base)
        #expect(QuietMic.failure(base, hearing: Self.plenty, device: Self.mac, builtInInput: Self.mac.name) == base)
    }

    @Test("a microphone that could not be named keeps the failure it had: the row never guesses a name", arguments: bases)
    func unknownDeviceKeepsItsFailure(base: DictationFailure) {
        #expect(QuietMic.failure(base, hearing: Self.little, device: nil, builtInInput: Self.mac.name) == base)
    }

    @Test("on the Mac's own microphone there is nothing better to offer: the row says which microphone to check")
    func macMicInUse() {
        let failure = QuietMic.failure(.noWords, hearing: Self.little, device: Self.mac, builtInInput: Self.mac.name)
        #expect(failure.line == "Hardly any sound came in · check MacBook Pro Microphone")
        #expect(failure.micOffer == nil)
        let silent = QuietMic.failure(.micSilent, hearing: Self.none, device: Self.mac, builtInInput: Self.mac.name)
        #expect(silent.line == "No sound came in · check MacBook Pro Microphone")
    }

    @Test("a Mac with no microphone of its own has nothing to offer either")
    func noBuiltIn() {
        let failure = QuietMic.failure(.heardNothing, hearing: Self.little, device: Self.deskMic, builtInInput: nil)
        #expect(failure.line == "Hardly any sound came in · check Desk Mic")
        #expect(failure.micOffer == nil)
    }

    @Test("a USB microphone gets the offer too: any input that is not the Mac's own")
    func usbMic() {
        let failure = QuietMic.failure(.noWords, hearing: Self.little, device: Self.deskMic, builtInInput: Self.mac.name)
        #expect(failure.line == "Hardly any sound from Desk Mic")
        #expect(failure.micOffer == "MacBook Pro Microphone")
    }

    @Test("a device that is not built-in but carries the built-in's name is never offered itself")
    func neverOffersItself() {
        let odd = InputDeviceInfo(name: "MacBook Pro Microphone", transport: .aggregate, sampleRate: 48_000, channels: 1)
        #expect(QuietMic.failure(.noWords, hearing: Self.little, device: odd, builtInInput: "MacBook Pro Microphone").micOffer == nil)
    }

    // MARK: The words

    @Test("the words name the microphone and never the person", arguments: bases)
    func noBlame(base: DictationFailure) {
        for device in [Self.headset, Self.mac, Self.deskMic] {
            for hearing in [Self.little, Self.none] {
                let failure = QuietMic.failure(base, hearing: hearing, device: device, builtInInput: Self.mac.name)
                let words = (failure.line + " " + failure.accessibilityText).lowercased()
                for blaming in ["louder", "you ", "your ", "speak", "closer", "try harder"] {
                    #expect(!words.contains(blaming), "\(failure.line)")
                }
                #expect(words.contains(device.name.lowercased()), "the microphone is named: \(failure.line)")
            }
        }
    }

    @Test("a long device name is cut in the middle, so the owner and the kind of device both stay readable")
    func longNames() {
        let long = "Alexandria's Example Buds Pro Max (2nd generation)"
        let shown = QuietMic.rowName(long)
        #expect(shown.count <= QuietMic.rowNameLimit)
        #expect(shown.hasPrefix("Alexandria's"))
        #expect(shown.hasSuffix("generation)"))
        #expect(shown.contains("…"))
        #expect(QuietMic.rowName("Example Buds Pro") == "Example Buds Pro", "a short name is shown whole")
        #expect(QuietMic.rowName("Line\nBreak  Mic") == "Line Break Mic", "and never breaks the row")
    }

    @Test("VoiceOver hears the same words, and what the button does")
    func accessibility() {
        let offer = DictationFailure.quietMic(QuietMic(micName: "Example Buds Pro", isSilent: false, betterInput: "MacBook Pro Microphone"))
        #expect(offer.accessibilityText
                == "Hardly any sound from Example Buds Pro. Press Use Mac mic to record from MacBook Pro Microphone.")
        let check = DictationFailure.quietMic(QuietMic(micName: "MacBook Pro Microphone", isSilent: false, betterInput: nil))
        #expect(check.accessibilityText == "Hardly any sound came in. Check MacBook Pro Microphone.")
        #expect(DictationFailure.micSwitched(to: "MacBook Pro Microphone").accessibilityText
                == "Using MacBook Pro Microphone. Dictate again.")
    }

    @Test("the row sounds the error tone exactly when the failure it stands in for did", arguments: bases)
    func sound(base: DictationFailure) {
        for hearing in [Self.little, Self.none] {
            let failure = QuietMic.failure(base, hearing: hearing, device: Self.headset, builtInInput: Self.mac.name)
            #expect(failure.playsErrorSound == base.playsErrorSound, "\(base.line)")
        }
        #expect(!DictationFailure.micSwitched(to: "MacBook Pro Microphone").playsErrorSound)
    }

    @Test("a key pressed by accident in a silent room is not an error tone, whatever the row says")
    func silentPressIsQuiet() {
        let failure = QuietMic.failure(.heardNothing, hearing: Self.none, device: Self.mac, builtInInput: Self.mac.name)
        #expect(failure.line == "No sound came in · check MacBook Pro Microphone")
        #expect(!failure.playsErrorSound)
    }

    @Test("the row never offers Try again: the same audio would give the same nothing")
    func noRetry() {
        #expect(!DictationFailure.quietMic(QuietMic(micName: "Example Buds Pro", isSilent: false, betterInput: "MacBook Pro Microphone")).canRetry)
        #expect(!DictationFailure.micSwitched(to: "MacBook Pro Microphone").canRetry)
    }

    // MARK: One tap

    @Test("Use Mac mic hands the device name to the app once, and the row says which microphone is in use")
    func oneTap() {
        let pill = PillModel()
        var asked: [String] = []
        pill.onUseMicrophone = { asked.append($0) }
        pill.present(failure: .quietMic(QuietMic(micName: "Example Buds Pro", isSilent: false, betterInput: "MacBook Pro Microphone")))
        #expect(pill.state.recoveryActions == [.useMacMic, .dismiss])
        pill.useOfferedMic()
        #expect(asked == ["MacBook Pro Microphone"])
        #expect(pill.state == .failed(.micSwitched(to: "MacBook Pro Microphone")))
        #expect(DictationFailure.micSwitched(to: "MacBook Pro Microphone").line == "Using MacBook Pro Microphone · dictate again")
        #expect(DictationFailure.micSwitched(to: "MacBook Pro Microphone").isGoodNews, "a tick, not the red dot")
        #expect(pill.state.recoveryActions == [.dismiss], "the row it becomes offers nothing more")
        pill.useOfferedMic()
        #expect(asked.count == 1, "a second tap does nothing")
        pill.dismissFailure()
        #expect(pill.state == .idle)
    }

    @Test("the tap does nothing on a row with no offer, or on any other row")
    func noOfferNoTap() {
        let pill = PillModel()
        var asked: [String] = []
        pill.onUseMicrophone = { asked.append($0) }
        pill.present(failure: .quietMic(QuietMic(micName: "MacBook Pro Microphone", isSilent: false, betterInput: nil)))
        #expect(pill.state.recoveryActions == [.dismiss])
        pill.useOfferedMic()
        pill.perform(.useMacMic)
        pill.present(failure: .noWords)
        pill.useOfferedMic()
        pill.state = .listening
        pill.useOfferedMic()
        #expect(asked.isEmpty)
        #expect(pill.state == .listening)
    }

    @Test("VoiceOver can take the offer by name")
    func voiceOverAction() {
        let pill = PillModel()
        var asked: [String] = []
        pill.onUseMicrophone = { asked.append($0) }
        pill.present(failure: .quietMic(QuietMic(micName: "Example Buds Pro", isSilent: false, betterInput: "MacBook Pro Microphone")))
        #expect(RecoveryAction.useMacMic.title == "Use Mac mic")
        pill.perform(.useMacMic)
        #expect(asked == ["MacBook Pro Microphone"])
    }

    @Test("the next dictation replaces either row at once")
    func replaced() {
        let pill = PillModel()
        pill.present(failure: .quietMic(QuietMic(micName: "Example Buds Pro", isSilent: false, betterInput: "MacBook Pro Microphone")))
        pill.state = .listening
        #expect(pill.state == .listening)
        pill.present(failure: .micSwitched(to: "MacBook Pro Microphone"))
        pill.state = .listening
        #expect(pill.state == .listening)
    }
}

/// The same row through `DictationController`: a recording handed in through its test seam, with
/// the microphone facts supplied by the test, so no hardware and no system setting is touched.
/// Settings live in a throwaway defaults suite.
@Suite("The quiet-microphone row through the dictation controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct QuietMicControllerTests {
    typealias Harness = DictationRecoveryControllerTests.Harness

    private func facts(_ device: InputDeviceInfo?, builtIn: String? = QuietMicTests.mac.name) -> @MainActor () -> DictationController.MicFacts {
        { DictationController.MicFacts(device: device, builtInInput: builtIn) }
    }

    /// 1.8 s of exact zeros and a 0.3 s tone: what a headset sends while its call link comes up.
    static let lateBurst: [Float] = [Float](repeating: 0, count: 28_800)
        + (0..<4_800).map { 0.05 * sin(2 * Float.pi * 440 * Float($0) / 16_000) }

    @Test("exact zeros from a headset: the row names it, offers the Mac's microphone, and the tap changes Hushy's setting only")
    func zerosFromAHeadset() throws {
        let harness = try Harness()
        harness.controller.micFacts = facts(QuietMicTests.headset)
        #expect(harness.settings.inputDeviceName == nil, "System default to begin with")
        harness.controller.finishForTests(samples: [Float](repeating: 0, count: 32_000))
        #expect(harness.pill.state == .failed(.quietMic(
            QuietMic(micName: "Example Buds Pro", isSilent: true, betterInput: "MacBook Pro Microphone", soundsError: true,
                     headsetSilence: true))))
        #expect(!harness.controller.isBusy, "the next dictation is not blocked")
        harness.pill.useOfferedMic()
        #expect(harness.settings.inputDeviceName == "MacBook Pro Microphone")
        #expect(harness.pill.state == .failed(.micSwitched(to: "MacBook Pro Microphone")))
    }

    @Test("sound too faint to hear, on the Mac's own microphone: the row says which microphone to check and offers nothing")
    func faintOnTheMacMic() throws {
        let harness = try Harness()
        harness.controller.micFacts = facts(QuietMicTests.mac)
        harness.controller.finishForTests(samples: [Float](repeating: 0.000_1, count: 32_000))
        #expect(harness.pill.state == .failed(.quietMic(
            QuietMic(micName: "MacBook Pro Microphone", isSilent: true, betterInput: nil))))
        harness.pill.useOfferedMic()
        #expect(harness.settings.inputDeviceName == nil, "nothing was offered, so nothing changes")
    }

    @Test("with no microphone known, the rows are the ones there were before")
    func unknownMicrophone() throws {
        let harness = try Harness()
        harness.controller.micFacts = facts(nil)
        harness.controller.finishForTests(samples: [Float](repeating: 0.000_1, count: 32_000))
        #expect(harness.pill.state == .failed(.heardNothing))
        harness.controller.finishForTests(samples: [Float](repeating: 0, count: 32_000))
        #expect(harness.pill.state == .failed(.micSilent))
    }

    @Test("recognition that found no words in a late burst from a headset is the quiet-microphone row, not a request to speak up")
    func noWordsInALateBurst() throws {
        let harness = try Harness()
        harness.controller.micFacts = facts(QuietMicTests.headset)
        #expect(SpeechGate.evaluate(Self.lateBurst).hasSpeech, "it passes the speech gate, as the reported recordings did")
        let failure = harness.controller.noTextFailure(.noWords, samples: Self.lateBurst)
        #expect(failure.line == "Hardly any sound from Example Buds Pro")
        #expect(failure.micOffer == "MacBook Pro Microphone")
        #expect(!failure.playsErrorSound, "nothing heard is not an error tone")
        #expect(harness.controller.noTextFailure(.nothingToWrite, samples: Self.lateBurst) == failure)
    }

    @Test("a recording that was heard keeps its own failure through the controller")
    func heardRecording() throws {
        let harness = try Harness()
        harness.controller.micFacts = facts(QuietMicTests.headset)
        #expect(harness.controller.noTextFailure(.noWords, samples: Harness.speech) == .noWords)
        #expect(harness.controller.noTextFailure(.nothingToWrite, samples: Harness.speech) == .nothingToWrite)
    }
}
