@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MurmurCore
import os
import Testing
@testable import Murmur

@Suite("Microphone capture lifecycle")
@MainActor
struct AudioCaptureLifecycleTests {
    final class FakeEngine: NSObject, MicrophoneEngine {
        var notificationObject: AnyObject { self }
        var voiceProcessingEnabled = false
        var stopped = false
        var failStart = false
        var tapInstalled = false
        var failConfigure: DeviceSelectionError?
        /// What each `configure` call asked for: the device and whether the selection was strict.
        var configureCalls: [(device: AudioDeviceID?, strict: Bool)] = []
        var isDelivering = false
        var path = CapturePath.engine
        /// What the hardware says it delivers; nil, as for any fake, unless a test sets it.
        var hardwareRate: Double?
        func hardwareSampleRate() -> Double? { hardwareRate }
        var selectsDeviceOnTheSystemUnit = true
        var format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        func currentInputFormat() -> AVAudioFormat? { format }
        /// The device this graph says it records from; nil, as for any fake, unless a test names one.
        var device: AudioCapture.InputDevice?
        func currentDevice() -> AudioCapture.InputDevice? { device }
        var receive: (@Sendable (AVAudioPCMBuffer) -> Void)?
        func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> AVAudioFormat {
            try configure(deviceID: deviceID, voiceProcessing: voiceProcessing, strictDevice: false)
        }
        func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool, strictDevice: Bool) throws -> AVAudioFormat {
            configureCalls.append((deviceID, strictDevice))
            if strictDevice, let failConfigure { throw failConfigure }
            voiceProcessingEnabled = voiceProcessing
            return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        }
        /// What the graph says when the tap goes in: a fault here is what AVFAudio raising looks like to the capture.
        var tapFault: CaptureGraphError?
        func installTap(_ receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            if let tapFault { throw tapFault }
            self.receive = receive
            tapInstalled = true
        }
        func start() throws {
            if failStart { throw AudioCapture.CaptureError.noInputDevice }
        }
        func stop() { stopped = true; receive = nil }
        func sendSamples(value: Float = 0.1, count: AVAudioFrameCount = 160) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            buffer.floatChannelData![0].initialize(repeating: value, count: Int(count))
            receive?(buffer)
        }
    }

    // MARK: Which microphone, and when it first delivered sound

    @Test("a capture remembers the microphone it opened, with the format it opened at, and keeps it after stopping")
    func rememberedDevice() throws {
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engine.device = AudioCapture.InputDevice(id: 71, name: "Example Buds Pro", transport: .bluetooth)
            return engine
        })
        #expect(capture.device == nil, "nothing before the first start")
        try capture.start { _ in }
        let expected = InputDeviceInfo(name: "Example Buds Pro", transport: .bluetooth, sampleRate: 16_000, channels: 1)
        #expect(capture.device == expected)
        #expect(capture.device?.logSummary == "\"Example Buds Pro\" · bluetooth · 16000 Hz · 1 ch")
        capture.stop()
        #expect(capture.device == expected, "a recording that came back with hardly any sound can still say which microphone")
    }

    @Test("a device that cannot be named is not carried over from the capture before")
    func unnamedDeviceIsNotStale() throws {
        var named = true
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            if named { engine.device = AudioCapture.InputDevice(id: 71, name: "Example Buds Pro", transport: .bluetooth) }
            return engine
        })
        try capture.start { _ in }
        capture.stop()
        named = false
        try capture.start { _ in }
        #expect(capture.device == nil)
        capture.stop()
    }

    @Test("built-in is a transport, not a separate flag")
    func builtInFollowsTransport() {
        #expect(AudioCapture.InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn).isBuiltIn)
        #expect(!AudioCapture.InputDevice(id: 2, name: "Example Buds Pro", transport: .bluetooth).isBuiltIn)
        #expect(AudioCapture.device(AudioDeviceID(kAudioObjectUnknown)) == nil, "the unknown device is never looked up")
    }

    @Test("the time before the first sound is counted in captured audio: zeros while a headset's link comes up")
    func timeBeforeFirstSound() throws {
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        })
        try capture.start { _ in }
        #expect(capture.secondsBeforeFirstSound == nil)
        for _ in 0..<10 { engines[0].sendSamples(value: 0, count: 1_600) }   // one second of exact zeros
        #expect(capture.secondsBeforeFirstSound == nil, "zeros are not sound")
        engines[0].sendSamples(value: 0.05, count: 1_600)
        let first = try #require(capture.secondsBeforeFirstSound)
        #expect(abs(first - 1.0) < 0.05, "one second of zeros came first, got \(first)")
        engines[0].sendSamples(value: 0, count: 1_600)
        engines[0].sendSamples(value: 0.05, count: 1_600)
        #expect(capture.secondsBeforeFirstSound == first, "the first sound, not the latest")
        capture.stop()
        try capture.start { _ in }
        #expect(capture.secondsBeforeFirstSound == nil, "each recording counts from its own start")
        engines[1].sendSamples()
        #expect(capture.secondsBeforeFirstSound == 0)
        capture.stop()
    }

    @Test("the lost start is split into its parts: the graph, the engine, the first buffer, the first sound")
    func timingSplitsTheStart() throws {
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let advance = { (ms: Int) in clock.withLock { $0 += .milliseconds(ms) } }
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.append(engine)
            advance(40)   // building the graph
            return engine
        }, now: { clock.withLock { $0 } })
        try capture.start { _ in }
        #expect(capture.timing.graphReady == .milliseconds(40))
        #expect(capture.timing.engineStarted == .milliseconds(40))
        #expect(capture.timing.firstBuffer == nil)
        advance(160)
        for _ in 0..<11 {   // a headset's link coming up: 1.1 s of exact zeros
            engines[0].sendSamples(value: 0, count: 1_600)
            advance(100)
        }
        #expect(capture.timing.firstBuffer == .milliseconds(200))
        #expect(capture.timing.firstSound == nil, "zeros are not sound")
        engines[0].sendSamples(value: 0.05, count: 1_600)
        #expect(capture.timing.firstSound == .milliseconds(1_300))
        #expect(capture.timing.silenceDelivered == .milliseconds(1_100))
        #expect(capture.timing.logLine == "capture timing: graph ready 40 ms · engine started 40 ms · first buffer 200 ms · first sound 1300 ms")
        capture.stop()
        #expect(capture.timing.firstSound == .milliseconds(1_300), "kept after stopping, for the stop line")
        try capture.start { _ in }
        #expect(capture.timing.firstBuffer == nil, "each recording counts from its own start")
        capture.stop()
    }

    @Test("a buffer beyond full scale is delivered like any other: the capture counts it, the dictation decides")
    func overFullScaleBufferIsKept() throws {
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        })
        try capture.start { _ in }
        engines[0].sendSamples(value: 0.05, count: 1_600)
        engines[0].sendSamples(value: 11.7, count: 1_600)
        let samples = capture.stop()
        #expect(samples.count == 3_200)
        #expect(AudioReadFault.find(in: samples)?.peak == 11.7, "what reaches the dictation still shows the fault")
    }

    @Test func stopReleasesGraphAndNextSessionCreatesAnother() throws {
        weak var previous: FakeEngine?
        var creations = 0
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            previous = engine
            creations += 1
            return engine
        })
        try capture.start { _ in }
        previous?.sendSamples()
        #expect(!capture.stop().isEmpty)
        #expect(previous == nil)
        try capture.start { _ in }
        #expect(creations == 2)
        #expect(capture.stop().isEmpty)
    }

    @Test("a capture is plain unless its caller asks for voice processing")
    func captureIsPlainUnlessAsked() throws {
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        })
        try capture.start { _ in }
        _ = capture.stop()
        capture.voiceProcessing = true
        try capture.start { _ in }
        _ = capture.stop()
        #expect(engines.map(\.voiceProcessingEnabled) == [false, true])
    }

    @Test func failedStartReleasesGraph() {
        weak var previous: FakeEngine?
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engine.failStart = true
            previous = engine
            return engine
        })
        #expect(throws: (any Error).self) { try capture.start { _ in } }
        #expect(!capture.isRunning)
        #expect(previous == nil)
    }

    @Test func configurationRecoveryReplacesGraphAndKeepsSamples() throws {
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        })
        try capture.start { _ in }
        engines[0].sendSamples()
        let before = capture.capturedSeconds
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 2)
        #expect(engines[0].stopped)
        engines[1].sendSamples()
        #expect(capture.capturedSeconds > before)
        // A delayed notification from the disposed graph must not restart the new graph.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 2)
        capture.stop()
    }

    @Test("a configuration change that leaves the graph running on the same format is not a restart")
    func selfInflictedConfigurationChangeIsIgnored() throws {
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engine.isDelivering = true
            engines.append(engine)
            return engine
        })
        try capture.start { _ in }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 1)
        engines[0].format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 2)
        capture.stop()
    }

    @Test func watchdogReplacesStalledGraphAndIgnoresPreviousSession() throws {
        var engines: [FakeEngine] = []
        var pending: [@Sendable () -> Void] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }, scheduleRecovery: { pending.append($0) })
        try capture.start { _ in }
        let staleWatchdog = pending.removeFirst()
        capture.stop()
        try capture.start { _ in }
        staleWatchdog()
        #expect(engines.count == 2)
        pending.removeFirst()()
        #expect(engines.count == 3)
        #expect(engines[1].stopped)
        engines[2].sendSamples()
        #expect(capture.capturedSeconds > 0)
        pending.removeFirst()()
        #expect(engines.count == 3)
        capture.stop()
    }

    // MARK: Strict device selection

    @Test("a strict capture fails to start when the device cannot be selected, and releases the graph")
    func strictCaptureThrowsWhenSelectionFails() {
        weak var previous: FakeEngine?
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engine.failConfigure = .setFailed(-10851)
            previous = engine
            return engine
        })
        capture.preferredDeviceID = 77
        capture.strictDevice = true
        #expect(throws: DeviceSelectionError.setFailed(-10851)) { try capture.start { _ in } }
        #expect(!capture.isRunning)
        #expect(previous == nil)
    }

    @Test("the strict option is off unless asked for, and a plain capture ignores a failing selection")
    func strictIsOffByDefault() throws {
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engine.failConfigure = .setFailed(-1)
            engines.append(engine)
            return engine
        })
        capture.preferredDeviceID = 77
        try capture.start { _ in }
        #expect(engines[0].configureCalls.map(\.strict) == [false])
        capture.stop()
    }

    @Test("a configuration-change restart and both watchdog restarts keep the requested device and the strict option")
    func restartsKeepDeviceAndStrict() throws {
        var engines: [FakeEngine] = []
        var pending: [@Sendable () -> Void] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }, scheduleRecovery: { pending.append($0) })
        capture.preferredDeviceID = 77
        capture.strictDevice = true
        try capture.start { _ in }
        // Selecting a device posts one configuration change of its own: that one is not a restart.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 1)
        // A second one on the same graph is a real change.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 2)
        pending.removeFirst()()   // the first watchdog
        pending.removeFirst()()   // the stall check left by the first notification: its graph is gone
        #expect(engines.count == 3)
        pending.removeFirst()()   // the second watchdog
        #expect(engines.count == 4)
        for engine in engines {
            #expect(engine.configureCalls.count == 1)
            #expect(engine.configureCalls.first?.device == 77)
            #expect(engine.configureCalls.first?.strict == true)
        }
        capture.stop()
    }

    @Test("a strict restart that cannot select the device leaves the capture silent instead of on another device")
    func strictRestartFailsClosed() throws {
        var engines: [FakeEngine] = []
        let capture = AudioCapture(makeEngine: {
            let engine = FakeEngine()
            engine.failConfigure = engines.isEmpty ? nil : .differentDevice(requested: 77, actual: 1)
            engines.append(engine)
            return engine
        })
        capture.preferredDeviceID = 77
        capture.strictDevice = true
        try capture.start { _ in }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 1, "the change our own selection causes is not a restart")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        #expect(engines.count == 2)
        #expect(!engines[1].tapInstalled, "no tap was installed on the graph that could not select the device")
        capture.stop()
    }

    @Test("the selection is accepted only when the set worked and reading it back gives the requested device")
    func selectionVerification() throws {
        try DeviceSelection.verify(setStatus: noErr, requested: 7, readBack: .success(7))
        #expect(throws: DeviceSelectionError.setFailed(-50)) {
            try DeviceSelection.verify(setStatus: -50, requested: 7, readBack: .success(7))
        }
        #expect(throws: DeviceSelectionError.differentDevice(requested: 7, actual: 3)) {
            try DeviceSelection.verify(setStatus: noErr, requested: 7, readBack: .success(3))
        }
        #expect(throws: DeviceSelectionError.readBackFailed(-1)) {
            try DeviceSelection.verify(setStatus: noErr, requested: 7, readBack: .failure(.readBackFailed(-1)))
        }
    }

    // MARK: Configuration change that leaves the graph running

    /// A capture whose graph reports it is still delivering, with the recovery timer under the test's control.
    private final class RunningCapture {
        var engines: [FakeEngine] = []
        var pending: [@Sendable () -> Void] = []
        var capture: AudioCapture!

        init() throws {
            capture = AudioCapture(makeEngine: { [unowned self] in
                let engine = FakeEngine()
                engine.isDelivering = true
                engines.append(engine)
                return engine
            }, scheduleRecovery: { [unowned self] in pending.append($0) })
            try capture.start { _ in }
            engines[0].sendSamples()
            pending.removeFirst()
        }

        func postConfigurationChange() {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engines[0])
        }
    }

    @Test("a configuration change while buffers keep flowing does not restart")
    func notificationWithFlowingBuffersDoesNotRestart() throws {
        let run = try RunningCapture()
        run.postConfigurationChange()
        run.engines[0].sendSamples()
        #expect(run.pending.count == 1)
        run.pending.removeFirst()()
        #expect(run.engines.count == 1)
        run.capture.stop()
    }

    @Test("a configuration change followed by silence on an unchanged format restarts once")
    func notificationThenSilenceRestartsOnce() throws {
        let run = try RunningCapture()
        run.postConfigurationChange()
        run.pending.removeFirst()()
        #expect(run.engines.count == 2)
        #expect(run.engines[0].stopped)
        #expect(run.pending.isEmpty)
        run.capture.stop()
    }

    @Test("a configuration change that changed the format restarts at once, with no wait")
    func formatChangeRestartsImmediately() throws {
        let run = try RunningCapture()
        run.engines[0].format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        run.postConfigurationChange()
        #expect(run.engines.count == 2)
        #expect(run.pending.isEmpty)
        run.capture.stop()
    }

    @Test("a stall check that fires after the capture stopped does nothing")
    func staleStallCheckIsIgnored() throws {
        let run = try RunningCapture()
        run.postConfigurationChange()
        run.capture.stop()
        run.pending.removeFirst()()
        #expect(run.engines.count == 1)
    }
}
