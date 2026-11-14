import MurmurCore
import SwiftUI

/// Settings → Privacy: "Learn from my edits", and the way into Memory when this build has it.
/// Rows for the caller to place in a `SettingsGroup`. Takes plain values, so a snapshot can show
/// the wording for a build that keeps the person's changes without the flag being touched.
struct LearningSettingsSection: View {
    @Binding var learnFromEdits: Bool
    /// This build keeps the before-and-after of an edit (`FeatureFlags.personMemory`).
    var keepsChanges = FeatureFlags.personMemory
    /// Snapshots only: another wording to show beside the one in use.
    var detail: String?
    var openMemory: () -> Void = {}

    var body: some View {
        SettingsRow(title: "Learn from my edits", detail: detail ?? LearningCopy.detail(keepsChanges: keepsChanges)) {
            SwitchToggle(isOn: $learnFromEdits)
        }
        if keepsChanges {
            SettingsRow(title: "Memory", detail: LearningCopy.memoryDetail) {
                Button("Open Memory…", action: openMemory).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// What Settings says about learning from edits. The wording for a build that keeps the
/// person's changes is a proposal: the founder approves the words before the flag goes on.
enum LearningCopy {
    static func detail(keepsChanges: Bool) -> String {
        guard keepsChanges else {
            return "When you fix a word right after dictating, Hushy remembers the fix on this Mac. It never reads password fields or code editors."
        }
        return "When you change a dictation right after Hushy types it, Hushy keeps what it wrote and what you changed it to, so it writes more like you next time. That before-and-after stays on this Mac until you delete it. Hushy keeps only the part of your own dictation that you changed, never what else is in the field, and it never reads password fields, password managers or code editors. See and delete what it kept in Memory. The words it learned are also in Voice & style → Dictionary."
    }

    static let memoryDetail = "See and delete the words, writing notes and changes to your dictations that Hushy keeps on this Mac."

    static func deleteDetail(keepsChanges: Bool) -> String {
        keepsChanges
            ? "Removes every word and habit Hushy learned from your edits, and every before-and-after it kept."
            : "Removes every word and habit Hushy learned from your edits."
    }

    static func deleteConfirmation(keepsChanges: Bool) -> String {
        let learned = "Hushy forgets every word and habit it learned from your edits, including ones you told it to forget, so the same fixes can teach it again."
        let kept = keepsChanges ? " Memory loses every word it learned and every before-and-after of your edits; what you typed or changed there yourself stays." : ""
        return learned + kept + " Words you added to the dictionary yourself stay. This can't be undone."
    }
}
