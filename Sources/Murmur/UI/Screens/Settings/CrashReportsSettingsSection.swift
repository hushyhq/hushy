import SwiftUI

/// The switch and its sentence are the whole disclosure, as with usage numbers. The disclosure is
/// versioned: changing its wording raises `currentCrashConsentVersion`, which turns sharing off until
/// the person turns it on again under the new words.
/// One row; the caller places it in a `SettingsGroup`.
struct CrashReportsSettingsSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsRow(title: "Share crash reports", detail: Self.explanation, showsDivider: false) {
            SwitchToggle(isOn: Binding(
                get: { settings.shareCrashReports },
                set: { on in
                    if on { settings.crashConsentVersion = AppSettings.currentCrashConsentVersion }
                    settings.shareCrashReports = on
                }))
            .accessibilityLabel("Share crash reports")
        }
    }

    static let explanation = "Crash details: where in Hushy's code it stopped, the app and macOS version and your Mac's chip. Never your words, audio or apps."
}
