import CoreAudio
import Foundation

/// Device selection for `murmur-eval head-to-head play`: the founder installs a virtual audio
/// device themselves (BlackHole, Loopback, …) and this tool plays the recorded WAVs to it, so
/// the same audio reaches both Hushy and Wispr Flow. This file is the pure, hardware-free half
/// — name matching and listing formatting — split out from `HeadToHeadPlayback.swift` so it can
/// be unit tested without CoreAudio actually enumerating a device.
enum HeadToHeadDevices {
    /// One playback-capable device, trimmed to what the CLI needs (`AudioCapture.InputDevice`
    /// in `Sources/Murmur/Audio/AudioCapture.swift` is the input-side twin of this).
    struct OutputDevice: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        let name: String
    }

    /// Picks a device by case-insensitive exact match first, then substring match, so
    /// `--device blackhole` matches "BlackHole 2ch" without the founder typing the exact name.
    /// Ambiguous substring matches (e.g. two devices both containing "blackhole") are rejected
    /// rather than guessed, since playing into the wrong device silently breaks the whole run.
    enum MatchResult: Equatable {
        case found(OutputDevice)
        case notFound
        case ambiguous([OutputDevice])
    }

    static func match(_ query: String, in devices: [OutputDevice]) -> MatchResult {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return .notFound }
        if let exact = devices.first(where: { $0.name.lowercased() == needle }) {
            return .found(exact)
        }
        let substring = devices.filter { $0.name.lowercased().contains(needle) }
        switch substring.count {
        case 0: return .notFound
        case 1: return .found(substring[0])
        default: return .ambiguous(substring)
        }
    }

    static func listing(_ devices: [OutputDevice]) -> String {
        guard !devices.isEmpty else { return "No output devices found." }
        return devices.map { "  \($0.name)" }.joined(separator: "\n")
    }

    // MARK: CoreAudio enumeration (not exercised by unit tests — no hardware in CI)

    static func outputDevices() -> [OutputDevice] {
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
            guard outputChannelCount(id) > 0, let name = deviceName(id) else { return nil }
            return OutputDevice(id: id, name: name)
        }
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
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
}
