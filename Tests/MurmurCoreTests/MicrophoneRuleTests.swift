import Foundation
import Testing
@testable import MurmurCore

/// Which microphone a recording opens for each setting and each set of devices. Device names are
/// invented; nothing here asks a Mac about its hardware.
@Suite("Microphone rule: Automatic prefers the Mac when system input is Bluetooth")
struct MicrophoneRuleTests {
    static let mac = MicrophoneCandidate(name: "MacBook Pro Microphone", transport: .builtIn)
    static let headset = MicrophoneCandidate(name: "Dana's AirPods Pro", transport: .bluetooth)
    static let desk = MicrophoneCandidate(name: "Desk Mic", transport: .usb)

    private func resolve(_ picked: String?, inputs: [MicrophoneCandidate], system: MicrophoneCandidate?) -> MicrophoneResolution {
        MicrophoneResolution.resolve(picked: picked, inventory: MicrophoneInventory(inputs: inputs, systemDefault: system))
    }

    // MARK: The rule

    @Test("Automatic with a Bluetooth system input uses the built-in device")
    func automaticUsesTheHeadset() {
        let resolution = resolve(nil, inputs: [Self.mac, Self.headset], system: Self.headset)
        #expect(resolution.rule == .builtInOverBluetooth)
        #expect(resolution.deviceName == Self.mac.name)
        #expect(resolution.using == Self.mac)
        #expect(resolution.logWord == "auto: built-in, system input is bluetooth")
    }

    @Test("unavailable built-in input falls back to wired, then headset")
    func fallbacks() {
        let unavailable = MicrophoneCandidate(name: Self.mac.name, transport: .builtIn, isUsable: false)
        let wired = resolve(nil, inputs: [unavailable, Self.headset, Self.desk], system: Self.headset)
        #expect(wired.rule == .wiredFallback)
        #expect(wired.deviceName == Self.desk.name)
        #expect(wired.logWord == "auto: wired fallback, no built-in")
        let headset = resolve(nil, inputs: [unavailable, Self.headset], system: Self.headset)
        #expect(headset.rule == .headsetFallback)
        #expect(headset.deviceName == nil)
        #expect(headset.logWord == "auto: headset, nothing else")
        let missing = resolve(nil, inputs: [Self.headset, Self.desk], system: Self.headset)
        #expect(missing.rule == .wiredFallback)
        #expect(missing.using == Self.desk)
        let alone = resolve(nil, inputs: [Self.headset], system: Self.headset)
        #expect(alone.rule == .headsetFallback)
        #expect(alone.using == Self.headset)
    }

    @Test("the old Automatic behavior remains available through one flag")
    func legacyAutomatic() {
        let inventory = MicrophoneInventory(inputs: [Self.mac, Self.headset], systemDefault: Self.headset)
        let chosen = MicrophoneResolution.resolve(picked: nil, inventory: inventory, followsSystemInput: true)
        #expect(chosen.rule == .followsSystem)
        #expect(chosen.deviceName == nil)
        #expect(chosen.using == Self.headset)
    }

    @Test("Automatic follows a non-Bluetooth system input", arguments: [mac, desk, nil] as [MicrophoneCandidate?])
    func automaticFollowsTheSystem(system: MicrophoneCandidate?) {
        let resolution = resolve(nil, inputs: [Self.mac, Self.headset, Self.desk], system: system)
        #expect(resolution.rule == .followsSystem)
        #expect(resolution.deviceName == nil)
        #expect(resolution.using == system)
    }

    @Test("a pick is opened by name, the Mac's microphone and the headset alike")
    func pickWins() {
        let both = [Self.mac, Self.headset]
        let mac = resolve("MacBook Pro Microphone", inputs: both, system: Self.headset)
        #expect(mac.rule == .picked)
        #expect(mac.deviceName == "MacBook Pro Microphone")
        #expect(mac.using == Self.mac)
        let headset = resolve("Dana's AirPods Pro", inputs: both, system: Self.mac)
        #expect(headset.rule == .picked)
        #expect(headset.deviceName == "Dana's AirPods Pro")
        #expect(headset.logWord == "picked")
    }

    @Test("a picked device that is not connected: the system input, and the pick is remembered by name")
    func pickedMissing() {
        let resolution = resolve("Desk Mic", inputs: [Self.mac, Self.headset], system: Self.headset)
        #expect(resolution.rule == .pickedMissing)
        #expect(resolution.deviceName == nil)
        #expect(resolution.using == Self.headset)
        #expect(resolution.missing == "Desk Mic")
        #expect(resolution.logWord == "picked device missing: system input")
    }

    @Test("the Mac's microphone picked with a headset connected leaves that headset alone, wherever the system input points")
    func macPickedWithHeadset() {
        for system in [Self.headset, Self.mac] {
            let resolution = resolve("MacBook Pro Microphone", inputs: [Self.mac, Self.desk, Self.headset], system: system)
            #expect(resolution.headsetLeftAlone == Self.headset)
        }
        #expect(resolve("MacBook Pro Microphone", inputs: [Self.mac, Self.desk], system: Self.desk).headsetLeftAlone == nil)
        #expect(resolve("Desk Mic", inputs: [Self.mac, Self.desk, Self.headset], system: Self.headset).headsetLeftAlone == nil,
                "only the Mac's own microphone is the music-mode choice")
    }

    @Test("no input at all")
    func noInput() {
        let resolution = resolve(nil, inputs: [], system: nil)
        #expect(resolution.using == nil)
        #expect(resolution.automaticLabel == "Automatic")
        #expect(resolution.settingNote == "No microphone found.")
    }

    // MARK: Words

    @Test("the Automatic entry names the microphone it resolves to")
    func automaticLabel() {
        #expect(resolve(nil, inputs: [Self.mac, Self.headset], system: Self.headset).automaticLabel
                == "Automatic · MacBook Pro Microphone")
        #expect(resolve(nil, inputs: [Self.mac], system: Self.mac).automaticLabel == "Automatic · MacBook Pro Microphone")
    }

    @Test("the line under the setting says what Hushy records from, for every resolution")
    func settingNotes() {
        let both = [Self.mac, Self.headset]
        #expect(resolve(nil, inputs: both, system: Self.headset).settingNote
                == "Automatic uses the Mac's microphone when a Bluetooth headset is connected, so the start of what you say is not lost and your music keeps its quality.")
        #expect(resolve(nil, inputs: both, system: Self.mac).settingNote == "Uses the microphone your Mac is set to use.")
        #expect(resolve("Desk Mic", inputs: [Self.mac, Self.desk], system: Self.mac).settingNote == "Always uses this microphone.")
        #expect(resolve("Dana's AirPods Pro", inputs: both, system: Self.mac).settingNote == "Always uses this microphone.")
        #expect(resolve("MacBook Pro Microphone", inputs: [Self.mac], system: Self.mac).settingNote == "Always uses this microphone.")
        #expect(resolve("Desk Mic", inputs: both, system: Self.mac).settingNote
                == "Desk Mic is not connected, so Hushy uses MacBook Pro Microphone.")
    }

    @Test("the Mac's microphone picked with a headset connected: one line with what it buys and what it costs")
    func macMicrophoneNote() {
        #expect(resolve("MacBook Pro Microphone", inputs: [Self.mac, Self.headset], system: Self.headset).settingNote
                == "Dana's AirPods Pro keeps its music quality and noise cancelling. "
                + "Speak up: this microphone is further from you, and room noise gets in.")
    }

    @Test("every line is short enough for two lines under the row, three with the longest name a device can show")
    func settingNotesFit() {
        // A device name is cut at 64 characters for display (`InputDeviceInfo.nameLimit`).
        let long = MicrophoneCandidate(name: String(repeating: "W", count: 80), transport: .bluetooth)
        let both = [Self.mac, Self.headset]
        let ordinary = [
            resolve(nil, inputs: both, system: Self.headset), resolve("Desk Mic", inputs: both, system: Self.mac),
            resolve("Dana's AirPods Pro", inputs: both, system: Self.headset),
            resolve("MacBook Pro Microphone", inputs: both, system: Self.headset),
        ]
        // About 75 characters fit on one line across the row at the Settings window's width.
        for note in ordinary.map(\.settingNote) { #expect(note.count <= 150, "\(note.count): \(note)") }
        let longest = resolve("MacBook Pro Microphone", inputs: [Self.mac, long], system: long).settingNote
        #expect(longest.count <= 225, "\(longest.count)")
    }

    @Test("the words keep the app's voice: no exclamation marks, em dashes, simply or just")
    func voice() {
        let both = [Self.mac, Self.headset]
        let all = [
            resolve(nil, inputs: both, system: Self.headset), resolve("Desk Mic", inputs: both, system: Self.mac),
            resolve("Dana's AirPods Pro", inputs: both, system: Self.headset),
            resolve("MacBook Pro Microphone", inputs: both, system: Self.headset),
        ]
        for note in all.map(\.settingNote) {
            #expect(!note.contains("!") && !note.contains("—"), "\(note)")
            let words = note.lowercased().split { !$0.isLetter }.map(String.init)
            #expect(!words.contains("simply") && !words.contains("just"), "\(note)")
        }
    }

    @Test("a name from a driver is cleaned before it is shown")
    func uncleanNames() {
        let odd = MicrophoneCandidate(name: "Buds\n  Pro\u{7}", transport: .bluetooth)
        let label = resolve(nil, inputs: [odd], system: odd).automaticLabel
        #expect(!label.contains("\n") && !label.contains("\u{7}"))
        let note = resolve("MacBook Pro Microphone", inputs: [Self.mac, odd], system: odd).settingNote
        #expect(!note.contains("\n") && !note.contains("\u{7}"))
    }
}
