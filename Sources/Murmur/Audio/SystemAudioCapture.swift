@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import MurmurCore
import ScreenCaptureKit
import os

/// Captures "the other side of the call" — system/output audio — alongside the microphone, as
/// 16 kHz mono Float samples, using a Core Audio process tap (macOS 14.4+) with a
/// ScreenCaptureKit audio-only stream as a fallback when taps are unavailable. See
/// `.claude/DECISIONS.md`'s system-audio entry and `docs/research/speaker-labeling.md`.
///
/// Mirrors `AudioCapture`'s shape (same sample rate constant, same `start`/`stop`/`drain`
/// contract, same watchdog-free simplicity) so `NoteRecorder` can drive both engines identically
/// and so the two streams stay easy to reason about as parallel, independent pipelines.
final class SystemAudioCapture: @unchecked Sendable {
    static let sampleRate: Double = AudioCapture.sampleRate

    enum CaptureError: LocalizedError {
        case permissionDenied
        case unsupported
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Call audio permission was not granted."
            case .unsupported: "Call audio capture isn't supported on this Mac."
            case .tapCreationFailed(let status): "Could not start call audio capture (tap error \(status))."
            case .aggregateDeviceFailed(let status): "Could not start call audio capture (device error \(status))."
            case .converterUnavailable: "Could not prepare call audio for transcription."
            }
        }
    }

    private struct CaptureState {
        var samples = AudioSampleBuffer()
        var isRunning = false
        var totalCount = 0
        var onLevel: (@Sendable (Float) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: CaptureState())
    /// False for a note or meeting: drained audio is not kept in memory (notes audit B5), and `stop()`
    /// returns only what was not drained yet. Read at `start`.
    var retainsFullRecording = true
    private var resampler: StreamingResampler?
    private var resamplerFormat: AVAudioFormat?
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var scStream: SCStream?
    private var scOutput: ScreenCaptureAudioOutput?
    private var usingFallback = false

    private static let log = Logger(subsystem: "app.hushy", category: "system-audio")

    var isRunning: Bool { state.withLock { $0.isRunning } }

    /// Duration of audio captured so far, in seconds — same contract as `AudioCapture.capturedSeconds`.
    var capturedSeconds: Double {
        Double(state.withLock { $0.totalCount }) / Self.sampleRate
    }

    /// What Hushy last learned about system-audio permission. Core Audio process taps have no
    /// preflight API and don't use Screen Recording: macOS shows its own "System Audio
    /// Recording" prompt the first time a tap starts (using NSAudioCaptureUsageDescription),
    /// and a refused tap simply delivers silence. So the state is learned from real captures
    /// (`remember(_:)`, fed by `SystemAudioVerdict`) rather than asked up front.
    static func permissionState() -> SystemAudioPermissionState {
        guard #available(macOS 14.4, *) else { return .unsupported }
        switch UserDefaults.standard.string(forKey: permissionKey) {
        case "granted": return .granted
        case "denied": return .denied
        default: return .notDetermined
        }
    }

    static func remember(_ state: SystemAudioPermissionState) {
        let value: String? = switch state {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined, .unsupported: nil
        }
        UserDefaults.standard.set(value, forKey: permissionKey)
    }

    private static let permissionKey = "systemAudio.permission"

    /// Starts capturing system audio. Tries a Core Audio process tap first (macOS 14.4+,
    /// excludes Hushy's own process so its own UI sounds/pill audio never get captured); falls
    /// back to a ScreenCaptureKit audio-only stream only when the tap path is unavailable (e.g.
    /// an older OS within the 14.x range that lacks the tap API, or a sandboxing edge case).
    ///
    /// `async` (unlike `AudioCapture.start`) because the ScreenCaptureKit fallback path needs to
    /// `await SCStream.startCapture()`; the process-tap path (the common case) has no `await` of
    /// its own and returns as soon as its synchronous Core Audio calls complete.
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws {
        await stop()
        state.withLock {
            $0 = CaptureState()
            $0.samples = AudioSampleBuffer(retainsFullRecording: retainsFullRecording)
            $0.onLevel = onLevel
        }

        if #available(macOS 14.4, *) {
            do {
                try startProcessTap()
                usingFallback = false
                state.withLock { $0.isRunning = true }
                return
            } catch {
                Self.log.error("process tap unavailable, falling back to ScreenCaptureKit: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await startScreenCaptureKitFallback()
        usingFallback = true
        state.withLock { $0.isRunning = true }
    }

    @discardableResult
    func stop() async -> [Float] {
        stopProcessTap()
        await stopScreenCaptureKitFallback()
        let samples = state.withLock { current -> [Float] in
            current.isRunning = false
            current.onLevel = nil
            return current.samples.allSamples()
        }
        return samples
    }

    /// Capture health found the call's audio stalled or zeroed (notes audit B4): a default-output change can reset
    /// the tap, and the stream format is read once per tap. Tears the tap (or the fallback stream) down and builds it
    /// again, keeping what was captured. False when not running or the rebuild failed.
    func rebuild() async -> Bool {
        guard isRunning else { return false }
        stopProcessTap()
        await stopScreenCaptureKitFallback()
        do {
            if #available(macOS 14.4, *), !usingFallback {
                try startProcessTap()
            } else {
                try await startScreenCaptureKitFallback()
            }
            Self.log.notice("call audio rebuilt")
            return true
        } catch {
            Self.log.error("call audio rebuild failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Returns and releases samples captured since the previous drain — same contract as
    /// `AudioCapture.drain()`.
    func drain() -> [Float] {
        state.withLock { $0.samples.drain() }
    }

    // MARK: - Core Audio process tap

    @available(macOS 14.4, *)
    private func startProcessTap() throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownAudioObjectID = Self.processObjectID(forPID: ownPID)
        let description: CATapDescription
        if let ownAudioObjectID {
            // Prefer excluding Hushy explicitly by process object, per the task's guidance
            // ("prefer a global tap excluding Hushy's own process"): every other app's output is
            // captured, so a call in any app (Zoom, FaceTime, a browser tab, Phone Mirroring) is
            // picked up without needing to know which app the user is calling from.
            description = CATapDescription(monoGlobalTapButExcludeProcesses: [ownAudioObjectID])
        } else {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let createStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard createStatus == noErr else { throw CaptureError.tapCreationFailed(createStatus) }
        tapID = newTapID

        let tapUID = description.uuid.uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hushy System Audio Tap",
            kAudioAggregateDeviceUIDKey: "app.hushy.systemaudio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw CaptureError.aggregateDeviceFailed(aggregateStatus)
        }
        aggregateDeviceID = newAggregateID

        guard let format = Self.streamFormat(forAggregateDevice: aggregateDeviceID) else {
            teardownProcessTap()
            throw CaptureError.converterUnavailable
        }
        guard let resampler = StreamingResampler(from: format) else {
            teardownProcessTap()
            throw CaptureError.converterUnavailable
        }
        self.resampler = resampler
        resamplerFormat = format

        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            self?.process(inputData, format: format)
        }
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock)
        guard procStatus == noErr, let procID else {
            teardownProcessTap()
            throw CaptureError.tapCreationFailed(procStatus)
        }
        deviceProcID = procID
        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            teardownProcessTap()
            throw CaptureError.tapCreationFailed(startStatus)
        }
    }

    private func stopProcessTap() {
        guard #available(macOS 14.4, *) else { return }
        teardownProcessTap()
    }

    @available(macOS 14.4, *)
    private func teardownProcessTap() {
        if let deviceProcID {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            self.deviceProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// The `AudioObjectID` of the running process matching `pid`, used to exclude Hushy's own
    /// audio output from the global tap. Returns `nil` (rather than throwing) when the process
    /// object can't be found — the tap still works as a global-minus-nothing tap in that case,
    /// just without the self-exclusion optimization, so this is treated as best-effort.
    @available(macOS 14.4, *)
    private static func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }

        for objectID in ids {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var objectPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &objectPID) == noErr else { continue }
            if objectPID == pid { return objectID }
        }
        return nil
    }

    private static func streamFormat(forAggregateDevice deviceID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    private func process(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList) else { return }
        guard let resampler else { return }
        let chunk = resampler.convert(pcmBuffer)
        guard !chunk.isEmpty else { return }
        let rms = StreamingResampler.rms(chunk)
        let onLevel = state.withLock { current -> (@Sendable (Float) -> Void)? in
            current.samples.append(contentsOf: chunk)
            current.totalCount += chunk.count
            return current.onLevel
        }
        onLevel?(rms)
    }

    // MARK: - ScreenCaptureKit fallback

    /// Audio-only ScreenCaptureKit capture, used only when the Core Audio process tap path
    /// throws (older OS within range, or a tap/aggregate-device failure). Captures the whole
    /// display's audio output rather than excluding Hushy specifically — ScreenCaptureKit's
    /// per-app audio exclusion API is less consistent across macOS versions, and Hushy itself
    /// makes negligible sound (no music/media playback), so the tiny risk of self-capture here
    /// is an acceptable tradeoff for a fallback path that should rarely be exercised in practice.
    private func startScreenCaptureKitFallback() async throws {
        // Only this fallback path uses Screen Recording; never prompt for it just to try.
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.permissionDenied
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Minimal video config: SCStream requires a video track even for audio-only capture on
        // most OS versions; keep it tiny since the frames themselves are discarded.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = ScreenCaptureAudioOutput { [weak self] buffer in
            self?.processFallback(buffer)
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "app.hushy.systemaudio.fallback"))
        try await stream.startCapture()

        scStream = stream
        scOutput = output
    }

    private func stopScreenCaptureKitFallback() async {
        guard let stream = scStream else { return }
        try? await stream.stopCapture()
        scStream = nil
        scOutput = nil
    }

    private func processFallback(_ buffer: AVAudioPCMBuffer) {
        if resamplerFormat == nil || resamplerFormat?.sampleRate != buffer.format.sampleRate
            || resamplerFormat?.channelCount != buffer.format.channelCount {
            resampler = StreamingResampler(from: buffer.format)
            resamplerFormat = buffer.format
        }
        guard let resampler else { return }
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        let rms = StreamingResampler.rms(chunk)
        let onLevel = state.withLock { current -> (@Sendable (Float) -> Void)? in
            current.samples.append(contentsOf: chunk)
            current.totalCount += chunk.count
            return current.onLevel
        }
        onLevel?(rms)
    }
}

/// Thin `SCStreamOutput` adapter converting `CMSampleBuffer` audio into an `AVAudioPCMBuffer`
/// for the ScreenCaptureKit fallback path.
private final class ScreenCaptureAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return }
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else { return }

        if format.isInterleaved, let channelData = pcmBuffer.floatChannelData {
            dataPointer.withMemoryRebound(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size) { floats in
                let channelCount = Int(format.channelCount)
                for frame in 0..<Int(frameCount) {
                    for channel in 0..<channelCount {
                        channelData[channel][frame] = floats[frame * channelCount + channel]
                    }
                }
            }
        }
        onBuffer(pcmBuffer)
    }
}
