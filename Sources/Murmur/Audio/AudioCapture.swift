@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import CryptoKit
import Foundation
import MurmurCore
import os

/// Captures microphone audio as 16 kHz mono Float samples and reports live levels.
///
/// The engine is started on key-down and stopped on release so the macOS microphone
/// indicator is only on while the user is actually dictating.
final class AudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    enum CaptureError: LocalizedError {
        case noInputDevice
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .converterUnavailable: "Could not prepare the microphone audio."
            }
        }
    }

    private var engine: (any MicrophoneEngine)?
    private let makeEngine: () -> any MicrophoneEngine
    /// Makes the engine for a picked device that is not the system's input (`CapturePath`). Nil
    /// only for a test that passes its own engine and no device engine: every capture is then on
    /// that one engine, device and all.
    private let makeDeviceEngine: (() -> any MicrophoneEngine)?
    /// The path of the engine now in use, for the stop line.
    private var path = CapturePath.engine
    private var sessionID = UUID()
    private let scheduleRecovery: (@escaping @Sendable () -> Void) -> Void
    /// Held for the whole of `start` and `stop`, and by every handler that may restart the engine. The dictation
    /// starts its capture off the main thread while those handlers run on it; this keeps them after the start, as
    /// they always were when the start ran on the main thread too. Recursive: a test's recovery may run inline.
    private let lifecycle = NSRecursiveLock()

    /// With `makeEngine` left out this is the real capture: the system's engine, and Core Audio
    /// read for the log's proof lines. A test that passes its own engine gets no hardware reads
    /// unless it also passes a `probe`.
    init(
        makeEngine: (() -> any MicrophoneEngine)? = nil,
        makeDeviceEngine: (() -> any MicrophoneEngine)? = nil,
        probe: CaptureHardwareProbe? = nil,
        scheduleRecovery: @escaping (@escaping @Sendable () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + AudioCapture.watchdogDelay, execute: action)
        },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.makeEngine = makeEngine ?? { SystemMicrophoneEngine() }
        self.makeDeviceEngine = makeDeviceEngine ?? (makeEngine == nil ? { DeviceIOMicrophoneEngine() } : nil)
        self.probe = probe ?? (makeEngine == nil ? .live : .none)
        self.scheduleRecovery = scheduleRecovery
        self.now = now
    }
    /// The clock the timing line is read from; a test moves it by hand.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// When the current capture was asked to start.
    private var startedAt = ContinuousClock.now
    private let probe: CaptureHardwareProbe
    private let state = OSAllocatedUnfairLock(initialState: CaptureState())
    /// False for a note or meeting: drained audio is not kept in memory (notes audit B5), and `stop()`
    /// returns only what was not drained yet. Read at `start`.
    var retainsFullRecording = true
    private var resampler: StreamingResampler?
    private var resamplerFormat: AVAudioFormat?
    /// The rate the last engine of this capture was decoded at, kept past its teardown for the clock line.
    private var resamplerFormatAtStop: Double?
    private var configObserver: NSObjectProtocol?
    private var sessionVoiceProcessing = true
    /// A started engine that delivers no buffers within this time is restarted.
    private static let watchdogDelay: TimeInterval = 0.6
    /// The most restarts one capture makes, the watchdog's two included. Past it the capture is
    /// left as it is (silent, if the graph is dead) and ends with whatever it recorded: a Mac
    /// whose devices keep changing must not put the capture in a restart loop.
    static let maxRestarts = 4
    /// Restarts made in this capture, for the limit and for the stop line.
    private(set) var restartCount = 0
    private var restartLimitLogged = false
    /// `state.buffers` when the current engine started: more than this means it has delivered.
    private var buffersAtEngineStart = 0
    /// The current engine was moved to a device by us, and its first configuration change, which
    /// that move causes, has not been seen yet.
    private var awaitingOwnConfigurationChange = false
    /// Bluetooth audio devices before this capture opened anything and once it was running, and
    /// the watch on their inputs (see `CaptureHardwareProbe`).
    private var bluetoothBefore: BluetoothAudioState?
    private var bluetoothStarted: BluetoothAudioState?
    private var finishBluetoothWatch: (@Sendable () -> Bool)?
    /// Set at `start()` for the per-dictation metering summary logged at `stop()`.
    private var channelCount: AVAudioChannelCount = 0
    private var voiceProcessingActive = false
    /// The microphone the last `start` opened, with the format it opened at: nil before the first
    /// start, and when the device could not be named. Kept after `stop`, so a recording that
    /// came back with hardly any sound can say which microphone it was.
    private(set) var device: InputDeviceInfo?

    private struct CaptureState {
        /// Chunked growable buffer (see `AudioSampleBuffer`) instead of an unbounded `[Float]`:
        /// avoids O(n) whole-buffer copies on every tap callback and O(remaining) `removeFirst`
        /// on every `drain()` — both of which get worse the longer a recording runs.
        var samples = AudioSampleBuffer()
        var isRunning = false
        var onLevel: (@Sendable (Float) -> Void)?
        /// Total samples captured, including ones already handed out by `drain()`.
        var totalCount = 0
        /// Tap callbacks received and ones that produced no samples, for diagnostics.
        var buffers = 0
        var emptyChunks = 0
        /// Peak/RMS/floor accumulated across the session's raw, pre-resample, channel-0 audio
        /// (see `StreamingResampler`'s note on why only channel 0 is used). Tracked as a
        /// running max/sum rather than retaining every raw buffer, so a long note recording
        /// doesn't hold two copies of its audio just for logging.
        var rawPeak: Float = 0
        var rawSumSquares: Float = 0
        var rawSampleCount = 0
        /// How many samples had been captured when the first buffer that was not exact zeros
        /// arrived; nil while every buffer has been zeros. A Bluetooth headset delivers zeros
        /// until its call link is up, and this is how long that took.
        var firstSoundSample: Int?
        /// When each step of opening the microphone happened (`CaptureTiming`).
        var timing = CaptureTiming()
        /// Frames in the first raw buffer, for the clock check at stop.
        var firstBufferFrames = 0
        /// Buffers whose raw peak was beyond full scale or not a number, and how many samples
        /// had been captured when the first and the last of them arrived. No microphone delivers
        /// such a buffer; where they fall in the recording says what did.
        var faultyBuffers = 0
        var firstFaultSample: Int?
        var lastFaultSample: Int?
    }

    /// Selects the input device (nil = system default). Takes effect on the next `start`.
    var preferredDeviceID: AudioDeviceID?
    /// How `preferredDeviceID` was chosen (`MicrophoneSelector.prepare`), for the capture log and
    /// for a recording that came back silent. Nil for a capture that picks its own device.
    var choice: MicrophoneResolution?
    /// Fail rather than fall back: starting, and every restart, throws unless the graph is on exactly
    /// `preferredDeviceID`. Off in the app. The mock-microphone mode sets it so a failed device
    /// selection can never end up recording from the system default input.
    var strictDevice = false
    /// Apple's voice processing: echo cancellation, noise suppression and automatic gain, so
    /// whispers and noisy rooms come through clearly. Other audio is not ducked.
    ///
    /// Off unless the caller asks, and every capture in the app must ask the same way (the
    /// "Reduce background noise" setting). Once one capture has run with voice processing, a
    /// plain capture later in the same process can get no buffers at all: fn + control used to
    /// leave this on, and plain dictation then recorded silence until relaunch (2026-10-04).
    var voiceProcessing = false

    private static let log = Logger(subsystem: "app.hushy", category: "audio")

    var isRunning: Bool { state.withLock { $0.isRunning } }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        state.withLock { $0.isRunning = false }
        stopEngine()
        state.withLock {
            $0 = CaptureState()
            $0.samples = AudioSampleBuffer(retainsFullRecording: retainsFullRecording)
            $0.onLevel = onLevel
        }
        sessionID = UUID()
        startedAt = now()
        resamplerFormatAtStop = nil
        sessionVoiceProcessing = voiceProcessing
        device = nil
        restartCount = 0
        restartLimitLogged = false
        _ = finishBluetoothWatch?()
        bluetoothBefore = probe.bluetooth()
        bluetoothStarted = nil
        finishBluetoothWatch = probe.watchBluetoothInputs()
        do {
            try startFreshEngine()
        } catch {
            stopEngine()
            _ = finishBluetoothWatch?()
            finishBluetoothWatch = nil
            throw error
        }
        bluetoothStarted = probe.bluetooth()
        state.withLock { $0.isRunning = true }
        scheduleWatchdog(attempt: 1)
    }

    /// The first engine of a capture. A graph fault that is ordinary while devices change (the
    /// tap refused, the format moved) gets one more try on a fresh engine before the start fails.
    private func startFreshEngine() throws {
        do {
            try startEngine()
        } catch let fault as CaptureGraphError {
            stopEngine()
            restartCount += 1
            Self.log.error("capture start failed (\(fault.logWord, privacy: .public)); trying once more on a fresh graph")
            try startEngine()
        }
    }

    /// Installs the tap and starts the engine with the current session settings.
    private func startEngine() throws {
        // A picked device that is not the system's input is read through its own IO proc. The
        // system's engine is then never moved off the system's input: it records that or nothing.
        var deviceID = preferredDeviceID
        var make = makeEngine
        if let makeDeviceEngine {
            let chosen = CapturePath.choose(
                picked: preferredDeviceID, systemDefault: probe.systemDefaultInput(),
                pickedExists: preferredDeviceID.map(probe.deviceExists) ?? false, strict: strictDevice)
            if chosen == .deviceIO { make = makeDeviceEngine } else { deviceID = nil }
        }
        let engine = make()
        self.engine = engine
        path = engine.path
        let inputFormat = try engine.configure(
            deviceID: deviceID, voiceProcessing: sessionVoiceProcessing, strictDevice: strictDevice)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInputDevice }
        guard let resampler = StreamingResampler(from: inputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.resampler = resampler
        resamplerFormat = inputFormat
        channelCount = inputFormat.channelCount
        mark(.graphReady)
        voiceProcessingActive = engine.voiceProcessingEnabled
        Self.log.notice("capture start: \(inputFormat.channelCount) ch @ \(Int(inputFormat.sampleRate)) Hz, voice processing \(self.voiceProcessingActive) · path \(self.path.rawValue, privacy: .public)")
        // Which microphone, once per start (a restart opens the device again, so it says again).
        // How it is connected and its format are enough to diagnose the route; never log its name.
        let identity = engine.currentDevice()
        device = identity.map {
            InputDeviceInfo(name: $0.name, transport: $0.transport, sampleRate: inputFormat.sampleRate,
                            channels: Int(inputFormat.channelCount))
        }
        let transport = identity?.transport.rawValue ?? "unknown"
        // How it was chosen, in the rule's own words and with no names: "auto: system input".
        let chosen = choice.map { " · \($0.logWord)" } ?? ""
        Self.log.notice("capture device: \(transport, privacy: .public) · \(Int(inputFormat.sampleRate.rounded())) Hz · \(inputFormat.channelCount) ch\(chosen, privacy: .public)")
        buffersAtEngineStart = state.withLock { $0.buffers }
        awaitingOwnConfigurationChange = deviceID != nil && engine.selectsDeviceOnTheSystemUnit
        observeConfigurationChanges(for: engine)
        try engine.installTap { [weak self] buffer in self?.process(buffer) }
        try engine.start()
        mark(.engineStarted)
        logBinding(of: engine, graph: inputFormat)
    }

    private func mark(_ step: CaptureTiming.Step) {
        let elapsed = now() - startedAt
        state.withLock { $0.timing.mark(step, at: elapsed) }
    }

    /// When each step of opening the microphone happened in this capture, from its start.
    var timing: CaptureTiming { state.withLock { $0.timing } }

    /// Which device the running graph is on, read back from Core Audio after it started, next to
    /// the format the graph itself reports: the two rates agreeing is the check that the graph is
    /// really on that device. Fixed words and numbers only.
    private func logBinding(of engine: any MicrophoneEngine, graph: AVAudioFormat) {
        let bound = engine.currentDevice()
        let deviceRate = bound.flatMap { probe.nominalSampleRate($0.id) }
        let running = bound.flatMap { probe.isRunning($0.id) }
        let rates = deviceRate.map { $0 == graph.sampleRate ? "rates match" : "rates differ" } ?? "device rate unknown"
        let line = "capture bound: \(bound?.transport.rawValue ?? "unknown")"
            + " · device \(deviceRate.map { String(Int($0.rounded())) } ?? "-") Hz"
            + " · graph \(graph.channelCount) ch \(Int(graph.sampleRate.rounded())) Hz · \(rates)"
            + " · running \(running.map { $0 ? "1" : "0" } ?? "-")"
            + " · \(engine.path == .deviceIO ? "its own io proc" : engine.deviceIsReadFromUnit ? "read from the input unit" : "as requested")"
        Self.log.notice("\(line, privacy: .public)")
    }

    /// Restarts capture when the engine goes quiet: first as-is, then without voice processing,
    /// which is the component that most often stalls when audio devices change.
    private func restart(reason: String) {
        guard isRunning else { return }
        guard restartCount < Self.maxRestarts else {
            if !restartLimitLogged {
                restartLimitLogged = true
                Self.log.error("capture restarts stopped at \(self.restartCount) (the limit); not restarting for: \(reason, privacy: .public)")
            }
            return
        }
        restartCount += 1
        Self.log.error("capture restart \(self.restartCount) (\(reason, privacy: .public)); voice processing \(self.sessionVoiceProcessing)")
        stopEngine()
        do {
            try startEngine()
        } catch {
            stopEngine()
            let word = (error as? CaptureGraphError)?.logWord ?? error.localizedDescription
            Self.log.error("capture restart failed: \(word, privacy: .public)")
            // A fault of the graph itself is worth another fresh engine, inside the limit.
            if error is CaptureGraphError { retryAfterFailedRestart() }
        }
    }

    /// Capture health found this stream stalled or dead (notes audit B4): tear the graph down and build it again,
    /// with a fresh restart budget, since the budget belongs to the recording and not to one start. False when the
    /// capture is not running or the new graph did not start.
    @discardableResult
    func rebuild(reason: String) -> Bool {
        guard isRunning else { return false }
        restartCount = 0
        restartLimitLogged = false
        restart(reason: reason)
        return engine != nil
    }

    private func retryAfterFailedRestart() {
        let sessionID = self.sessionID
        scheduleRecovery { [weak self] in
            self?.lifecycle.lock()
            defer { self?.lifecycle.unlock() }
            guard let self, self.sessionID == sessionID, self.isRunning, self.engine == nil else { return }
            self.restart(reason: "retry after a failed restart")
        }
    }

    private func scheduleWatchdog(attempt: Int) {
        let sessionID = self.sessionID
        scheduleRecovery { [weak self] in
            self?.lifecycle.lock()
            defer { self?.lifecycle.unlock() }
            guard let self, self.sessionID == sessionID, self.isRunning, attempt <= 2 else { return }
            guard self.state.withLock({ $0.buffers }) == 0 else { return }
            if attempt == 2 { self.sessionVoiceProcessing = false }
            self.restart(reason: "no audio buffers after \(attempt) attempt(s)")
            self.scheduleWatchdog(attempt: attempt + 1)
        }
    }

    private func observeConfigurationChanges(for engine: any MicrophoneEngine) {
        let sessionID = self.sessionID
        let engineID = ObjectIdentifier(engine)
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine.notificationObject, queue: .main
        ) { [weak self] _ in
            self?.lifecycle.lock()
            defer { self?.lifecycle.unlock() }
            guard let self, self.sessionID == sessionID,
                  self.engine.map({ ObjectIdentifier($0) }) == engineID else { return }
            // Moving the input unit to the device we were asked for posts this notification by
            // itself. Restarting for it would select the device again, be notified again, and loop
            // (2026-10-13, a real headset). The first one on such an engine, before it has
            // delivered anything, is ours: no restart, only the stall check.
            let delivered = self.state.withLock { $0.buffers } > self.buffersAtEngineStart
            if self.awaitingOwnConfigurationChange, !delivered {
                self.awaitingOwnConfigurationChange = false
                Self.log.notice("capture configuration change after our own device selection: no restart")
                self.watchForStall(sessionID: sessionID, engineID: engineID)
                return
            }
            self.awaitingOwnConfigurationChange = false
            // Selecting a non-default input posts one notification while the graph keeps running with
            // the same format; restarting then selects it again and loops with no audio (mock-mic, 2026-10-05).
            // The graph's own format can be stale after the hardware changed its rate (a headset
            // moving between profiles), so the hardware's rate is asked as well: audio decoded
            // at a stale rate is the right samples at the wrong speed.
            if let engine = self.engine, engine.isDelivering,
               let format = engine.currentInputFormat(), format == self.resamplerFormat, !self.hardwareRateMoved(on: engine) {
                self.watchForStall(sessionID: sessionID, engineID: engineID)
                return
            }
            self.restart(reason: "audio configuration changed")
        }
    }

    /// Whether the hardware now delivers at another rate than the capture was set up with.
    /// False when the engine cannot say.
    private func hardwareRateMoved(on engine: any MicrophoneEngine) -> Bool {
        guard let hardware = engine.hardwareSampleRate(), let planned = resamplerFormat?.sampleRate else { return false }
        return hardware != planned
    }

    /// Asked once per capture, when the input's first sound arrives: a Bluetooth headset has
    /// then finished coming up, and may have settled on another rate than it showed when the
    /// capture was set up, without a configuration change being posted for it.
    private func checkRateOnceSoundArrives(sessionID: UUID) {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard self.sessionID == sessionID, isRunning, let engine, hardwareRateMoved(on: engine) else { return }
        restart(reason: "sample rate changed while the input came up")
    }

    /// The early return above could also swallow a real device loss that keeps the format (a headset
    /// unplugged mid-recording). Remember how many buffers had arrived and restart if none has
    /// arrived after `watchdogDelay`: about ten tap periods (a 1024-frame tap is 20 to 65 ms), so a
    /// healthy graph never trips it and a lost device costs about half a second of audio.
    private func watchForStall(sessionID: UUID, engineID: ObjectIdentifier) {
        let seen = state.withLock { $0.buffers }
        scheduleRecovery { [weak self] in
            self?.lifecycle.lock()
            defer { self?.lifecycle.unlock() }
            guard let self, self.sessionID == sessionID, self.isRunning,
                  self.engine.map({ ObjectIdentifier($0) }) == engineID,
                  self.state.withLock({ $0.buffers }) == seen else { return }
            self.restart(reason: "no audio buffers after a configuration change")
        }
    }

    /// Stops capture and returns everything recorded since `start`.
    @discardableResult
    func stop() -> [Float] {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        state.withLock { $0.isRunning = false }
        sessionID = UUID()
        stopEngine()
        let stats = state.withLock { ($0.buffers, $0.emptyChunks, $0.totalCount, $0.firstSoundSample, $0.timing) }
        let firstSound = stats.3.map { "first sound after \(Int((Double($0) / Self.sampleRate * 1_000).rounded())) ms" } ?? "no sound"
        Self.log.notice("capture stop: \(stats.0) buffers, \(stats.1) empty, \(stats.2) samples, \(firstSound, privacy: .public), restarts \(self.restartCount), path \(self.path.rawValue, privacy: .public)")
        Self.log.notice("\(stats.4.logLine, privacy: .public)")
        logClock(stoppedAfter: now() - startedAt, timing: stats.4)
        if let finish = finishBluetoothWatch {
            finishBluetoothWatch = nil
            let line = BluetoothAudioState.logLine(
                before: bluetoothBefore, started: bluetoothStarted, stopped: probe.bluetooth(), seenRunning: finish())
            Self.log.notice("\(line, privacy: .public)")
        }
        let faults = state.withLock { ($0.faultyBuffers, $0.firstFaultSample, $0.lastFaultSample) }
        if faults.0 > 0, let first = faults.1, let last = faults.2 {
            let ms = { (sample: Int) in Int((Double(sample) / Self.sampleRate * 1_000).rounded()) }
            Self.log.error("capture over full scale: \(faults.0) of \(stats.0) buffers · first at \(ms(first)) ms · last at \(ms(last)) ms · path \(self.path.rawValue, privacy: .public)")
        }
        let (samples, rawPeak, rawSumSquares, rawCount) = state.withLock { current -> ([Float], Float, Float, Int) in
            current.isRunning = false
            current.onLevel = nil
            return (current.samples.allSamples(), current.rawPeak, current.rawSumSquares, current.rawSampleCount)
        }
        if rawCount > 0 {
            let rawRMS = (rawSumSquares / Float(rawCount)).squareRoot()
            Self.log.notice("meter raw peak \(rawPeak, format: .fixed(precision: 4)) rms \(rawRMS, format: .fixed(precision: 4)) · \(self.channelCount) ch · voice processing \(self.voiceProcessingActive)")
        }
        return samples
    }

    /// How fast frames really arrived, next to the rate they were decoded at. A device that
    /// delivers at another rate than the capture believes shows here as a clear difference
    /// (16000 against 24000), whatever the graph says about itself. Numbers only.
    private func logClock(stoppedAfter stopped: Duration, timing: CaptureTiming) {
        let (frames, firstFrames) = state.withLock { ($0.rawSampleCount, $0.firstBufferFrames) }
        guard let firstBuffer = timing.firstBuffer, let declared = resamplerFormatAtStop, frames > firstFrames else { return }
        let span = Double(CaptureTiming.milliseconds(stopped - firstBuffer))
        guard span >= 500 else { return }   // too short to tell a rate from jitter
        let measured = Double(frames - firstFrames) / span * 1_000
        let verdict = abs(measured - declared) / declared > 0.08 ? "rates disagree" : "rates agree"
        Self.log.notice("capture clock: \(frames - firstFrames) frames in \(Int(span)) ms after the first buffer = \(Int(measured.rounded())) Hz · decoded at \(Int(declared)) Hz · \(verdict, privacy: .public)")
    }

    /// Returns and releases samples captured since the previous drain, without stopping.
    /// Long recordings drain periodically so memory stays flat.
    func drain() -> [Float] {
        state.withLock { current in
            current.samples.drain()
        }
    }

    /// Duration of audio captured so far, in seconds.
    var capturedSeconds: Double {
        Double(state.withLock { $0.totalCount }) / Self.sampleRate
    }

    /// How long the capture ran before a buffer that was not exact zeros arrived, in seconds;
    /// nil while every buffer so far has been zeros (or none has come).
    var secondsBeforeFirstSound: Double? {
        state.withLock { $0.firstSoundSample }.map { Double($0) / Self.sampleRate }
    }

    private func stopEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine?.stop()
        for line in engine?.diagnostics() ?? [] { Self.log.notice("\(line, privacy: .public)") }
        // Release the I/O unit, including voice processing, before another capture starts.
        // Restarting the same stopped engine can retain the stalled hardware graph.
        engine = nil
        resampler = nil
        resamplerFormatAtStop = resamplerFormat?.sampleRate ?? resamplerFormatAtStop
        resamplerFormat = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        // Device changes can alter the tap format mid-session; follow it instead of failing.
        if let expected = resamplerFormat,
           buffer.format.channelCount != expected.channelCount || buffer.format.sampleRate != expected.sampleRate {
            resampler = StreamingResampler(from: buffer.format)
            resamplerFormat = buffer.format
        }
        guard let resampler else { return }
        let chunk = resampler.convert(buffer)
        let elapsed = now() - startedAt
        state.withLock {
            $0.buffers += 1
            $0.timing.mark(.firstBuffer, at: elapsed)
            if chunk.isEmpty { $0.emptyChunks += 1 }
        }
        guard !chunk.isEmpty else { return }
        let rms = StreamingResampler.rms(chunk)
        let (rawPeak, rawSumSquares, rawCount) = Self.rawChannel0Stats(buffer)

        let (onLevel, soundJustArrived) = state.withLock { current -> ((@Sendable (Float) -> Void)?, Bool) in
            var soundJustArrived = false
            if current.rawSampleCount == 0 { current.firstBufferFrames = rawCount }
            if rawPeak > 1 || !rawPeak.isFinite || !rawSumSquares.isFinite {
                current.faultyBuffers += 1
                current.firstFaultSample = current.firstFaultSample ?? current.totalCount
                current.lastFaultSample = current.totalCount
            }
            if current.firstSoundSample == nil, rawPeak > 0 {
                current.firstSoundSample = current.totalCount
                current.timing.mark(.firstSound, at: elapsed)
                soundJustArrived = true
            }
            current.samples.append(contentsOf: chunk)
            current.totalCount += chunk.count
            current.rawPeak = max(current.rawPeak, rawPeak)
            current.rawSumSquares += rawSumSquares
            current.rawSampleCount += rawCount
            return (current.onLevel, soundJustArrived)
        }
        if soundJustArrived {
            let sessionID = self.sessionID
            DispatchQueue.main.async { [weak self] in self?.checkRateOnceSoundArrives(sessionID: sessionID) }
        }
        onLevel?(rms)
    }

    /// Peak and sum-of-squares of channel 0 of the raw (pre-resample) input buffer, without
    /// retaining the buffer itself. Uses vDSP (Accelerate) instead of a scalar loop: this runs
    /// on every tap callback (dozens/sec), and `vDSP_maxmgv`/`vDSP_svesq` vectorize the same
    /// peak/sum-of-squares reduction the old hand-rolled loop computed one sample at a time.
    private static func rawChannel0Stats(_ buffer: AVAudioPCMBuffer) -> (peak: Float, sumSquares: Float, count: Int) {
        guard let channel = buffer.floatChannelData?[0] else { return (0, 0, 0) }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return (0, 0, 0) }
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(count))
        var sumSquares: Float = 0
        vDSP_svesq(channel, 1, &sumSquares, vDSP_Length(count))
        return (peak, sumSquares, count)
    }

    // MARK: Devices

    struct InputDevice: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        let name: String
        let transport: InputTransport
        var isUsable = true
        var isBuiltIn: Bool { transport == .builtIn }
    }

    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            inputChannelCount(id) > 0 ? device(id) : nil
        }
    }

    /// One device by id: its name and how it is connected. Nil when Core Audio has no name for it.
    /// Reads only; nothing here selects a device or changes a system setting.
    static func device(_ id: AudioDeviceID) -> InputDevice? {
        guard id != kAudioObjectUnknown, let name = deviceName(id) else { return nil }
        return InputDevice(id: id, name: name, transport: InputTransport(coreAudioTransportType: transportType(id)),
                           isUsable: DeviceIOMicrophoneEngine.firstInputStream(of: id) != nil)
    }

    /// The input the system would record from when Hushy's Microphone setting is "System default".
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }


}

/// Writes 16 kHz mono samples to a WAV file.
enum WAVWriter {
    static func write(_ samples: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: Encrypted variants

    /// Writes `samples` as WAV, then, if `key` is provided, encrypts the result in place: the
    /// plaintext WAV is written to a private temp file, encrypted to `url` + `.enc`, and the
    /// temp file is securely removed. `url`'s own extension is left as the caller passed it
    /// (normally `.wav`); the encrypted sibling is what actually gets written to `url`'s
    /// directory when `key` is non-nil. Passing `key: nil` writes plain WAV exactly as
    /// `write(_:to:)` does, so existing plaintext call sites (Voice Lab) are unaffected.
    static func write(_ samples: [Float], to url: URL, key: SymmetricKey?) throws {
        guard let key else {
            try write(samples, to: url)
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try write(samples, to: tempURL)
        let plaintext = try Data(contentsOf: tempURL)
        try EncryptedFileStore.write(plaintext, to: EncryptedFileStore.encryptedURL(for: url), key: key)
    }

    /// Reads samples from `url`, transparently handling both a legacy plaintext WAV and a
    /// `.wav.enc` file written by `write(_:to:key:)`. `url` should be the *base* path (the
    /// `.wav` path as stored in the database); this checks for `url` itself first, then
    /// `url.wav.enc`, so callers don't need to know which era wrote a given file.
    static func read(_ url: URL, key: SymmetricKey?) throws -> [Float] {
        let encryptedURL = EncryptedFileStore.encryptedURL(for: url)
        if FileManager.default.fileExists(atPath: encryptedURL.path) {
            guard let key else { throw EncryptionError.decryptionFailed }
            let plaintext = try EncryptedFileStore.read(encryptedURL, key: key)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hushy-wav-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try plaintext.write(to: tempURL)
            return try read(tempURL)
        }
        return try read(url)
    }
}
