@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

/// Which way a capture reads its microphone.
///
/// `engine` is AVAudioEngine on the system's input, never moved to another device. `deviceIO` is
/// a Core Audio IO proc on one device's own ID, for a microphone the person picked that is not
/// the system's input.
///
/// Why two: AVAudioEngine's input node is built on the system's input. Moved to another device
/// while a Bluetooth headset is the system's input, it delivered no buffer at all on a real Mac,
/// with matching sample rates or not (2026-10-13, build 2276). An IO proc on the picked device
/// never involves the system's input, so it neither depends on the headset nor opens it.
enum CapturePath: String, Sendable, Equatable {
    case engine
    case deviceIO = "device io"

    /// - Parameters:
    ///   - picked: the device the capture was asked for; nil for the system's input.
    ///   - systemDefault: the system's input right now.
    ///   - pickedExists: whether `picked` is still a device (one unplugged since is not).
    ///   - strict: the capture must be on exactly `picked` or fail (the mock-microphone mode).
    static func choose(picked: AudioDeviceID?, systemDefault: AudioDeviceID?, pickedExists: Bool, strict: Bool) -> CapturePath {
        guard let picked else { return .engine }
        if strict { return .deviceIO }
        guard pickedExists else { return .engine }
        return picked == systemDefault ? .engine : .deviceIO
    }
}

/// Why a device's own IO could not be set up or started. Status codes and numbers only.
enum DeviceIOError: LocalizedError, Equatable {
    case noDevice
    case notFloat32
    case createFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDevice: "The picked microphone is not connected."
        case .notFloat32: "The picked microphone does not deliver audio in a format Hushy can read."
        case .createFailed(let status): "Could not open the picked microphone (\(status))."
        case .startFailed(let status): "Could not start the picked microphone (\(status))."
        }
    }
}

/// What an IO proc is handed, carried off the audio thread.
///
/// Core Audio calls an IO block on the device's real-time thread, and does so even when the block
/// was registered with a dispatch queue (measured 2026-10-14 on a virtual device: 563 of 563
/// blocks ran on the IO thread, and a queue held busy delayed none of them). Nothing but a copy
/// may happen there. `write` is that copy: into memory allocated once, under a lock held only for
/// the copy. `read` is the other side, on a queue of Hushy's own, where resampling, metering and
/// everything after them run as they do behind an AVAudioEngine tap.
///
/// It keeps one channel: channel 0 of the device's first stream, read from that buffer's own
/// byte size and channel count on every callback. The rest of the capture uses one channel
/// anyway, and a reader that needs no agreement about the layout cannot misread one that changes:
/// the Mac's own microphone can turn from one channel into three (one per capsule) while another
/// app uses voice processing, as three buffers or as one interleaved buffer.
///
/// The rules are the ones the shipped readers converged on (docs/engineering/
/// MAC-AUDIO-CAPTURE-OPEN-SOURCE.md, sections 3 and 4). The first version here ran the whole
/// capture inside the IO block (build 2295), and some recordings from the Mac's own microphone
/// came back with bursts far above full scale. The cause is not proven; `Fault` is the record
/// that will name it if it happens again.
final class DeviceIORing: @unchecked Sendable {
    /// What the audio thread saw, for the capture log. Numbers only.
    struct Counters: Equatable, Sendable {
        var callbacks = 0
        var frames = 0
        var smallestCallback = 0
        var largestCallback = 0
        /// The fewest and most buffers a callback's list held, and the most channels its first had.
        var fewestBuffers = 0
        var mostBuffers = 0
        var widestFirstBuffer = 0
        /// Frames dropped because the reader had fallen a whole ring behind.
        var dropped = 0
        /// Frames refused after the device's format changed, until the capture is rebuilt.
        var gated = 0
        /// Callbacks whose first buffer could not be read (no data, no channels, a partial frame).
        var misfits = 0
        /// Callbacks that did not follow the one before on the device's own sample clock, and the
        /// largest such jump in frames. A gap is a cycle the device or this process missed.
        var gaps = 0
        var largestGap = 0
        /// Callbacks holding a sample beyond full scale, or one that is not a number.
        var faulty = 0
    }

    /// One callback that held a sample no microphone delivers, as the audio thread saw it. With
    /// the gap on the device's clock and the list's layout it separates the candidate causes: a
    /// gap points at a missed cycle, a changed layout at the device's format, neither at the
    /// device's own samples.
    struct Fault: Equatable, Sendable {
        var callback = 0
        var frames = 0
        /// The largest magnitude in channel 0; -1 when it was not a number.
        var peak: Float = 0
        var buffers = 0
        /// Channels and bytes of the first four buffers of the list.
        var layout: [(channels: Int, bytes: Int)] = []
        /// Frames between this callback and the one before on the device's clock, beyond what
        /// the one before held; 0 when they follow on, nil for the first callback.
        var gap: Int?

        static func == (a: Fault, b: Fault) -> Bool {
            a.callback == b.callback && a.frames == b.frames && a.peak == b.peak && a.buffers == b.buffers && a.gap == b.gap
                && a.layout.map(\.channels) == b.layout.map(\.channels) && a.layout.map(\.bytes) == b.layout.map(\.bytes)
        }

        /// "callback 212 · 512 frames · peak 11.7033 · buffers 1 [1 ch 2048 bytes] · gap 0 frames".
        var logWords: String {
            let shape = layout.map { "\($0.channels) ch \($0.bytes) bytes" }.joined(separator: ", ")
            let size = peak < 0 ? "not a number" : String(format: "%.4f", peak)
            return "callback \(callback) · \(frames) frames · peak \(size) · buffers \(buffers) [\(shape)]"
                + " · gap \(gap.map { "\($0) frames" } ?? "first callback")"
        }
    }

    /// Faults kept per capture: the first few say what is going on; the count says how often.
    static let faultsKept = 4

    /// One channel at the device's own rate.
    let format: AVAudioFormat
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float32>
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var readIndex = 0
        var count = 0
        var counters = Counters()
        var isGated = false
        var lastSampleTime: Double?
        var lastFrames = 0
        var faults: [Fault] = []
    }

    /// `seconds` of audio fit before frames are dropped: far longer than a reader is ever behind.
    init?(sampleRate: Double, seconds: Double = 2) {
        guard sampleRate > 0, let format = TapFormat.plain(sampleRate: sampleRate, channels: 1) else { return nil }
        self.format = format
        capacity = max(1, Int(sampleRate * seconds))
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        var initial = State()
        // Room for every fault that is kept, so the audio thread never allocates for one.
        initial.faults.reserveCapacity(Self.faultsKept)
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    deinit { storage.deallocate() }

    var counters: Counters { state.withLock { $0.counters } }
    var faults: [Fault] { state.withLockUnchecked { $0.faults } }

    /// The device's format changed: nothing more is taken until the capture is rebuilt. Audio
    /// read with the old format's rate would be the right samples at the wrong speed.
    func closeGate() { state.withLock { $0.isGated = true } }

    /// The audio thread's side. `list` holds one buffer per stream of the device, each with its
    /// channels interleaved as 32-bit floats (the stream's virtual format, which is what an IO
    /// proc is handed). `sampleTime` is the device's clock for the first frame. Returns whether
    /// anything was taken.
    @discardableResult
    func write(_ list: UnsafePointer<AudioBufferList>, sampleTime: Double = 0) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let sampleSize = MemoryLayout<Float32>.size
        guard let first = buffers.first, first.mNumberChannels > 0, let data = first.mData,
              Int(first.mDataByteSize) % (Int(first.mNumberChannels) * sampleSize) == 0,
              first.mDataByteSize > 0 else {
            state.withLockUnchecked { $0.counters.misfits += 1 }
            return false
        }
        let width = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (width * sampleSize)
        let source = data.assumingMemoryBound(to: Float32.self)
        var peak: Float = 0
        vDSP_maxmgv(source, vDSP_Stride(width), &peak, vDSP_Length(frames))
        let isFaulty = !(peak <= 1)   // also true when the peak is not a number
        return state.withLockUnchecked { state in
            state.counters.callbacks += 1
            let isFirst = state.counters.callbacks == 1
            state.counters.frames += frames
            state.counters.largestCallback = max(state.counters.largestCallback, frames)
            state.counters.smallestCallback = isFirst ? frames : min(state.counters.smallestCallback, frames)
            state.counters.mostBuffers = max(state.counters.mostBuffers, buffers.count)
            state.counters.fewestBuffers = isFirst ? buffers.count : min(state.counters.fewestBuffers, buffers.count)
            state.counters.widestFirstBuffer = max(state.counters.widestFirstBuffer, width)
            var gap: Int?
            if let last = state.lastSampleTime {
                let jump = Int((sampleTime - last).rounded()) - state.lastFrames
                gap = jump
                if jump != 0 {
                    state.counters.gaps += 1
                    state.counters.largestGap = max(state.counters.largestGap, abs(jump))
                }
            }
            state.lastSampleTime = sampleTime
            state.lastFrames = frames
            if isFaulty {
                state.counters.faulty += 1
                if state.faults.count < Self.faultsKept {
                    var fault = Fault(callback: state.counters.callbacks, frames: frames, peak: peak.isFinite ? peak : -1,
                                      buffers: buffers.count, gap: gap)
                    fault.layout.reserveCapacity(4)
                    for buffer in buffers.prefix(4) { fault.layout.append((Int(buffer.mNumberChannels), Int(buffer.mDataByteSize))) }
                    state.faults.append(fault)
                }
            }
            guard !state.isGated else {
                state.counters.gated += frames
                return false
            }
            guard frames <= capacity - state.count else {
                state.counters.dropped += frames
                return false
            }
            let start = (state.readIndex + state.count) % capacity
            for frame in 0..<frames { storage[(start + frame) % capacity] = source[frame * width] }
            state.count += frames
            return true
        }
    }

    /// The reader's side: everything written since the last read, or nil when there is nothing.
    func read() -> AVAudioPCMBuffer? {
        let waiting = state.withLock { $0.count }
        guard waiting > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(waiting)),
              let plane = output.floatChannelData?[0] else { return nil }
        state.withLockUnchecked { state in
            // More may have arrived since; only what was counted is taken, the rest next time.
            for frame in 0..<waiting { plane[frame] = storage[(state.readIndex + frame) % capacity] }
            state.readIndex = (state.readIndex + waiting) % capacity
            state.count -= waiting
        }
        output.frameLength = AVAudioFrameCount(waiting)
        return output
    }
}

/// Moves a device's audio from its IO thread to the capture: `take` on the audio thread only
/// copies and wakes the reader; the reader hands buffers to `receive` on its own queue, in order.
final class DeviceIOHandoff: @unchecked Sendable {
    let ring: DeviceIORing
    private let wake: DispatchSourceUserDataAdd
    private let queue: DispatchQueue
    private let drain: @Sendable () -> Void
    private static let onReaderQueue = DispatchSpecificKey<ObjectIdentifier>()

    init?(sampleRate: Double, queue: DispatchQueue, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        guard let ring = DeviceIORing(sampleRate: sampleRate) else { return nil }
        self.ring = ring
        self.queue = queue
        let drain: @Sendable () -> Void = { while let buffer = ring.read() { receive(buffer) } }
        self.drain = drain
        queue.setSpecific(key: Self.onReaderQueue, value: ObjectIdentifier(queue))
        wake = DispatchSource.makeUserDataAddSource(queue: queue)
        wake.setEventHandler(handler: drain)
        wake.activate()
    }

    deinit { wake.cancel() }

    /// Hands over whatever is still waiting, before returning: the end of a recording is not
    /// left in the ring when the device stops. Safe from the reader's own queue.
    func flush() {
        if DispatchQueue.getSpecific(key: Self.onReaderQueue) == ObjectIdentifier(queue) { drain() } else { queue.sync(execute: drain) }
    }

    /// The audio thread's whole job.
    func take(_ list: UnsafePointer<AudioBufferList>, sampleTime: Double = 0) {
        if ring.write(list, sampleTime: sampleTime) { wake.add(data: 1) }
    }
}

/// A microphone read through its own IO proc: `AudioDeviceCreateIOProcIDWithBlock` on the picked
/// device's ID. No audio unit, no AVAudioEngine and nothing of the system's input is involved.
/// Voice processing does not exist on this path; "Reduce background noise" has no effect on it.
///
/// Kept instead of an input-only audio unit bound to the device (what most shipped apps use)
/// because this path is the one proven on a real Mac with a headset connected: it delivered,
/// started in under 50 ms and left the headset in its music mode (build 2295). The reader follows
/// the rules of the shipped IO-proc readers: copy only on the audio thread, the format from the
/// stream's own virtual format, a gate that shuts when that format changes, and listeners on a
/// queue the audio never waits for.
///
/// A device that goes away, or whose format changes, is reported the way AVAudioEngine reports a
/// configuration change, so the capture's own restart handling deals with both paths alike.
final class DeviceIOMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {
    private static let log = Logger(subsystem: "app.hushy", category: "audio")
    /// Where the capture's own work runs (resampling, metering, the level callback).
    private let queue = DispatchQueue(label: "app.hushy.capture.device-io", qos: .userInteractive)
    /// Where the device's property listeners are delivered: never behind the capture's work, so
    /// a format change shuts the gate at once.
    private let listenerQueue = DispatchQueue(label: "app.hushy.capture.device-io.listeners", qos: .userInteractive)
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var stream: StreamFacts?
    private var handoff: DeviceIOHandoff?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    private struct State {
        var procID: AudioDeviceIOProcID?
        var isRunning = false
        var changeReported = false
        /// Times Core Audio said this process was too slow for the device's IO cycle.
        var overloads = 0
    }

    /// The device's first input stream, as its virtual format describes it.
    struct StreamFacts: Equatable {
        var id: AudioStreamID
        var sampleRate: Double
        var channels: Int
        var inputStreams: Int
    }

    var notificationObject: AnyObject { self }
    var voiceProcessingEnabled: Bool { false }
    var path: CapturePath { .deviceIO }
    var selectsDeviceOnTheSystemUnit: Bool { false }
    /// The IO proc is on the device's own ID: there is nothing to read back.
    var deviceIsReadFromUnit: Bool { false }
    var isDelivering: Bool { lock.withLock { $0.isRunning } && Self.isAlive(deviceID) }

    deinit { stop() }

    func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> AVAudioFormat {
        guard let deviceID, Self.isAlive(deviceID) else { throw DeviceIOError.noDevice }
        guard let stream = Self.firstInputStream(of: deviceID) else { throw DeviceIOError.notFloat32 }
        guard let format = TapFormat.plain(sampleRate: stream.sampleRate, channels: 1) else { throw CaptureGraphError.noInputFormat }
        self.deviceID = deviceID
        self.stream = stream
        return format
    }

    /// One channel at the rate the stream has right now: a different rate from the one the
    /// capture was set up with is what tells it to start again.
    func currentInputFormat() -> AVAudioFormat? {
        Self.firstInputStream(of: deviceID).flatMap { TapFormat.plain(sampleRate: $0.sampleRate, channels: 1) }
    }

    func currentDevice() -> AudioCapture.InputDevice? { AudioCapture.device(deviceID) }

    func installTap(_ receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let stream, let handoff = DeviceIOHandoff(sampleRate: stream.sampleRate, queue: queue, receive: receive) else {
            throw CaptureGraphError.noInputFormat
        }
        var procID: AudioDeviceIOProcID?
        // No queue: the block runs on the device's IO thread either way, and saying so keeps
        // anyone from believing otherwise. It copies and returns (`DeviceIOHandoff.take`).
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, inputTime, _, _ in
            handoff.take(input, sampleTime: inputTime.pointee.mSampleTime)
        }
        guard status == noErr, let procID else { throw DeviceIOError.createFailed(status) }
        self.handoff = handoff
        lock.withLock { $0.procID = procID }
        watchTheDevice(stream: stream.id)
    }

    func start() throws {
        guard let procID = lock.withLock({ $0.procID }) else { throw DeviceIOError.createFailed(noErr) }
        let status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else { throw DeviceIOError.startFailed(status) }
        lock.withLock { $0.isRunning = true }
    }

    /// Stops the device's IO for this proc and removes the proc and the listeners. Safe to call
    /// twice and from `deinit`: a capture that is dropped never leaves the device running.
    func stop() {
        let (procID, wasRunning) = lock.withLock { state -> (AudioDeviceIOProcID?, Bool) in
            let taken = (state.procID, state.isRunning)
            state.procID = nil
            state.isRunning = false
            return taken
        }
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, listenerQueue, listener.block)
        }
        listeners = []
        guard let procID else { return }
        if wasRunning { AudioDeviceStop(deviceID, procID) }
        AudioDeviceDestroyIOProcID(deviceID, procID)
        handoff?.flush()   // the last few milliseconds, after the device has stopped writing
    }

    /// What the audio thread saw in this capture, for the stop line. Numbers only. One line of
    /// counts, and one per callback that held a sample no microphone delivers.
    func diagnostics() -> [String] {
        guard let ring = handoff?.ring, let stream else { return [] }
        let counters = ring.counters
        let overloads = lock.withLock { $0.overloads }
        let summary = "capture device io: stream \(stream.channels) ch \(Int(stream.sampleRate)) Hz of \(stream.inputStreams)"
            + " · callbacks \(counters.callbacks) · frames \(counters.frames)"
            + " · per callback \(counters.smallestCallback) to \(counters.largestCallback)"
            + " · buffers \(counters.fewestBuffers) to \(counters.mostBuffers) · widest \(counters.widestFirstBuffer) ch"
            + " · dropped \(counters.dropped) · gated \(counters.gated) · misfits \(counters.misfits)"
            + " · clock gaps \(counters.gaps) (largest \(counters.largestGap) frames) · overloads \(overloads)"
            + " · over full scale \(counters.faulty)"
        let faults = ring.faults
        return [summary] + faults.enumerated().map { index, fault in
            "capture device io fault \(index + 1) of \(counters.faulty): \(fault.logWords)"
        }
    }

    /// The device went away, or its stream's format changed. A format change shuts the gate at
    /// once: audio read at the old rate would be the right samples at the wrong speed.
    private func watchTheDevice(stream: AudioStreamID) {
        let gone: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reportChange() }
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handoff?.ring.closeGate()
            self?.reportChange()
        }
        // Counted, never acted on: an overload is Core Audio saying a cycle was missed.
        let overload: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.lock.withLock { $0.overloads += 1 } }
        let watched: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = [
            (deviceID, CoreAudioRead.address(kAudioDevicePropertyDeviceIsAlive), gone),
            (deviceID, CoreAudioRead.address(kAudioDevicePropertyNominalSampleRate), changed),
            (deviceID, CoreAudioRead.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput), changed),
            (stream, CoreAudioRead.address(kAudioStreamPropertyVirtualFormat), changed),
            (deviceID, CoreAudioRead.address(kAudioDeviceProcessorOverload), overload),
        ]
        for (object, address, block) in watched {
            var address = address
            if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    private func reportChange() {
        let isFirst = lock.withLock { state -> Bool in
            defer { state.changeReported = true }
            return !state.changeReported && state.procID != nil
        }
        guard isFirst else { return }
        Self.log.notice("capture device io: the device changed or went away")
        // Posted from the main queue: the capture's observer runs there and stops this engine,
        // and that must not happen from the audio thread or from a listener's queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
        }
    }

    // MARK: The device's own facts

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        return (CoreAudioRead.value(device, kAudioDevicePropertyDeviceIsAlive) as UInt32?).map { $0 != 0 } ?? false
    }

    /// The device's first input stream, when its virtual format is one this reader takes:
    /// 32-bit float PCM in the Mac's own byte order, packed. That is what Core Audio presents to
    /// an IO proc on every device seen so far; anything else is refused instead of read as noise.
    static func firstInputStream(of device: AudioDeviceID) -> StreamFacts? {
        guard isAlive(device) else { return nil }
        var address = CoreAudioRead.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first,
              let description: AudioStreamBasicDescription = CoreAudioRead.value(first, kAudioStreamPropertyVirtualFormat),
              isReadable(description) else { return nil }
        return StreamFacts(id: first, sampleRate: description.mSampleRate, channels: Int(description.mChannelsPerFrame),
                           inputStreams: streams.count)
    }

    static func isReadable(_ description: AudioStreamBasicDescription) -> Bool {
        description.mFormatID == kAudioFormatLinearPCM
            && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && description.mFormatFlags & kAudioFormatFlagIsPacked != 0
            && description.mBitsPerChannel == 32
            && description.mSampleRate > 0
            && description.mChannelsPerFrame > 0
    }
}
