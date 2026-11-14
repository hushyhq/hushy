import MurmurCore
import SwiftUI

/// Settings → General → Microphone in each state the setting can be in
/// (`settings-microphone-*`), driven by fixed device lists with invented names: no still asks the
/// Mac about its devices. `HUSHY_SNAPSHOT_ONLY=settings-microphone` renders just these, and
/// onboarding's microphone check in its "no audio" state, which carries the same picker.
extension Snapshots {
    static func renderMicrophoneSetting(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let mac = AudioCapture.InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn)
        let headset = AudioCapture.InputDevice(id: 2, name: "Dana's AirPods Pro", transport: .bluetooth)
        let desk = AudioCapture.InputDevice(id: 3, name: "Desk Mic", transport: .usb)
        typealias Devices = MicrophoneSelector.Devices
        let states: [(name: String, picked: String?, devices: Devices)] = [
            // Automatic follows the Mac's input: a connected headset's microphone is the one used.
            ("auto-headset", nil, Devices(inputs: [mac, headset], systemDefault: headset)),
            ("auto-system", nil, Devices(inputs: [mac, desk], systemDefault: mac)),
            // The Mac's microphone picked with a headset connected: what that buys and costs.
            ("picked-mac-with-headset", mac.name, Devices(inputs: [mac, headset], systemDefault: headset)),
            ("picked-headset", headset.name, Devices(inputs: [mac, headset], systemDefault: mac)),
            ("picked", desk.name, Devices(inputs: [mac, desk], systemDefault: mac)),
            ("picked-missing", headset.name, Devices(inputs: [mac], systemDefault: mac)),
        ]
        // Onboarding's microphone check when it hears nothing: the same picker, the same label.
        let check = MicCheck(isSnapshot: true, silentSnapshot: Devices(inputs: [mac, headset], systemDefault: headset))
            .environment(model)
        await capture(
            check.padding(24).frame(width: 480, alignment: .leading).background(Theme.bgBase),
            name: "settings-microphone-onboarding-check", scheme: scheme,
            size: CGSize(width: 480, height: 220), directory: directory, fixedSize: true)
        for state in states {
            let row = SettingsGroup {
                MicrophoneSettingRow(
                    selection: .constant(state.picked),
                    state: MicrophoneSettingState(picked: state.picked, devices: state.devices))
            }
            // As wide as the General pane's own groups in the Settings window, so the wrapping is real.
            await capture(
                row.padding(24).frame(width: 544).background(Theme.bgBase),
                name: "settings-microphone-\(state.name)", scheme: scheme,
                size: CGSize(width: 544, height: 190), directory: directory, fixedSize: true)
        }
    }
}
