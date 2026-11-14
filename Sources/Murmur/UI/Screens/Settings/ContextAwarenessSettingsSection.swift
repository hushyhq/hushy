import MurmurCore
import SwiftUI

/// "Use on-screen context for spelling" toggle for Settings → Privacy: one row, for the caller to
/// place in a `SettingsGroup`. Self-contained (owns no state beyond the binding it's given) — it
/// only needs a binding to `AppSettings.contextAwarenessEnabled`.
///
/// See `ContextExtractor`/`ContextSpellingFixer` (MurmurCore) for what actually runs when this
/// is on, and `.claude/DECISIONS.md`'s context-awareness entry for the privacy design: the
/// surrounding text is read once per dictation via the Accessibility API, used only to build
/// temporary boost terms and fix near-miss spellings for that single dictation, and discarded
/// immediately after — never logged, never written to disk, never sent anywhere.
struct ContextAwarenessSettingsSection: View {
    @Binding var isEnabled: Bool

    var body: some View {
        SettingsRow(
            title: "Use on-screen context for spelling",
            detail: "Hushy reads the text on screen, on your Mac, to get names right. It is never saved or sent, and password fields are skipped."
        ) {
            SwitchToggle(isOn: $isEnabled)
        }
    }
}
