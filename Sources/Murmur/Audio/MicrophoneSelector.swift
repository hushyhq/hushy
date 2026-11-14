import CoreAudio
import Foundation
import MurmurCore

/// Chooses the device each recording opens, from the Microphone setting and what the Mac has
/// (`MicrophoneResolution` is the rule). One instance for the app, so the setting's label, the
/// menu bar menu, onboarding's check and every capture (dictation, voice actions, meeting
/// notes, Tune, Voice Lab) agree.
///
/// It only reads: the device list and the system's default input. It never selects a system
/// device and holds no input open.
@MainActor
final class MicrophoneSelector {
    static let shared = MicrophoneSelector()
    static let legacyAutomaticKey = "microphoneAutomaticFollowsSystemInput"

    /// What the Mac has right now, with Core Audio's ids for opening a device by name.
    struct Devices {
        var inputs: [AudioCapture.InputDevice]
        var systemDefault: AudioCapture.InputDevice?

        var inventory: MicrophoneInventory {
            MicrophoneInventory(
                inputs: inputs.map { MicrophoneCandidate(name: $0.name, transport: $0.transport, isUsable: $0.isUsable) },
                systemDefault: systemDefault.map { MicrophoneCandidate(name: $0.name, transport: $0.transport) })
        }
    }

    /// A microphone taken from the quiet-microphone row's offer and not yet shown to deliver sound,
    /// with the setting it replaced (nil is Automatic). The next recording settles it: sound, and
    /// the pick stays; hardly any, and the setting goes back (`DictationController.noTextFailure`).
    struct Trial: Equatable {
        var picked: String
        var previous: String?
    }
    var trial: Trial?
    /// Microphones whose trial failed in this launch: the row does not offer them again.
    var failedTrials: Set<String> = []

    /// Where the device list comes from. Tests and snapshots give a fixed one, so they never ask
    /// the Mac about its hardware.
    var probe: () -> Devices
    var followsSystemInput: () -> Bool

    init(probe: @escaping () -> Devices = MicrophoneSelector.liveDevices,
         followsSystemInput: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: MicrophoneSelector.legacyAutomaticKey) }) {
        self.probe = probe
        self.followsSystemInput = followsSystemInput
    }

    /// What a recording would open for this setting (`picked` nil is Automatic).
    func resolution(picked: String?) -> MicrophoneResolution {
        MicrophoneResolution.resolve(picked: picked, inventory: probe().inventory, followsSystemInput: followsSystemInput())
    }

    /// Points `audio` at the device for this setting, for its next `start`, and tells it how the
    /// device was chosen (for the capture log). Returns the choice. Automatic names a device only
    /// when the Bluetooth rule chooses an input other than the system default.
    @discardableResult
    func prepare(_ audio: AudioCapture, picked: String?) -> MicrophoneResolution {
        let devices = probe()
        let resolution = MicrophoneResolution.resolve(picked: picked, inventory: devices.inventory,
                                                     followsSystemInput: followsSystemInput())
        audio.preferredDeviceID = resolution.deviceName.flatMap { name in devices.inputs.first { $0.name == name }?.id }
        audio.choice = resolution
        return resolution
    }

    // MARK: The Mac's own answers (read-only)

    nonisolated static func liveDevices() -> Devices {
        let inputs = AudioCapture.inputDevices()
        let systemDefault = AudioCapture.defaultInputDeviceID().flatMap { id in
            inputs.first { $0.id == id } ?? AudioCapture.device(id)
        }
        return Devices(inputs: inputs, systemDefault: systemDefault)
    }
}
