@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The quiet-microphone row through `DictationController`, with the selector and the recording's
/// facts supplied by the test.
@Suite("Microphone setting through the dictation controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MicrophoneFallbackControllerTests {
    typealias Harness = DictationRecoveryControllerTests.Harness
    typealias Devices = MicrophoneSelector.Devices

    static let mac = MicrophoneSelectorTests.mac
    static let headset = MicrophoneSelectorTests.headset
    static let macInfo = InputDeviceInfo(name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 48_000, channels: 1)

    private func harness(system: AudioCapture.InputDevice = headset) throws -> Harness {
        let harness = try Harness()
        harness.controller.microphones = MicrophoneSelector(probe: {
            Devices(inputs: [Self.mac, Self.headset], systemDefault: system)
        })
        return harness
    }

    @Test("Automatic already chooses the Mac, so a quiet Mac microphone offers no switch")
    func automaticMacHasNoSwitch() throws {
        let harness = try harness()
        let automatic = harness.controller.microphones.resolution(picked: nil)
        #expect(automatic.rule == .builtInOverBluetooth)
        let usable = harness.controller.liveMicFacts().builtInInput
        #expect(usable == "MacBook Pro Microphone")
        harness.controller.micFacts = { .init(device: Self.macInfo, builtInInput: usable, choice: automatic,
                                              automaticInput: Self.mac.name) }
        harness.controller.finishForTests(samples: [Float](repeating: 0, count: 32_000))
        #expect(harness.pill.state == .failed(.quietMic(QuietMic(
            micName: "MacBook Pro Microphone", isSilent: true, betterInput: nil, soundsError: true))))
        #expect(harness.pill.state.recoveryActions == [.dismiss])
    }

    @Test("silence on the Mac's own microphone changes no setting and switches nothing")
    func silenceChangesNothing() throws {
        let harness = try harness(system: Self.mac)
        let automatic = harness.controller.microphones.resolution(picked: nil)
        harness.controller.micFacts = { .init(device: Self.macInfo, builtInInput: "MacBook Pro Microphone", choice: automatic) }
        harness.controller.finishForTests(samples: [Float](repeating: 0, count: 32_000))
        #expect(harness.settings.inputDeviceName == nil)
        #expect(harness.controller.microphones.resolution(picked: nil).rule == .followsSystem)
        if case .failed(.quietMic(let row)) = harness.pill.state { #expect(row.betterInput == nil) }
    }

    @Test("an explicitly picked headset that sends silence offers Automatic")
    func pickedHeadsetOffersAutomatic() throws {
        let harness = try harness()
        let headsetInfo = InputDeviceInfo(name: "Dana's AirPods Pro", transport: .bluetooth, sampleRate: 16_000, channels: 1)
        let picked = harness.controller.microphones.resolution(picked: "Dana's AirPods Pro")
        let usable = harness.controller.liveMicFacts().builtInInput
        harness.controller.micFacts = { .init(device: headsetInfo, builtInInput: usable, choice: picked,
                                              automaticInput: Self.mac.name) }
        harness.controller.finishForTests(samples: [Float](repeating: 0, count: 32_000))
        #expect(harness.pill.state == .failed(.quietMic(QuietMic(
            micName: "Dana's AirPods Pro", isSilent: true, betterInput: nil, soundsError: true,
            headsetSilence: true, offersAutomatic: true))))
        #expect(harness.pill.state.recoveryActions == [.useAutomatic, .dismiss])
        harness.pill.useAutomatic()
        #expect(harness.settings.inputDeviceName == nil)
    }
}
