import CoreAudio
import Foundation
import os

/// What the capture log says about Bluetooth audio devices around one recording, so a person's
/// next try can prove whether a headset's microphone was opened. Numbers only.
struct BluetoothAudioState: Equatable, Sendable {
    /// How many Bluetooth devices with input channels the Mac has.
    var inputs: Int
    /// Whether any of them is running, in any app (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
    var inputRunning: Bool
    /// The first Bluetooth output device's nominal sample rate. A headset in its music mode
    /// plays at 44100 or 48000 Hz; in its call mode (microphone open) at 8000, 16000 or 24000.
    var outputRate: Double?
}

/// Read-only Core Audio facts for the capture log. Nothing here opens, selects or changes a
/// device. Tests use `.none`, so no test asks the Mac about its hardware.
struct CaptureHardwareProbe: Sendable {
    var nominalSampleRate: @Sendable (AudioDeviceID) -> Double?
    /// Whether this process is running I/O on the device (`kAudioDevicePropertyDeviceIsRunning`).
    var isRunning: @Sendable (AudioDeviceID) -> Bool?
    /// Nil when the Mac has no Bluetooth audio device.
    var bluetooth: @Sendable () -> BluetoothAudioState?
    /// Starts watching the Bluetooth inputs' running flag. The returned closure stops watching
    /// and says whether any of them was seen running in between.
    var watchBluetoothInputs: @Sendable () -> (@Sendable () -> Bool)
    /// The system's input right now, and whether a device still exists: what decides the
    /// capture's path (`CapturePath.choose`).
    var systemDefaultInput: @Sendable () -> AudioDeviceID? = { nil }
    var deviceExists: @Sendable (AudioDeviceID) -> Bool = { _ in true }

    static let none = CaptureHardwareProbe(
        nominalSampleRate: { _ in nil }, isRunning: { _ in nil }, bluetooth: { nil },
        watchBluetoothInputs: { { false } })

    static let live = CaptureHardwareProbe(
        nominalSampleRate: { CoreAudioRead.value($0, kAudioDevicePropertyNominalSampleRate) as Double? },
        isRunning: { (CoreAudioRead.value($0, kAudioDevicePropertyDeviceIsRunning) as UInt32?).map { $0 != 0 } },
        bluetooth: {
            let devices = CoreAudioRead.bluetoothDevices()
            guard !devices.inputs.isEmpty || !devices.outputs.isEmpty else { return nil }
            return BluetoothAudioState(
                inputs: devices.inputs.count,
                inputRunning: devices.inputs.contains(where: CoreAudioRead.isRunningSomewhere),
                outputRate: devices.outputs.first.flatMap { CoreAudioRead.value($0, kAudioDevicePropertyNominalSampleRate) as Double? })
        },
        watchBluetoothInputs: {
            let watch = RunningWatch(devices: CoreAudioRead.bluetoothDevices().inputs)
            return { watch.finish() }
        },
        systemDefaultInput: { AudioCapture.defaultInputDeviceID() },
        deviceExists: { DeviceIOMicrophoneEngine.isAlive($0) })
}

extension BluetoothAudioState {
    /// One log line for a capture: the state before it opened anything, once it was running and
    /// when it stopped, and whether a Bluetooth input was seen running at any point in between.
    static func logLine(before: BluetoothAudioState?, started: BluetoothAudioState?, stopped: BluetoothAudioState?,
                        seenRunning: Bool) -> String {
        guard before != nil || started != nil || stopped != nil else { return "capture bluetooth: none" }
        func flag(_ state: BluetoothAudioState?) -> String { state.map { $0.inputRunning ? "1" : "0" } ?? "-" }
        func rate(_ state: BluetoothAudioState?) -> String { state?.outputRate.map { String(Int($0.rounded())) } ?? "-" }
        let inputs = (stopped ?? started ?? before)?.inputs ?? 0
        return "capture bluetooth: inputs \(inputs) · input running before \(flag(before)) · started \(flag(started))"
            + " · stopped \(flag(stopped)) · seen running \(seenRunning ? 1 : 0)"
            + " · output rate \(rate(before)) > \(rate(started)) > \(rate(stopped)) Hz"
    }
}

/// Watches `kAudioDevicePropertyDeviceIsRunningSomewhere` on a set of devices and remembers
/// whether any of them was running at any moment. A listener, never a change.
private final class RunningWatch: @unchecked Sendable {
    private let devices: [AudioDeviceID]
    private let seen = OSAllocatedUnfairLock(initialState: false)
    private let queue = DispatchQueue(label: "app.hushy.capture-proof")
    private var block: AudioObjectPropertyListenerBlock?

    init(devices: [AudioDeviceID]) {
        self.devices = devices
        guard !devices.isEmpty else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sample() }
        self.block = block
        for device in devices {
            var address = CoreAudioRead.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        }
        sample()
    }

    private func sample() {
        if devices.contains(where: CoreAudioRead.isRunningSomewhere) { seen.withLock { $0 = true } }
    }

    func finish() -> Bool {
        if let block {
            for device in devices {
                var address = CoreAudioRead.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            }
            self.block = nil
            sample()
        }
        return seen.withLock { $0 }
    }
}

/// Property reads. Each returns nil when Core Audio cannot answer.
enum CoreAudioRead {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return pointer.pointee
    }

    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        (value(device, kAudioDevicePropertyDeviceIsRunningSomewhere) as UInt32?).map { $0 != 0 } ?? false
    }

    /// Bluetooth audio devices by direction. A headset is usually two devices on a Mac: one with
    /// only input channels (its microphone) and one with only output channels.
    static func bluetoothDevices() -> (inputs: [AudioDeviceID], outputs: [AudioDeviceID]) {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return ([], []) }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return ([], []) }
        let bluetooth = ids.filter {
            let transport: UInt32? = value($0, kAudioDevicePropertyTransportType)
            return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        return (bluetooth.filter { channels($0, scope: kAudioDevicePropertyScopeInput) > 0 },
                bluetooth.filter { channels($0, scope: kAudioDevicePropertyScopeOutput) > 0 })
    }

    static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
