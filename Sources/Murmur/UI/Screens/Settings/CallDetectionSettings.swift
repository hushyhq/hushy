import MurmurCore
import SwiftUI

/// "Ask to record when a call starts" + "Maximum length," self-contained so it can be dropped
/// into the Notes/Meetings settings pane as one row group without that pane knowing anything
/// about `CallDetectionState`, `MeetingApp`, or the never-list's storage. See `.claude/DECISIONS.md`
/// for the privacy rationale (why detection never reads window titles/screen content).
struct CallDetectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(title: "Call detection") {
            SettingsRow(
                title: "Ask to record when a call starts",
                detail: detectionDetail
            ) {
                SwitchToggle(isOn: $settings.askToRecordCalls)
                    .disabled(!CallDetector.isSupported)
            }
            SettingsRow(title: "Maximum length", detail: "Recording stops automatically, with a 2-minute warning first.") {
                Picker("", selection: $settings.maxRecordingLength) {
                    ForEach(MaxRecordingLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            if !settings.neverAskForApps.isEmpty {
                neverListRow
            }
        }
    }

    private var detectionDetail: String {
        guard CallDetector.isSupported else {
            return "Needs macOS 14.4 or later."
        }
        return "Detects Zoom, Teams, Webex, FaceTime, Slack huddles, Discord, and browser meetings from microphone use — never from window titles or screen content."
    }

    /// Lets a "Never for <App>" choice be undone without leaving Settings — otherwise it's a
    /// one-way door hidden behind a prompt the user may not see again for weeks.
    private var neverListRow: some View {
        SettingsRow(
            title: "Never ask for",
            detail: ListFormatter.localizedString(byJoining: model.settings.neverAskForApps.map(\.displayName).sorted())
        ) {
            Menu("Edit") {
                ForEach(Array(model.settings.neverAskForApps).sorted(by: { $0.displayName < $1.displayName })) { app in
                    Button("Allow \(app.displayName) again") {
                        model.settings.neverAskForApps.remove(app)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

extension MeetingApp: Identifiable {
    public var id: String { rawValue }
}
