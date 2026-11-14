@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import HushyObjC
import Testing
@testable import Murmur

/// The capture's start and restart path when the audio system misbehaves: a tap the graph
/// refuses, configuration changes while starting, a format that moves, and a Mac that never
/// settles. Fake engines and a recovery timer the test fires by hand; no device is opened.
@Suite("Audio capture: no crash and no restart storm when devices change")
struct AudioCaptureRestartTests {
    typealias FakeEngine = AudioCaptureLifecycleTests.FakeEngine

    /// A capture on fake engines. `prepare` sets each engine up as it is made, by its number.
    private final class Rig {
        var engines: [FakeEngine] = []
        var pending: [@Sendable () -> Void] = []
        var capture: AudioCapture!

        init(probe: CaptureHardwareProbe? = nil, prepare: @escaping (Int, FakeEngine) -> Void = { _, _ in }) {
            capture = AudioCapture(makeEngine: { [unowned self] in
                let engine = FakeEngine()
                prepare(engines.count, engine)
                engines.append(engine)
                return engine
            }, probe: probe, scheduleRecovery: { [unowned self] in pending.append($0) })
        }

        func postConfigurationChange(from index: Int? = nil) {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[index ?? engines.count - 1])
        }

        func fireAll() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    private static let raised = CaptureGraphError.raised(
        step: "install the tap", reason: "required condition is false: format.sampleRate == hwFormat.sampleRate")

    // MARK: The tap is refused

    @Test("a tap the graph refuses at the start is an error, and one fresh graph is tried")
    func tapRefusedAtStartRetriesOnce() throws {
        let rig = Rig { index, engine in engine.tapFault = index == 0 ? Self.raised : nil }
        try rig.capture.start { _ in }
        #expect(rig.engines.count == 2)
        #expect(rig.engines[0].stopped, "the refused graph is dropped")
        #expect(rig.engines[1].tapInstalled)
        #expect(rig.capture.restartCount == 1)
        rig.engines[1].sendSamples()
        #expect(rig.capture.stop().count == 160)
    }

    @Test("a tap refused twice at the start fails the start as an ordinary error and leaves nothing running")
    func tapRefusedTwiceFailsTheStart() {
        let rig = Rig { _, engine in engine.tapFault = Self.raised }
        #expect(throws: CaptureGraphError.self) { try rig.capture.start(onLevel: { _ in }) }
        #expect(rig.engines.count == 2)
        #expect(rig.engines.filter { !$0.stopped }.isEmpty)
        #expect(!rig.capture.isRunning)
        #expect(rig.pending.isEmpty, "no watchdog is left behind")
    }

    @Test("a tap refused during a restart ends that restart, and a fresh graph is tried after the wait")
    func tapRefusedDuringRestart() throws {
        let rig = Rig { index, engine in engine.tapFault = index == 1 ? Self.raised : nil }
        try rig.capture.start { _ in }
        rig.engines[0].sendSamples()
        rig.pending.removeAll()   // the start watchdog: buffers have arrived
        rig.postConfigurationChange()
        #expect(rig.engines.count == 2, "the change restarted the graph")
        #expect(!rig.engines[1].tapInstalled)
        #expect(rig.capture.isRunning, "the capture is still open, with what it has")
        rig.fireAll()
        #expect(rig.engines.count == 3)
        #expect(rig.engines[2].tapInstalled)
        rig.engines[2].sendSamples()
        #expect(rig.capture.stop().count == 320, "audio from before and after the fault is kept")
    }

    @Test("a format that moved between configuring and the tap is the same kind of fault")
    func formatMovedBeforeTheTap() throws {
        let moved = CaptureGraphError.formatChanged(fromRate: 16_000, toRate: 48_000)
        let rig = Rig { index, engine in engine.tapFault = index == 0 ? moved : nil }
        try rig.capture.start { _ in }
        #expect(rig.engines.count == 2)
        #expect(rig.capture.isRunning)
        rig.capture.stop()
    }

    // MARK: Configuration changes while starting

    @Test("the configuration change our own device selection causes is not a restart; silence after it is")
    func ownConfigurationChange() throws {
        let rig = Rig()
        rig.capture.preferredDeviceID = 41
        try rig.capture.start { _ in }
        rig.postConfigurationChange()
        #expect(rig.engines.count == 1, "no restart for our own change")
        #expect(rig.pending.count == 2, "the start watchdog and a stall check")
        rig.pending.removeLast()()   // the stall check: still no buffers
        #expect(rig.engines.count == 2)
        #expect(rig.capture.restartCount == 1)
        rig.capture.stop()
    }

    @Test("our own configuration change followed by audio: nothing restarts")
    func ownConfigurationChangeThenAudio() throws {
        let rig = Rig()
        rig.capture.preferredDeviceID = 41
        try rig.capture.start { _ in }
        rig.postConfigurationChange()
        rig.engines[0].sendSamples()
        rig.fireAll()
        #expect(rig.engines.count == 1)
        #expect(rig.capture.restartCount == 0)
        rig.capture.stop()
    }

    @Test("a configuration change with no device selected by us still restarts at once")
    func foreignConfigurationChange() throws {
        let rig = Rig()
        try rig.capture.start { _ in }
        rig.postConfigurationChange()
        #expect(rig.engines.count == 2)
        rig.capture.stop()
    }

    // MARK: The limit

    @Test("a Mac that never settles: restarts stop at the limit, and the capture ends with what it has")
    func restartLimit() throws {
        let rig = Rig()
        try rig.capture.start { _ in }
        rig.engines[0].sendSamples()
        for _ in 0..<20 {
            rig.postConfigurationChange()
            rig.fireAll()
        }
        #expect(rig.capture.restartCount == AudioCapture.maxRestarts)
        #expect(rig.engines.count == 1 + AudioCapture.maxRestarts)
        #expect(rig.capture.isRunning)
        #expect(rig.capture.stop().count == 160)
        #expect(rig.capture.restartCount == AudioCapture.maxRestarts, "the count is kept for the stop line")
    }

    @Test("a graph refused on every restart: the retries stop at the limit too")
    func refusedForever() throws {
        let rig = Rig { index, engine in engine.tapFault = index == 0 ? nil : Self.raised }
        try rig.capture.start { _ in }
        rig.engines[0].sendSamples()
        rig.pending.removeAll()
        rig.postConfigurationChange()
        for _ in 0..<20 { rig.fireAll() }
        #expect(rig.engines.count == 1 + AudioCapture.maxRestarts)
        #expect(rig.pending.isEmpty, "nothing is left scheduled")
        rig.capture.stop()
    }

    @Test("the count starts again with each capture")
    func restartCountIsPerCapture() throws {
        let rig = Rig()
        try rig.capture.start { _ in }
        rig.postConfigurationChange()
        #expect(rig.capture.restartCount == 1)
        rig.capture.stop()
        try rig.capture.start { _ in }
        #expect(rig.capture.restartCount == 0)
        rig.capture.stop()
    }

    // MARK: Objective-C exceptions

    @Test("an Objective-C exception comes back as an error with the framework's reason")
    func exceptionIsCaught() {
        let reason = "required condition is false: nullptr == Tap()"
        #expect(throws: CaptureGraphError.raised(step: "install the tap", reason: reason)) {
            try ObjCExceptions.catching("install the tap") {
                NSException(name: .internalInconsistencyException, reason: reason).raise()
            }
        }
    }

    @Test("a value comes back, and a Swift error thrown inside is the error that comes out")
    func catchingPassesThrough() throws {
        #expect(try ObjCExceptions.catching("add") { 2 + 2 } == 4)
        #expect(throws: DeviceSelectionError.noAudioUnit) {
            try ObjCExceptions.catching("select") { throw DeviceSelectionError.noAudioUnit }
        }
    }

    // MARK: The tap's format

    private func format(_ rate: Double, _ channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }

    @Test("the tap runs at the hardware's rate when the node still offers the rate of the device it was made on")
    func staleClientFormat() throws {
        // 2026-10-13: the node offered a headset's 16 kHz after the unit was moved to the Mac's 48 kHz microphone.
        let tap = try TapFormat.resolve(client: format(16_000), hardware: .init(sampleRate: 48_000, channels: 1))
        #expect(tap.sampleRate == 48_000)
        #expect(tap.channelCount == 1)
    }

    @Test("a node that agrees with the hardware keeps its own format, and an unknown hardware format leaves the node's")
    func agreeingFormats() throws {
        let client = format(48_000, 2)
        #expect(try TapFormat.resolve(client: client, hardware: .init(sampleRate: 48_000, channels: 2)) === client)
        #expect(try TapFormat.resolve(client: client, hardware: nil) === client)
        #expect(try TapFormat.resolve(client: format(48_000, 2), hardware: .init(sampleRate: 48_000, channels: 1)).channelCount == 1)
        #expect(try TapFormat.resolve(client: format(48_000), hardware: .init(sampleRate: 44_100, channels: 4)).channelCount == 4)
    }

    @Test("no usable format is an error, never a tap", arguments: [(0.0, UInt32(1)), (48_000.0, UInt32(0))])
    func noUsableFormat(rate: Double, channels: UInt32) {
        #expect(throws: CaptureGraphError.noInputFormat) {
            try TapFormat.resolve(client: format(48_000), hardware: .init(sampleRate: rate, channels: channels))
        }
        #expect(throws: CaptureGraphError.noInputFormat) {
            try TapFormat.check(format(48_000), against: .init(sampleRate: rate, channels: channels))
        }
    }

    @Test("a hardware rate that changed after the tap was planned is refused before the tap goes in")
    func rateChangedBeforeTheTap() throws {
        #expect(throws: CaptureGraphError.formatChanged(fromRate: 16_000, toRate: 48_000)) {
            try TapFormat.check(format(16_000), against: .init(sampleRate: 48_000, channels: 1))
        }
        try TapFormat.check(format(48_000), against: .init(sampleRate: 48_000, channels: 1))
        try TapFormat.check(format(48_000), against: nil)
    }

    // MARK: The proof lines

    @Test("the Bluetooth line gives the three readings and whether an input was seen running")
    func bluetoothLine() {
        let quiet = BluetoothAudioState(inputs: 1, inputRunning: false, outputRate: 48_000)
        let call = BluetoothAudioState(inputs: 1, inputRunning: true, outputRate: 16_000)
        #expect(BluetoothAudioState.logLine(before: quiet, started: quiet, stopped: quiet, seenRunning: false)
                == "capture bluetooth: inputs 1 · input running before 0 · started 0 · stopped 0 · seen running 0 · output rate 48000 > 48000 > 48000 Hz")
        #expect(BluetoothAudioState.logLine(before: quiet, started: call, stopped: quiet, seenRunning: true)
                == "capture bluetooth: inputs 1 · input running before 0 · started 1 · stopped 0 · seen running 1 · output rate 48000 > 16000 > 48000 Hz")
        #expect(BluetoothAudioState.logLine(before: nil, started: nil, stopped: nil, seenRunning: false) == "capture bluetooth: none")
        #expect(BluetoothAudioState.logLine(before: nil, started: nil, stopped: quiet, seenRunning: false).contains("before - · started - · stopped 0"))
    }

    @Test("a capture reads the Bluetooth state before it opens anything, once started and when it stops, and ends its watch")
    func probeIsReadAroundTheCapture() throws {
        final class Calls: @unchecked Sendable { var readings = 0; var watching = 0; var finished = 0 }
        let calls = Calls()
        let probe = CaptureHardwareProbe(
            nominalSampleRate: { _ in 48_000 }, isRunning: { _ in true },
            bluetooth: { calls.readings += 1; return nil },
            watchBluetoothInputs: { calls.watching += 1; return { calls.finished += 1; return false } })
        let rig = Rig(probe: probe)
        try rig.capture.start { _ in }
        #expect(calls.readings == 2)
        #expect(calls.watching == 1)
        rig.capture.stop()
        #expect(calls.readings == 3)
        #expect(calls.finished == 1)
        rig.capture.stop()
        #expect(calls.finished == 1, "a second stop has nothing to report")
    }

    // MARK: A hardware rate that moved (a headset changing profile)

    @Test("a configuration change with the graph's own format unchanged but the hardware at another rate: the capture starts again")
    func staleGraphFormatDoesNotHideARateChange() throws {
        let rig = Rig { _, engine in engine.isDelivering = true }
        try rig.capture.start { _ in }
        rig.engines[0].sendSamples()
        // The node still reports 16 kHz (its format is cached); the hardware has moved to 24 kHz.
        rig.engines[0].hardwareRate = 24_000
        rig.postConfigurationChange()
        #expect(rig.engines.count == 2, "audio decoded at the old rate would be the right samples at the wrong speed")
        #expect(rig.engines[0].stopped)
        #expect(rig.capture.restartCount == 1)
        rig.capture.stop()
    }

    @Test("the same change with the hardware still at the capture's rate keeps the graph, as before")
    func sameHardwareRateKeepsTheGraph() throws {
        let rig = Rig { _, engine in
            engine.isDelivering = true
            engine.hardwareRate = 16_000
        }
        try rig.capture.start { _ in }
        rig.engines[0].sendSamples()
        rig.postConfigurationChange()
        #expect(rig.engines.count == 1)
        #expect(rig.capture.restartCount == 0)
        rig.capture.stop()
    }

    @Test("the rate is asked again when the first sound arrives: a headset that settled on another rate while connecting")
    func rateIsCheckedWhenSoundArrives() async throws {
        let rig = Rig()
        try rig.capture.start { _ in }
        rig.engines[0].sendSamples(value: 0, count: 1_600)   // the link coming up
        rig.engines[0].hardwareRate = 24_000
        rig.engines[0].sendSamples(value: 0.05, count: 1_600)
        await MainActor.run {}
        #expect(rig.engines.count == 2)
        #expect(rig.capture.restartCount == 1)
        rig.engines[1].hardwareRate = 16_000
        rig.engines[1].sendSamples(value: 0.05, count: 1_600)
        await MainActor.run {}
        #expect(rig.engines.count == 2, "once per capture, and not when the rate is the capture's own")
        rig.capture.stop()
    }
}
