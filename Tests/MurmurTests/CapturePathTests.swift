@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Testing
import MurmurCore
@testable import Murmur

/// Which way a capture reads its microphone, and what a device's IO proc hands over. Fake
/// engines and hand-built buffers; no device is opened.
@Suite("Capture path: a picked microphone is read through its own IO, never through the system's input")
struct CapturePathTests {
    typealias FakeEngine = AudioCaptureLifecycleTests.FakeEngine

    // MARK: The rule

    @Test("nothing picked: the system's engine on the system's input")
    func nothingPicked() {
        #expect(CapturePath.choose(picked: nil, systemDefault: 10, pickedExists: false, strict: false) == .engine)
    }

    @Test("a picked device that is not the system's input: its own IO")
    func pickedOtherThanTheSystemInput() {
        #expect(CapturePath.choose(picked: 20, systemDefault: 10, pickedExists: true, strict: false) == .deviceIO)
        #expect(CapturePath.choose(picked: 20, systemDefault: nil, pickedExists: true, strict: false) == .deviceIO)
    }

    @Test("a picked device that is the system's input: the system's engine, with its noise reduction")
    func pickedIsTheSystemInput() {
        #expect(CapturePath.choose(picked: 10, systemDefault: 10, pickedExists: true, strict: false) == .engine)
    }

    @Test("a picked device that has gone: the system's input, as the microphone rule says")
    func pickedHasGone() {
        #expect(CapturePath.choose(picked: 20, systemDefault: 10, pickedExists: false, strict: false) == .engine)
    }

    @Test("a strict capture is on exactly the device asked for, so always on its own IO")
    func strictIsAlwaysTheDevice() {
        #expect(CapturePath.choose(picked: 10, systemDefault: 10, pickedExists: true, strict: true) == .deviceIO)
        #expect(CapturePath.choose(picked: 20, systemDefault: 10, pickedExists: false, strict: true) == .deviceIO)
    }

    // MARK: Through the capture

    private final class Rig {
        var systemEngines: [FakeEngine] = []
        var deviceEngines: [FakeEngine] = []
        var pending: [@Sendable () -> Void] = []
        let exists = OSAllocatedUnfairLock(initialState: true)
        var capture: AudioCapture!

        init(systemDefault: AudioDeviceID? = 10) {
            var probe = CaptureHardwareProbe.none
            probe.systemDefaultInput = { systemDefault }
            let exists = exists
            probe.deviceExists = { _ in exists.withLock { $0 } }
            capture = AudioCapture(
                makeEngine: { [unowned self] in
                    let engine = FakeEngine()
                    systemEngines.append(engine)
                    return engine
                },
                makeDeviceEngine: { [unowned self] in
                    let engine = FakeEngine()
                    engine.path = .deviceIO
                    engine.selectsDeviceOnTheSystemUnit = false
                    deviceEngines.append(engine)
                    return engine
                },
                probe: probe, scheduleRecovery: { [unowned self] in pending.append($0) })
        }
    }

    @Test("a picked microphone that is not the system's input never touches the system's engine")
    func pickedDeviceUsesItsOwnEngine() throws {
        let rig = Rig()
        rig.capture.preferredDeviceID = 20
        try rig.capture.start { _ in }
        #expect(rig.systemEngines.isEmpty, "the system's input is not opened, moved or read")
        #expect(rig.deviceEngines.count == 1)
        #expect(rig.deviceEngines[0].configureCalls.map(\.device) == [20])
        rig.deviceEngines[0].sendSamples()
        #expect(rig.capture.stop().count == 160)
        #expect(rig.deviceEngines[0].stopped, "and the device is not left running")
    }

    @Test("Automatic over Bluetooth routes the Mac input to its own IO proc")
    @MainActor
    func automaticBuiltInUsesDeviceIO() throws {
        let rig = Rig(systemDefault: 22)
        let mac = AudioCapture.InputDevice(id: 11, name: "MacBook Pro Microphone", transport: .builtIn)
        let headset = AudioCapture.InputDevice(id: 22, name: "Headset", transport: .bluetooth)
        let selector = MicrophoneSelector(probe: { .init(inputs: [mac, headset], systemDefault: headset) },
                                          followsSystemInput: { false })
        let choice = selector.prepare(rig.capture, picked: nil)
        #expect(choice.rule == .builtInOverBluetooth)
        try rig.capture.start { _ in }
        #expect(rig.systemEngines.isEmpty)
        #expect(rig.deviceEngines.first?.configureCalls.first?.device == mac.id)
        rig.capture.stop()
    }

    @Test("Automatic, and a pick that is the system's input, record on the system's engine without moving it")
    func systemInputIsNeverMoved() throws {
        let rig = Rig()
        try rig.capture.start { _ in }
        rig.capture.stop()
        rig.capture.preferredDeviceID = 10
        try rig.capture.start { _ in }
        rig.capture.stop()
        #expect(rig.deviceEngines.isEmpty)
        #expect(rig.systemEngines.map { $0.configureCalls.map(\.device) } == [[nil], [nil]], "no device is selected on the system's unit")
    }

    @Test("the first configuration change on a device's own IO is real: nothing of ours caused it")
    func deviceChangeIsNotMistakenForOurOwn() throws {
        let rig = Rig()
        rig.capture.preferredDeviceID = 20
        try rig.capture.start { _ in }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.deviceEngines[0])
        #expect(rig.deviceEngines.count == 2, "a device that changed is opened again")
        #expect(rig.deviceEngines[0].stopped)
        #expect(rig.capture.restartCount == 1)
        rig.capture.stop()
    }

    @Test("a picked microphone unplugged mid-recording: the recording goes on with the system's input")
    func pickedDeviceGoesAwayMidCapture() throws {
        let rig = Rig()
        rig.capture.preferredDeviceID = 20
        try rig.capture.start { _ in }
        rig.deviceEngines[0].sendSamples()
        rig.exists.withLock { $0 = false }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.deviceEngines[0])
        #expect(rig.deviceEngines.count == 1)
        #expect(rig.deviceEngines[0].stopped, "the dead device's IO is taken down")
        #expect(rig.systemEngines.count == 1)
        #expect(rig.systemEngines[0].configureCalls.map(\.device) == [nil])
        rig.systemEngines[0].sendSamples()
        #expect(rig.capture.stop().count == 320, "what was recorded before is kept")
    }

    @Test("a strict capture goes to the device's own IO and never to the system's input")
    func strictCaptureUsesTheDevice() throws {
        let rig = Rig(systemDefault: 20)
        rig.capture.preferredDeviceID = 20
        rig.capture.strictDevice = true
        try rig.capture.start { _ in }
        #expect(rig.systemEngines.isEmpty)
        #expect(rig.deviceEngines[0].configureCalls.map(\.device) == [20])
        rig.capture.stop()
    }
}
