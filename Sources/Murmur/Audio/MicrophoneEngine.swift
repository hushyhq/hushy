@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import HushyObjC

/// Hardware seam: each instance owns one capture graph and is discarded after stopping.
protocol MicrophoneEngine: AnyObject {
    var notificationObject: AnyObject { get }
    var voiceProcessingEnabled: Bool { get }
    func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> AVAudioFormat
    /// As `configure`, and when `strictDevice` is set, throws unless the graph is on exactly `deviceID`
    /// (a failed selection otherwise leaves it on the system default input). Off in the app.
    func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool, strictDevice: Bool) throws -> AVAudioFormat
    /// Throws, and never raises, when the graph cannot take the tap (`CaptureGraphError`): the
    /// caller drops this engine and builds another.
    func installTap(_ receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func start() throws
    func stop()
    /// Whether the graph is still delivering audio. Fakes that never claim so keep the old behaviour.
    var isDelivering: Bool { get }
    /// The input format the graph has right now (`nil` when unknown).
    func currentInputFormat() -> AVAudioFormat?
    /// The device the configured graph records from (`nil` when it cannot be named). Asked once
    /// per start, after `configure`, for the capture log and the quiet-microphone row. Fakes say
    /// nothing unless a test gives them a device, so no test asks the Mac about its hardware.
    func currentDevice() -> AudioCapture.InputDevice?
    /// Whether `currentDevice` was read back from the graph's own input unit, or is only what
    /// was asked for (voice processing hides the real device behind a private aggregate).
    var deviceIsReadFromUnit: Bool { get }
    /// Which way this engine reads the microphone, for the capture log.
    var path: CapturePath { get }
    /// Whether asking for a device moves the system's input unit to it, which by itself posts
    /// one configuration change the capture must not answer with a restart.
    var selectsDeviceOnTheSystemUnit: Bool { get }
    /// What the engine's audio thread saw in this capture, as log lines of numbers; empty when
    /// the engine has nothing to say. Asked once, after `stop`.
    func diagnostics() -> [String]
    /// The sample rate the hardware delivers right now, read from the device side of the graph;
    /// nil when the engine cannot say. The graph's own format can be stale after a device has
    /// changed its rate (a headset moving between profiles), and audio decoded at a stale rate
    /// is the right samples at the wrong speed.
    func hardwareSampleRate() -> Double?
}

extension MicrophoneEngine {
    func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool, strictDevice: Bool) throws -> AVAudioFormat {
        try configure(deviceID: deviceID, voiceProcessing: voiceProcessing)
    }
    var isDelivering: Bool { false }
    func currentInputFormat() -> AVAudioFormat? { nil }
    func currentDevice() -> AudioCapture.InputDevice? { nil }
    var deviceIsReadFromUnit: Bool { false }
    var path: CapturePath { .engine }
    var selectsDeviceOnTheSystemUnit: Bool { true }
    func diagnostics() -> [String] { [] }
    func hardwareSampleRate() -> Double? { nil }
}

/// A capture graph that could not be built or started for a reason that is ordinary while audio
/// devices are changing. Every case is an error the capture handles by dropping the engine and
/// building a fresh one within its restart budget; none of them may end the app.
enum CaptureGraphError: LocalizedError, Equatable {
    /// AVFAudio raised an Objective-C exception in `step`. `reason` is the framework's own text
    /// (a failed condition and formats; never anything a person said).
    case raised(step: String, reason: String)
    /// The input has no usable format right now (no sample rate or no channels).
    case noInputFormat
    /// The hardware's sample rate changed between configuring the graph and installing the tap.
    case formatChanged(fromRate: Double, toRate: Double)

    var errorDescription: String? {
        switch self {
        case .raised(let step, let reason): "The audio system refused to \(step): \(reason)"
        case .noInputFormat: "The microphone has no audio format right now."
        case .formatChanged(let from, let to):
            "The microphone's sample rate changed from \(Int(from)) to \(Int(to)) Hz while starting."
        }
    }

    /// The log's word for it: fixed words and numbers only.
    var logWord: String {
        switch self {
        case .raised(let step, _): "exception in \(step)"
        case .noInputFormat: "no input format"
        case .formatChanged(let from, let to): "format changed \(Int(from)) > \(Int(to)) Hz"
        }
    }
}

enum ObjCExceptions {
    /// Runs `body` and returns its value. An Objective-C exception raised inside comes back as
    /// `CaptureGraphError.raised`; a Swift error thrown inside is rethrown unchanged.
    static func catching<T>(_ step: String, _ body: () throws -> T) throws -> T {
        var outcome: Result<T, Error>?
        do {
            try HushyObjCExceptionCatcher.perform { outcome = Result { try body() } }
        } catch let error as NSError where error.domain == HushyObjCExceptionDomain {
            throw CaptureGraphError.raised(step: step, reason: error.userInfo[HushyObjCExceptionReasonKey] as? String ?? "")
        }
        guard let outcome else { throw CaptureGraphError.raised(step: step, reason: "") }
        return try outcome.get()
    }
}

/// The format an input tap is installed with.
///
/// AVAudioEngine raises an exception when a tap's sample rate is not the hardware's, and the input
/// unit cannot convert sample rates (Apple TN2091), so a tap at any other rate gets no audio at
/// all. The input node's own "output format" can be stale: it is cached from the device the node
/// was created on, and stays when the unit is moved to another device (2026-10-13: a tap at a
/// headset's 16 kHz on the Mac's 48 kHz microphone). So the hardware's format, read from the
/// unit, decides.
enum TapFormat {
    struct Hardware: Equatable {
        var sampleRate: Double
        var channels: UInt32
    }

    /// `client` is what the input node offers; `hardware` is what the device delivers, when the
    /// unit can say. Throws when there is no usable format.
    static func resolve(client: AVAudioFormat, hardware: Hardware?) throws -> AVAudioFormat {
        guard let hardware else {
            guard client.sampleRate > 0, client.channelCount > 0 else { throw CaptureGraphError.noInputFormat }
            return client
        }
        guard hardware.sampleRate > 0, hardware.channels > 0 else { throw CaptureGraphError.noInputFormat }
        if client.sampleRate == hardware.sampleRate, client.channelCount == hardware.channels { return client }
        guard let format = plain(sampleRate: hardware.sampleRate, channels: hardware.channels) else {
            throw CaptureGraphError.noInputFormat
        }
        return format
    }

    /// Checked again right before the tap goes in: the rate the tap was planned at must still be
    /// the hardware's.
    static func check(_ planned: AVAudioFormat, against hardware: Hardware?) throws {
        guard let hardware else { return }
        guard hardware.sampleRate > 0, hardware.channels > 0 else { throw CaptureGraphError.noInputFormat }
        guard hardware.sampleRate == planned.sampleRate else {
            throw CaptureGraphError.formatChanged(fromRate: planned.sampleRate, toRate: hardware.sampleRate)
        }
    }

    static func plain(sampleRate: Double, channels: UInt32) -> AVAudioFormat? {
        if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }
}

/// Why a strict device selection was refused.
enum DeviceSelectionError: LocalizedError, Equatable {
    case noDeviceRequested
    case noAudioUnit
    case setFailed(OSStatus)
    case readBackFailed(OSStatus)
    case differentDevice(requested: AudioDeviceID, actual: AudioDeviceID)

    var errorDescription: String? {
        switch self {
        case .noDeviceRequested: "A strict capture needs a requested input device."
        case .noAudioUnit: "The input has no audio unit to select the device on."
        case .setFailed(let status): "Selecting the input device failed (\(status))."
        case .readBackFailed(let status): "Could not read back the selected input device (\(status))."
        case .differentDevice(let requested, let actual):
            "The input is on device \(actual), not the requested \(requested)."
        }
    }
}

enum DeviceSelection {
    /// The selection counts only if the set succeeded and reading the property back gives the requested device.
    static func verify(setStatus: OSStatus, requested: AudioDeviceID,
                       readBack: Result<AudioDeviceID, DeviceSelectionError>) throws {
        guard setStatus == noErr else { throw DeviceSelectionError.setFailed(setStatus) }
        let actual = try readBack.get()
        guard actual == requested else { throw DeviceSelectionError.differentDevice(requested: requested, actual: actual) }
    }
}

final class SystemMicrophoneEngine: MicrophoneEngine {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    /// The device `configure` was asked for (nil = the system default input).
    private var requestedDevice: AudioDeviceID?
    /// The format the tap goes in with: decided once, in `configure`, and not read again.
    private var tapFormat: AVAudioFormat?
    private(set) var deviceIsReadFromUnit = false
    var notificationObject: AnyObject { engine }
    // Every call into the engine goes through `ObjCExceptions.catching`: AVFAudio raises
    // exceptions, which Swift cannot catch, when devices change under it.
    var voiceProcessingEnabled: Bool {
        (try? ObjCExceptions.catching("read voice processing") { engine.inputNode.isVoiceProcessingEnabled }) ?? false
    }
    var isDelivering: Bool { engine.isRunning }
    func currentInputFormat() -> AVAudioFormat? {
        try? ObjCExceptions.catching("read the input format") { engine.inputNode.outputFormat(forBus: 0) }
    }
    func hardwareSampleRate() -> Double? {
        (try? ObjCExceptions.catching("read the hardware format") { Self.hardwareFormat(of: engine.inputNode) })??.sampleRate
    }

    /// The device the input unit says it is on. Voice processing puts the unit on a private
    /// aggregate whose name means nothing to a person, so then (and when the unit cannot say) it
    /// is the device that was asked for, or the system default input.
    func currentDevice() -> AudioCapture.InputDevice? {
        let onUnit = inputUnit()
            .flatMap { try? Self.selectedDevice(of: $0).get() }
            .flatMap(AudioCapture.device)
        if let onUnit, onUnit.transport != .aggregate {
            deviceIsReadFromUnit = true
            return onUnit
        }
        deviceIsReadFromUnit = false
        return (requestedDevice ?? AudioCapture.defaultInputDeviceID()).flatMap(AudioCapture.device) ?? onUnit
    }

    func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> AVAudioFormat {
        try configure(deviceID: deviceID, voiceProcessing: voiceProcessing, strictDevice: false)
    }

    func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool, strictDevice: Bool) throws -> AVAudioFormat {
        requestedDevice = deviceID
        let format = try ObjCExceptions.catching("configure the input") {
            let input = engine.inputNode
            if input.isVoiceProcessingEnabled != voiceProcessing {
                do {
                    try input.setVoiceProcessingEnabled(voiceProcessing)
                    if voiceProcessing {
                        input.isVoiceProcessingAGCEnabled = true
                        input.voiceProcessingOtherAudioDuckingConfiguration =
                            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                                enableAdvancedDucking: false, duckingLevel: .min)
                    }
                } catch {
                    NSLog("Hushy: voice processing unavailable: \(error.localizedDescription)")
                }
            }
            // Voice processing replaces the I/O unit. Select the device on the final unit.
            try selectDevice(deviceID, strict: strictDevice, on: input)
            // The node's own format can still be the one of the device it was created on.
            return try TapFormat.resolve(client: input.outputFormat(forBus: 0), hardware: Self.hardwareFormat(of: input))
        }
        tapFormat = format
        return format
    }

    private func inputUnit() -> AudioUnit? {
        (try? ObjCExceptions.catching("read the input unit") { engine.inputNode.audioUnit }) ?? nil
    }

    private func selectDevice(_ requested: AudioDeviceID?, strict: Bool, on input: AVAudioInputNode) throws {
        guard var deviceID = requested else {
            if strict { throw DeviceSelectionError.noDeviceRequested }
            return
        }
        guard let unit = input.audioUnit else {
            if strict { throw DeviceSelectionError.noAudioUnit }
            return
        }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if strict {
            try DeviceSelection.verify(setStatus: status, requested: deviceID, readBack: Self.selectedDevice(of: unit))
        }
    }

    private static func selectedDevice(of unit: AudioUnit) -> Result<AudioDeviceID, DeviceSelectionError> {
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &current, &size)
        return status == noErr ? .success(current) : .failure(.readBackFailed(status))
    }

    /// What the device delivers, from the unit itself: the input scope of element 1 is the
    /// device side (Apple TN2091). Falls back to the node's own hardware format; nil when
    /// neither can say.
    private static func hardwareFormat(of input: AVAudioInputNode) -> TapFormat.Hardware? {
        if let unit = input.audioUnit {
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &description, &size) == noErr {
                return TapFormat.Hardware(sampleRate: description.mSampleRate, channels: description.mChannelsPerFrame)
            }
        }
        let format = input.inputFormat(forBus: 0)
        return TapFormat.Hardware(sampleRate: format.sampleRate, channels: format.channelCount)
    }

    func installTap(_ receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let tapFormat else { throw CaptureGraphError.noInputFormat }
        try ObjCExceptions.catching("install the tap") {
            let input = engine.inputNode
            try TapFormat.check(tapFormat, against: Self.hardwareFormat(of: input))
            input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
                receive(buffer)
            }
        }
        tapInstalled = true
    }

    func start() throws {
        try ObjCExceptions.catching("start the engine") {
            engine.prepare()
            try engine.start()
        }
    }

    func stop() {
        _ = try? ObjCExceptions.catching("stop the engine") {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
    }
}
