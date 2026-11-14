import AppKit
import MurmurCore
import SwiftUI

/// What the Microphone setting shows: the inputs to pick from, what "Automatic" resolves to right
/// now, and the line saying what Hushy records from and why. Plain values worked out from one
/// read of the Mac's devices, so the row draws the same in the app, in a still and in a test.
struct MicrophoneSettingState: Equatable {
    /// The picker's entries after Automatic: every input by name, then a picked device that is
    /// not connected, so the selection always has an entry.
    var entries: [Entry]
    /// What Automatic would open now: the label of the first entry.
    var automatic: MicrophoneResolution
    /// What the current selection opens: the line under the setting.
    var current: MicrophoneResolution

    struct Entry: Equatable, Identifiable {
        var name: String
        var label: String
        var id: String { name }
    }

    @MainActor
    init(picked: String?, devices: MicrophoneSelector.Devices) {
        let inventory = devices.inventory
        let oldRule = UserDefaults.standard.bool(forKey: MicrophoneSelector.legacyAutomaticKey)
        automatic = MicrophoneResolution.resolve(picked: nil, inventory: inventory, followsSystemInput: oldRule)
        current = picked == nil ? automatic : MicrophoneResolution.resolve(picked: picked, inventory: inventory,
                                                                          followsSystemInput: oldRule)
        var entries = devices.inputs.map { Entry(name: $0.name, label: $0.name) }
        if let missing = current.missing { entries.append(Entry(name: missing, label: "\(missing) (not connected)")) }
        self.entries = entries
    }

    /// The Automatic entry: "Automatic · MacBook Pro Microphone".
    var automaticLabel: String { automatic.automaticLabel }
    /// The line under the setting.
    var note: String { current.settingNote }
}

/// Settings → General → Microphone: a picker with Automatic first, and a line saying which
/// microphone Hushy records from now and why. The same components as every other settings row;
/// the line runs under the whole row, because beside this wide picker it wrapped to six lines.
struct MicrophoneSettingRow: View {
    @Binding var selection: String?
    let state: MicrophoneSettingState

    var body: some View {
        SettingsRow(title: "Microphone", detail: state.note, detailBelow: true) {
            Picker("", selection: $selection) {
                Text(state.automaticLabel).tag(String?.none)
                ForEach(state.entries) { Text($0.label).tag(Optional($0.name)) }
            }
            // The menu button is as wide as its longest entry; keep its right edge on the row's.
            .labelsHidden().frame(width: Self.pickerWidth, alignment: .trailing)
        }
    }

    /// Wide enough for "Automatic · MacBook Pro Microphone" without cutting it.
    static let pickerWidth: CGFloat = 270
}

extension MicrophoneSelector.Devices {
    /// The devices a still is drawn with, so no still depends on the Mac that rendered it: a
    /// laptop on its own microphone.
    static let snapshot = MicrophoneSelector.Devices(
        inputs: [AudioCapture.InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn)],
        systemDefault: AudioCapture.InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn))
}
