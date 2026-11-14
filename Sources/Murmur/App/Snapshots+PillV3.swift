import MurmurCore
import SwiftUI

/// Review set for the founder-approved dictation states (design v3, 2026-10-04), one PNG per
/// state and scheme as `pill-v3-<name>-<light|dark>.png`: Listening, Hands-free with its timer,
/// Writing (dots, the word tail or "Writing…", "Still writing…"), Done (short, and a long result with its count)
/// and the action-done chip the pill settles out of.
extension Snapshots {
    static func renderPillV3(scheme: ColorScheme, directory: URL) async {
        let levels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        let chip = DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 1)
        let cases: [(String, PillState, TimeInterval)] = [
            ("listening", .listening, 0),
            ("handsFree", .handsFree(startedAt: Date().addingTimeInterval(-72)), 0),
            ("writing-dots", .processing(), 0),
            ("writing", .processing(), 2),
            ("writing-still", .processing(), 6),
            ("done-short", .done(words: 8), 0),
            ("done-long", .done(words: 142), 0),
            ("done-asHeard", .done(words: 142, asHeard: true), 0),
            ("action-done", .actionDone(chip), 0),
        ]
        for (name, state, writingElapsed) in cases {
            let pill = PillModel()
            pill.state = state
            pill.showWhenIdle = true
            pill.setLevels(levels)
            let view = PillView(model: pill)
                .environment(\.snapshotWritingElapsed, writingElapsed)
                .padding(40)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: "pill-v3-\(name)", scheme: scheme,
                          size: CGSize(width: 480, height: 160), directory: directory, fixedSize: true)
        }
        await renderPillIdle(scheme: scheme, directory: directory)
    }

    /// The resting pill (design v3 "Idle": five grey marks, 40×10), close up at each anchor as
    /// `pill-v3-idle-<anchor>-<light|dark>.png`. The pill is always the same view whatever came
    /// before, so this is also the end frame of the action-done → idle settle.
    static func renderPillIdle(scheme: ColorScheme, directory: URL) async {
        for anchor in PillAnchor.allCases {
            let pill = PillModel()
            pill.state = .idle
            pill.showWhenIdle = true
            pill.anchor = anchor
            let view = PillView(model: pill)
                .frame(width: 120, height: 120)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: "pill-v3-idle-\(anchor.rawValue)", scheme: scheme,
                          size: CGSize(width: 120, height: 120), directory: directory, fixedSize: true)
        }
    }
}
