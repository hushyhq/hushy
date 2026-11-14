#if DEBUG
import MurmurCore
import SwiftUI

/// DEBUG-only tools: Voice Lab, the Apple voice-processing override, and the feature flags that
/// gate experimental/deferred functionality (`FeatureFlags`). Compiled out entirely from release
/// builds — see `SettingsPane` and `SettingsView`, which only reference `.developer` under
/// `#if DEBUG` too, so nothing here can leak into a shipping build's UI or binary size.
struct DeveloperSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showVoiceLab = false
    @State private var recordingEncryption = FeatureFlags.recordingEncryption
    @State private var streamingLongDictation = FeatureFlags.streamingLongDictation
    @State private var speakerLabels = FeatureFlags.speakerLabels
    @State private var meetingAppIntegration = FeatureFlags.meetingAppIntegration
    @State private var autoActivateLearnedTerms = FeatureFlags.autoActivateLearnedTerms
    @State private var accounts = FeatureFlags.accounts
    @State private var askActions = FeatureFlags.askActions
    @State private var taskHandoff = FeatureFlags.taskHandoff
    @State private var restyleSelection = FeatureFlags.restyleSelection
    @State private var screenContextSpelling = FeatureFlags.screenContextSpelling
    @State private var personMemory = FeatureFlags.personMemory
    @State private var pasteGlow = FeatureFlags.pasteGlow
    @State private var proDebugUnlocked = Entitlements.debugUnlocked

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup {
                SettingsRow(title: "Apple voice processing", detail: "Hushy manages this for you: off, because it measurably hurt accuracy and whispers. For testing only.") {
                    SwitchToggle(isOn: $settings.reduceBackgroundNoise)
                }
                SettingsRow(title: "Voice Lab", detail: "Record a held-out set of your real dictation for the ground-truth eval.") {
                    Button("Voice Lab →") { showVoiceLab = true }.buttonStyle(SecondaryButtonStyle())
                }
            }

            SettingsGroup(title: "Feature flags") {
                SettingsRow(title: "Person memory", detail: "Local Markdown memory and shadow recall. Off by default.") {
                    SwitchToggle(isOn: $personMemory)
                        .onChange(of: personMemory) { _, value in FeatureFlags.personMemory = value }
                }
                SettingsRow(title: "Paste glow", detail: "A soft outline fades around the field a dictation was pasted into.") {
                    SwitchToggle(isOn: $pasteGlow)
                        .onChange(of: pasteGlow) { _, value in FeatureFlags.pasteGlow = value }
                }
                SettingsRow(title: "On-screen context spelling", detail: "Temporary vocabulary from the focused field and window title.") {
                    SwitchToggle(isOn: $screenContextSpelling)
                        .onChange(of: screenContextSpelling) { _, value in FeatureFlags.screenContextSpelling = value }
                }
                SettingsRow(title: "Accounts", detail: "Optional sign-in. Requires Supabase configuration.") {
                    SwitchToggle(isOn: $accounts)
                        .onChange(of: accounts) { _, value in FeatureFlags.accounts = value }
                }
                SettingsRow(
                    title: "Ask actions",
                    detail: "The answer card (ask your own stuff, ask an AI, summarize this) and act-first with Undo for safe actions. Off: the chord runs only the original Do path with a card for everything."
                ) {
                    SwitchToggle(isOn: $askActions)
                        .onChange(of: askActions) { _, value in FeatureFlags.askActions = value }
                }
                SettingsRow(title: "Restyle selection", detail: "The right-click Services items and the shortcut that rewrite or copy selected text in a tone. On by default; off stops the shortcut at once and the items from doing anything.") {
                    SwitchToggle(isOn: $restyleSelection)
                        .onChange(of: restyleSelection) { _, value in FeatureFlags.restyleSelection = value }
                }
                SettingsRow(title: "Background AI tasks", detail: "Queue confirmed Codex tasks. Off by default.") {
                    SwitchToggle(isOn: $taskHandoff)
                        .onChange(of: taskHandoff) { _, value in FeatureFlags.taskHandoff = value }
                }
                SettingsRow(
                    title: "Recording encryption",
                    detail: "Shows the Security pane's encryption rows. On by default. Only covers audio files, not the database — see .claude/DECISIONS.md."
                ) {
                    SwitchToggle(isOn: $recordingEncryption)
                        .onChange(of: recordingEncryption) { _, value in FeatureFlags.recordingEncryption = value }
                }
                SettingsRow(
                    title: "Streaming long dictation",
                    detail: "Pseudo-streaming transcription for long recordings. On by default (see .claude/DECISIONS.md) — this is a DEBUG-only kill switch for isolating a regression, not a real user setting."
                ) {
                    SwitchToggle(isOn: $streamingLongDictation)
                        .onChange(of: streamingLongDictation) { _, value in FeatureFlags.streamingLongDictation = value }
                }
                SettingsRow(
                    title: "Speaker labels (diarization)",
                    detail: "Runs FluidAudio speaker diarization after a note finishes recording. On by default; turn off to disable speaker labels and speaker-based re-summaries."
                ) {
                    SwitchToggle(isOn: $speakerLabels)
                        .onChange(of: speakerLabels) { _, value in FeatureFlags.speakerLabels = value }
                }
                SettingsRow(
                    title: "Meeting-app recognition",
                    detail: "Names browser calls Google Meet, Teams or Zoom from the window title. On by default."
                ) {
                    SwitchToggle(isOn: $meetingAppIntegration)
                        .onChange(of: meetingAppIntegration) { _, value in FeatureFlags.meetingAppIntegration = value }
                }
                SettingsRow(
                    title: "Auto-activate learned terms",
                    detail: "A term you correct twice in 14 days is used by itself, with an Undo notice. On by default."
                ) {
                    SwitchToggle(isOn: $autoActivateLearnedTerms)
                        .onChange(of: autoActivateLearnedTerms) { _, value in FeatureFlags.autoActivateLearnedTerms = value }
                }
            }

            SettingsGroup(title: "First-run funnel (local only)") {
                SettingsRow(
                    title: "Time to first dictation",
                    detail: funnelHeadline
                ) {
                    Button("Reset") { model.funnel.reset() }.buttonStyle(SecondaryButtonStyle())
                }
                ForEach(settings.onboardingFunnel.rows, id: \.event) { row in
                    SettingsRow(title: row.event.title, detail: Self.detail(for: row)) {
                        Text(row.offsetSeconds.map { "+" + OnboardingFunnel.formatSeconds($0) } ?? "—")
                            .font(Theme.Font.data).foregroundStyle(Theme.textSecondary)
                    }
                }
                SettingsRow(title: "Download pacing", detail: Self.pacingDetail(settings.onboardingFunnel)) { EmptyView() }
                SettingsRow(
                    title: "Replay onboarding",
                    detail: "Clears the completed flag; onboarding shows again at the next launch. Or run the app with MURMUR_DEFAULTS_SUITE=<name> MURMUR_HOME=<tmp> for a fresh-install run."
                ) {
                    Button("Show at next launch") { settings.hasCompletedOnboarding = false }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }

            SettingsGroup(title: "Entitlements (debug)") {
                SettingsRow(
                    title: "Unlock every gated feature",
                    detail: "Debug-only override for Entitlements.has(_:). Every feature is free today, so it changes nothing. Never has any effect in a release build."
                ) {
                    SwitchToggle(isOn: $proDebugUnlocked)
                        .onChange(of: proDebugUnlocked) { _, value in
                            Entitlements.debugUnlocked = value
                            // Keep the out-of-process MCP helper's view of the plan in step.
                            model.refreshEntitlementSnapshot()
                        }
                }
            }
        }
        .sheet(isPresented: $showVoiceLab) { VoiceLabView() }
    }

    /// Gate 11's number: onboarding start → first paste. Never leaves this Mac.
    /// "Speed moderate · pace slow · shown: hotkeyPractice, micCheck · skipped: micCheck".
    private static func pacingDetail(_ funnel: OnboardingFunnel) -> String {
        let speed = funnel.speedBucket?.rawValue ?? "—"
        let pace = funnel.pace?.rawValue ?? "—"
        let shown = funnel.optionalStepsShown.map(\.rawValue).joined(separator: ", ")
        let skipped = funnel.optionalStepsSkipped.map(\.rawValue).joined(separator: ", ")
        return "Speed \(speed) · pace \(pace) · shown: \(shown.isEmpty ? "none" : shown) · skipped: \(skipped.isEmpty ? "none" : skipped)"
    }

    private var funnelHeadline: String {
        let funnel = model.settings.onboardingFunnel
        guard funnel.hasStarted else { return "Not recorded yet — onboarding hasn't run on this install." }
        guard let seconds = funnel.timeToFirstDictation else { return "Onboarding started; no dictation yet." }
        return "\(OnboardingFunnel.formatSeconds(seconds)) from onboarding start to the first pasted dictation (target ≤ 90 s)."
    }

    private static func detail(for row: OnboardingFunnel.Row) -> String {
        guard let timestamp = row.timestamp else { return "Not yet" }
        return timestamp.formatted(date: .abbreviated, time: .standard)
    }
}
#endif
