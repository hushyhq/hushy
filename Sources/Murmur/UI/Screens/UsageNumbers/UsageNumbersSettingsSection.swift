import MurmurCore
import SwiftUI

/// "Share usage numbers" for Settings → Privacy & security: one switch, one plain sentence, and
/// "See what's sent". Off until the person turns it on; turning it off again stops recording at
/// once and deletes whatever is waiting on this Mac (`UsageMetricsRecorder.switchChanged`).
struct UsageNumbersSettingsSection: View {
    @Binding var isOn: Bool
    /// The setting could not be saved, so usage numbers are paused until it can be (fail closed).
    var isPausedByStorageFault = false
    @State private var showDisclosure = false

    var body: some View {
        SettingsRow(
            title: "Share usage numbers",
            detail: isPausedByStorageFault
                ? "Paused: this Mac could not save the setting. Nothing is recorded or sent."
                : "Counts and timings, never your words.",
            detailLink: SettingsRowLink(title: "See what's sent") { showDisclosure = true }) {
            SwitchToggle(isOn: $isOn)
        }
        .sheet(isPresented: $showDisclosure) { UsageNumbersSheet() }
    }
}

/// The same switch on the welcome screen, one line: off, so nothing is recorded unless it is turned on here.
struct UsageNumbersOnboardingRow: View {
    @Binding var isOn: Bool
    @Binding var showDisclosure: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share usage numbers").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text("Turn it on to help improve Hushy. Counts and timings, never your words. Change it any time in Settings.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            LinkLikeButton(title: "See what's sent") { showDisclosure = true }
            SwitchToggle(isOn: $isOn)
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .frame(maxWidth: 520)
    }
}

/// Home's one-time notice for an install that finished setup before usage numbers existed. It
/// asks; the switch starts off, and nothing is recorded for that install unless it is turned on.
struct UsageNumbersNotice: View {
    /// The same setting the Settings switch edits, so the two can never disagree.
    @Binding var isOn: Bool
    var onSeeWhatsSent: () -> Void = {}
    var onOK: () -> Void = {}

    var body: some View {
        Card(padding: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share usage numbers with Hushy?").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Optional. Counts and timings, never your words.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: Theme.Space.s) {
                    Text("Share usage numbers").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    SwitchToggle(isOn: $isOn).accessibilityLabel("Share usage numbers")
                }
                HStack(spacing: Theme.Space.s) {
                    Button("See what's sent", action: onSeeWhatsSent).buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: Theme.Space.m)
                    Button("OK", action: onOK).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// "Send a daily count" for Settings → Privacy & security: a switch of its own, on by default, with the
/// same "See what's sent" link. Turning it off stops the count at once (`DailyCountSender`).
struct DailyCountSettingsSection: View {
    @Binding var isOn: Bool
    @State private var showDisclosure = false

    var body: some View {
        SettingsRow(
            title: DailyCountDisclosure.switchTitle, detail: DailyCountDisclosure.switchDetail,
            detailLink: SettingsRowLink(title: "See what's sent") { showDisclosure = true }) {
            SwitchToggle(isOn: $isOn)
        }
        .sheet(isPresented: $showDisclosure) { UsageNumbersSheet() }
    }
}
