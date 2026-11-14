import MurmurCore
import SwiftUI

/// Task 119's review set (`t119-*`, light and dark): the pill while a voice action listens (hands-free
/// with its cancelling key, and the held chord), the stop notice, the Settings row, the same row
/// when macOS Dictation listens for the same key, and the voice-action practice Settings opens.
/// `HUSHY_SNAPSHOT_ONLY=t119-` renders just these.
extension Snapshots {
    static func renderActionTrigger(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        let states: [(String, PillState, String?)] = [
            ("listening-handsfree", .actionListening, "control"),
            ("listening-handsfree-option", .actionListening, "option"),
            ("listening-held", .actionListening, nil),
            ("stopped", .error("Stopped listening"), nil),
        ]
        for (name, state, key) in states {
            let pill = PillModel()
            pill.state = state
            pill.actionCancelKey = key
            pill.actionChordHeld = name == "listening-held"
            await capture(
                PillView(model: pill).padding(40).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "t119-\(name)", scheme: scheme, size: CGSize(width: 560, height: 160), directory: directory, fixedSize: true)
        }

        let saved = model.settings.actionTrigger
        for (name, key, clash) in [("default", ActionTriggerKey.control, false), ("clash", .control, true), ("option", .option, false)] {
            model.settings.actionTrigger = key
            let page = SettingsSnapshotPage(
                pane: .voiceActions, needsAttentionBadge: false,
                retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
            await capture(
                page.environment(model).environment(\.snapshotPlan, .founding).environment(\.snapshotActionTriggerClash, clash),
                name: "t119-settings-\(name)", scheme: scheme, size: CGSize(width: 780, height: 560), directory: directory)
        }
        // The Menu picker cannot be drawn by ImageRenderer, so the open list is drawn from the same
        // `ActionTriggerKey.choices` over the real page, under the row's control.
        model.settings.actionTrigger = .control
        let openPage = SettingsSnapshotPage(
            pane: .voiceActions, needsAttentionBadge: false,
            retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
        await capture(
            openPage.environment(model).environment(\.snapshotPlan, .founding)
                .environment(\.snapshotActionTriggerClash, false)
                .overlay(alignment: .topTrailing) { ChoicesOpenList(selected: .control, dictation: model.settings.triggerKey) },
            name: "t119-settings-choices-open", scheme: scheme, size: CGSize(width: 780, height: 560), directory: directory)
        model.settings.actionTrigger = saved

        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .granted)
        model.modelStatus.pinForSnapshot(.ready)
        model.downloads.pinForSnapshot()
        await capture(
            VoiceActionRehearsalView.snapshotSheet(model: model, phase: .waiting),
            name: "t119-settings-practice", scheme: scheme,
            size: CGSize(width: VoiceActionRehearsalView.sheetWidth, height: 560), directory: directory)
    }
}

/// A drawn stand-in for the open Action key pop-up: every option the person can pick, the current
/// one ticked. Snapshot-only; the real control is the Picker in `VoiceActionsSettingsPane`.
private struct ChoicesOpenList: View {
    var selected: ActionTriggerKey
    var dictation: TriggerKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ActionTriggerKey.choices(dictation: dictation)) { key in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .opacity(key == selected ? 1 : 0)
                    Text(key.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.body)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(key == selected ? Theme.textTertiary.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(6)
        .frame(width: 210)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.trailing, 40).padding(.top, 133)
    }
}
