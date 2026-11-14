@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// A voice action records from the microphone a dictation would: both go through the app's one
/// selector. A fake device list; nothing is opened (`prepareMicrophone` only points the capture).
@Suite("Microphone selector: a voice action uses the microphone a dictation would")
@MainActor
struct MicrophoneVoiceActionTests {
    typealias Devices = MicrophoneSelector.Devices
    static let mac = MicrophoneSelectorTests.mac
    static let headset = MicrophoneSelectorTests.headset
    static let desk = MicrophoneSelectorTests.desk

    private func controller(_ microphones: MicrophoneSelector, picked: String?) throws -> VoiceActionsController {
        let integrity = SpeechModelIntegrity(
            fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: "hushy-test-\(UUID().uuidString)")
        let controller = VoiceActionsController(
            hotkeys: ActionHotkeyMonitor(), pill: PillModel(),
            speech: SpeechEngine(status: SpeechModelStatus(), integrity: integrity),
            modelStatus: SpeechModelStatus(), store: try Store(), calendarBackend: FakeCalendarBackend(),
            shortcutsBackend: FakeShortcutsBackend())
        controller.microphones = microphones
        controller.pickedMicrophone = { picked }
        return controller
    }

    /// What a dictation opens for the same setting and the same devices.
    private func dictation(_ microphones: MicrophoneSelector, picked: String?) -> (id: AudioDeviceID?, rule: MicrophoneResolution.Rule) {
        let audio = AudioCapture(makeEngine: { AudioCaptureLifecycleTests.FakeEngine() })
        let chosen = microphones.prepare(audio, picked: picked)
        return (audio.preferredDeviceID, chosen.rule)
    }

    @Test("an action and a dictation open the same device, for Automatic and for a pick",
          arguments: [nil, "Dana's AirPods Pro", "MacBook Pro Microphone", "Desk Mic"] as [String?])
    func sameMicrophone(picked: String?) throws {
        for system in [Self.headset, Self.mac] {
            let microphones = MicrophoneSelector(probe: { Devices(inputs: [Self.mac, Self.headset], systemDefault: system) })
            let action = try controller(microphones, picked: picked)
            let chosen = action.prepareMicrophone()
            let spoken = dictation(microphones, picked: picked)
            #expect(action.audio.preferredDeviceID == spoken.id)
            #expect(chosen.rule == spoken.rule)
            #expect(action.audio.choice == chosen)
        }
    }

    @Test("Automatic with a headset as the Mac's input: the action records from the Mac's microphone, as a dictation does")
    func usesTheMacMicrophoneOverAHeadset() throws {
        let microphones = MicrophoneSelector(probe: { Devices(inputs: [Self.mac, Self.headset], systemDefault: Self.headset) })
        let action = try controller(microphones, picked: nil)
        let chosen = action.prepareMicrophone()
        #expect(chosen.rule == .builtInOverBluetooth)
        #expect(chosen.using?.name == "MacBook Pro Microphone")
        #expect(action.audio.preferredDeviceID == Self.mac.id)
    }

    @Test("Automatic with a headset and no usable Mac microphone: the action uses the headset, and selects no device")
    func usesTheHeadsetWhenItIsAllThereIs() throws {
        let microphones = MicrophoneSelector(probe: { Devices(inputs: [Self.headset], systemDefault: Self.headset) })
        let action = try controller(microphones, picked: nil)
        let chosen = action.prepareMicrophone()
        #expect(chosen.rule == .headsetFallback)
        #expect(chosen.using?.name == "Dana's AirPods Pro")
        #expect(action.audio.preferredDeviceID == nil)
    }
}
