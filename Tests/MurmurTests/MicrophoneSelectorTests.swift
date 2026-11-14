@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The automatic microphone rule wired into the app: a fake device list and fake engines, so no
/// device is opened, no system setting is read or changed, and nothing depends on this Mac.
@Suite("Microphone selector: which device a capture opens")
@MainActor
struct MicrophoneSelectorTests {
    typealias Devices = MicrophoneSelector.Devices
    typealias FakeEngine = AudioCaptureLifecycleTests.FakeEngine

    nonisolated static let mac = AudioCapture.InputDevice(id: 11, name: "MacBook Pro Microphone", transport: .builtIn)
    nonisolated static let headset = AudioCapture.InputDevice(id: 22, name: "Dana's AirPods Pro", transport: .bluetooth)
    nonisolated static let desk = AudioCapture.InputDevice(id: 33, name: "Desk Mic", transport: .usb)

    private func selector(inputs: [AudioCapture.InputDevice], system: AudioCapture.InputDevice?) -> MicrophoneSelector {
        MicrophoneSelector(probe: { Devices(inputs: inputs, systemDefault: system) })
    }

    /// A capture on fake engines that records what each engine was asked to open.
    private func capture(_ engines: Engines) -> AudioCapture {
        AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.made.append(engine)
            return engine
        })
    }

    final class Engines { var made: [FakeEngine] = [] }

    // MARK: What the capture opens

    @Test("Automatic with a Bluetooth system input opens the built-in device")
    func automaticOpensTheSystemInput() throws {
        let engines = Engines()
        let audio = capture(engines)
        audio.preferredDeviceID = 11
        let chosen = selector(inputs: [Self.mac, Self.headset], system: Self.headset).prepare(audio, picked: nil)
        #expect(chosen.rule == .builtInOverBluetooth)
        #expect(chosen.using?.name == "MacBook Pro Microphone")
        #expect(audio.preferredDeviceID == 11)
        try audio.start { _ in }
        #expect(engines.made.first?.configureCalls.first?.device == 11)
        #expect(audio.choice?.logWord == "auto: built-in, system input is bluetooth")
        audio.stop()
    }

    @Test("Automatic asks for no device on non-Bluetooth system inputs", arguments: [mac, desk])
    func followsSystem(system: AudioCapture.InputDevice) {
        let audio = capture(Engines())
        let chosen = selector(inputs: [Self.mac, Self.desk, Self.headset], system: system).prepare(audio, picked: nil)
        #expect(chosen.rule == .followsSystem)
        #expect(audio.preferredDeviceID == nil)
    }

    @Test("the Mac's microphone picked with a headset as the system input is opened by its id")
    func pickedMac() throws {
        let engines = Engines()
        let audio = capture(engines)
        let chosen = selector(inputs: [Self.mac, Self.headset], system: Self.headset).prepare(audio, picked: "MacBook Pro Microphone")
        #expect(chosen.rule == .picked)
        #expect(chosen.headsetLeftAlone?.name == "Dana's AirPods Pro")
        #expect(audio.preferredDeviceID == 11)
        try audio.start { _ in }
        #expect(engines.made.first?.configureCalls.first?.device == 11)
        #expect(audio.choice?.logWord == "picked")
        audio.stop()
    }

    @Test("a picked headset is opened by its id")
    func pickedHeadset() {
        let audio = capture(Engines())
        let chosen = selector(inputs: [Self.mac, Self.headset], system: Self.mac).prepare(audio, picked: "Dana's AirPods Pro")
        #expect(chosen.rule == .picked)
        #expect(audio.preferredDeviceID == 22)
    }

    @Test("a picked device that is gone opens the system default, as before")
    func pickedMissing() {
        let audio = capture(Engines())
        audio.preferredDeviceID = 99
        let chosen = selector(inputs: [Self.mac, Self.headset], system: Self.headset).prepare(audio, picked: "Desk Mic")
        #expect(chosen.rule == .pickedMissing)
        #expect(audio.preferredDeviceID == nil, "a stale id from an earlier recording is cleared")
    }

    @Test("the internal flag restores following the Bluetooth system input")
    func legacyRule() {
        let audio = capture(Engines())
        let microphones = MicrophoneSelector(
            probe: { Devices(inputs: [Self.mac, Self.headset], systemDefault: Self.headset) },
            followsSystemInput: { true })
        let chosen = microphones.prepare(audio, picked: nil)
        #expect(chosen.rule == .followsSystem)
        #expect(audio.preferredDeviceID == nil)
        #expect(chosen.logWord == "auto: system input")
    }

    @Test("an unreadable built-in input is skipped for a USB input")
    func unreadableBuiltIn() {
        let unavailable = AudioCapture.InputDevice(id: 11, name: Self.mac.name, transport: .builtIn, isUsable: false)
        let audio = capture(Engines())
        let chosen = selector(inputs: [unavailable, Self.headset, Self.desk], system: Self.headset)
            .prepare(audio, picked: nil)
        #expect(chosen.rule == .wiredFallback)
        #expect(audio.preferredDeviceID == Self.desk.id)
    }

    @Test("each prepare reads the devices again: a headset that becomes the system input is used from the next recording")
    func readsEachTime() {
        var system = Self.mac
        let microphones = MicrophoneSelector(probe: { Devices(inputs: [Self.mac, Self.headset], systemDefault: system) })
        let audio = capture(Engines())
        #expect(microphones.prepare(audio, picked: nil).using?.name == "MacBook Pro Microphone")
        system = Self.headset
        #expect(microphones.prepare(audio, picked: nil).using?.name == "MacBook Pro Microphone")
        #expect(audio.preferredDeviceID == 11)
    }
}
