@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// What the Microphone setting shows for each resolution, from fixed device lists.
@Suite("Microphone setting: Automatic, and what it resolves to")
@MainActor
struct MicrophoneSettingTests {
    typealias Devices = MicrophoneSelector.Devices
    static let mac = MicrophoneSelectorTests.mac
    static let headset = MicrophoneSelectorTests.headset
    static let desk = MicrophoneSelectorTests.desk

    @Test("the setting shows Automatic with the microphone it resolves to, then every input")
    func settingAutomatic() {
        let devices = Devices(inputs: [Self.mac, Self.headset], systemDefault: Self.headset)
        let state = MicrophoneSettingState(picked: nil, devices: devices)
        #expect(state.automaticLabel == "Automatic · MacBook Pro Microphone")
        #expect(state.entries.map(\.label) == ["MacBook Pro Microphone", "Dana's AirPods Pro"])
        #expect(state.note == "Automatic uses the Mac's microphone when a Bluetooth headset is connected, so the start of what you say is not lost and your music keeps its quality.")
    }

    @Test("Automatic following the system says so")
    func settingFollowsSystem() {
        let state = MicrophoneSettingState(
            picked: nil, devices: Devices(inputs: [Self.mac, Self.desk], systemDefault: Self.desk))
        #expect(state.automaticLabel == "Automatic · Desk Mic")
        #expect(state.note == "Uses the microphone your Mac is set to use.")
    }

    @Test("with a pick, the Automatic entry still shows what Automatic would use, and the line is about the pick")
    func settingPicked() {
        let devices = Devices(inputs: [Self.mac, Self.headset], systemDefault: Self.headset)
        let state = MicrophoneSettingState(picked: "Dana's AirPods Pro", devices: devices)
        #expect(state.automaticLabel == "Automatic · MacBook Pro Microphone")
        #expect(state.note == "Always uses this microphone.")
        #expect(state.entries.count == 2)
    }

    @Test("a picked device that is not connected keeps an entry, so the picker never shows a blank")
    func settingPickedMissing() {
        let state = MicrophoneSettingState(
            picked: "Desk Mic", devices: Devices(inputs: [Self.mac], systemDefault: Self.mac))
        #expect(state.entries.map(\.label) == ["MacBook Pro Microphone", "Desk Mic (not connected)"])
        #expect(state.entries.last?.name == "Desk Mic")
        #expect(state.note == "Desk Mic is not connected, so Hushy uses MacBook Pro Microphone.")
    }

    @Test("the Mac's microphone picked with a headset connected says what that buys and costs")
    func settingMacWithHeadset() {
        let devices = Devices(inputs: [Self.mac, Self.headset], systemDefault: Self.headset)
        let state = MicrophoneSettingState(picked: "MacBook Pro Microphone", devices: devices)
        #expect(state.automaticLabel == "Automatic · MacBook Pro Microphone")
        #expect(state.note.hasPrefix("Dana's AirPods Pro keeps its music quality and noise cancelling."))
        #expect(state.note.contains("Speak up"))
    }

    @Test("the fixed device list stills are drawn with is a laptop on its own microphone")
    func snapshotDevices() {
        let state = MicrophoneSettingState(picked: nil, devices: .snapshot)
        #expect(state.automaticLabel == "Automatic · MacBook Pro Microphone")
    }

    @Test("the first headset fallback notice is one plain line")
    func fallbackNotice() {
        #expect(PillBanner.microphoneFallback(headset: "Dana's AirPods Pro").microphoneFallbackLine
                == "Using Dana's AirPods Pro's microphone · the Mac's is unavailable")
    }

    @Test("quiet-microphone offers match Automatic's actual input")
    func quietMicOffers() {
        let devices = Devices(inputs: [Self.mac, Self.headset], systemDefault: Self.headset)
        let inventory = devices.inventory
        let automatic = MicrophoneResolution.resolve(picked: nil, inventory: inventory)
        let picked = MicrophoneResolution.resolve(picked: Self.headset.name, inventory: inventory)
        let onMac = MicrophoneRecoveryOffer.choose(choice: automatic, used: Self.mac.name,
                                                  builtIn: Self.mac.name, automatic: automatic.using?.name)
        #expect(onMac.mac == nil)
        #expect(!onMac.automatic)
        let onHeadset = MicrophoneRecoveryOffer.choose(choice: picked, used: Self.headset.name,
                                                      builtIn: Self.mac.name, automatic: automatic.using?.name)
        #expect(onHeadset.mac == nil)
        #expect(onHeadset.automatic)
        let old = MicrophoneResolution.resolve(picked: nil, inventory: inventory, followsSystemInput: true)
        let oldOffer = MicrophoneRecoveryOffer.choose(choice: old, used: Self.headset.name,
                                                      builtIn: Self.mac.name, automatic: old.using?.name)
        #expect(oldOffer.mac == Self.mac.name)
        #expect(!oldOffer.automatic)
    }
}
