import Foundation
import MurmurCore
import Observation

/// Writes the local-only first-run funnel (`OnboardingFunnel`, gate 11) into `AppSettings` as
/// the events happen: onboarding shown, each permission granted, the speech model ready, the
/// first dictation that produced text, and onboarding completed. Observation-driven for the
/// model and permissions (so the first grant is caught whichever screen the user is on), and
/// callback-driven for dictation (`DictationController.onDictationSucceeded`).
///
/// Nothing here touches the network; the numbers are read back by the DEBUG Developer pane and,
/// as step counts only, by `UsageMetricsRecorder` (which sends nothing unless sharing is on). See `.claude/DECISIONS.md` (gate 11).
@MainActor
final class OnboardingFunnelRecorder {
    private let settings: AppSettings
    private let modelStatus: SpeechModelStatus
    private let permissions: Permissions
    /// Usage numbers: called once for each setup step the first time it is reached (never for the
    /// speed bucket, pace or optional steps). Set by `AppModel`; the recorder behind it records
    /// nothing unless sharing is on.
    var onStepReached: ((OnboardingFunnel.Event, Date) -> Void)?

    init(settings: AppSettings, modelStatus: SpeechModelStatus, permissions: Permissions) {
        self.settings = settings
        self.modelStatus = modelStatus
        self.permissions = permissions
    }

    /// Begins observing. Safe to call on every launch: events already recorded stay as they
    /// were, and nothing is recorded until `markOnboardingStarted()` has run once.
    func start() {
        trackModel()
        trackPermissions()
        // A returning user may already have everything granted before observation starts.
        recordCurrentState()
    }

    func markOnboardingStarted() {
        mark(.onboardingStarted)
        recordCurrentState()
    }

    func markFirstDictation() { mark(.firstDictation) }

    func markOnboardingCompleted() { mark(.onboardingCompleted) }

    /// The first measured throughput bucket of the speech-model download (or `.offline`).
    func recordSpeed(_ bucket: SpeedBucket) {
        pendingSpeed = pendingSpeed ?? bucket
        update { $0.recordingSpeed(bucket) }
    }

    /// The pace behind the plan made on leaving the last permission step.
    func recordPace(_ pace: OnboardingPace) { update { $0.recordingPace(pace) } }

    /// An optional "while it downloads" step was shown (and maybe skipped).
    func recordOptionalStep(_ step: OnboardingStep, skipped: Bool) {
        update { $0.recordingOptionalStep(step, skipped: skipped) }
    }

    /// The speed is usually measured seconds before the onboarding window starts the funnel
    /// clock; it's held here and recorded once the funnel has started.
    private var pendingSpeed: SpeedBucket?

    private func update(_ change: (OnboardingFunnel) -> OnboardingFunnel) {
        let updated = change(settings.onboardingFunnel)
        if updated != settings.onboardingFunnel { settings.onboardingFunnel = updated }
    }

    /// Developer pane: forget the recorded funnel so the next onboarding run measures afresh.
    func reset() {
        settings.onboardingFunnel = .empty
    }

    private func mark(_ event: OnboardingFunnel.Event, at date: Date = Date()) {
        let updated = settings.onboardingFunnel.marking(event, at: date)
        guard updated != settings.onboardingFunnel else { return }
        let isNewStep = settings.onboardingFunnel[event] == nil
        settings.onboardingFunnel = updated
        if isNewStep { onStepReached?(event, date) }
    }

    private func recordCurrentState() {
        if let startedAt = modelStatus.downloadStartedAt { mark(.speechDownloadStarted, at: startedAt) }
        if let finishedAt = modelStatus.downloadFinishedAt { mark(.speechDownloadFinished, at: finishedAt) }
        if let pendingSpeed { update { $0.recordingSpeed(pendingSpeed) } }
        if let readyAt = modelStatus.readyAt { mark(.modelReady, at: readyAt) }
        if permissions.microphone == .granted { mark(.microphoneGranted) }
        if permissions.accessibility == .granted { mark(.accessibilityGranted) }
    }

    /// Same self-rearming `withObservationTracking` pattern as `SettingsSync.track()`.
    private func trackModel() {
        withObservationTracking {
            _ = (modelStatus.readyAt, modelStatus.downloadStartedAt, modelStatus.downloadFinishedAt)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let startedAt = self.modelStatus.downloadStartedAt { self.mark(.speechDownloadStarted, at: startedAt) }
                if let finishedAt = self.modelStatus.downloadFinishedAt { self.mark(.speechDownloadFinished, at: finishedAt) }
                if let readyAt = self.modelStatus.readyAt { self.mark(.modelReady, at: readyAt) }
                self.trackModel()
            }
        }
    }

    private func trackPermissions() {
        withObservationTracking {
            _ = (permissions.microphone, permissions.accessibility)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.permissions.microphone == .granted { self.mark(.microphoneGranted) }
                if self.permissions.accessibility == .granted { self.mark(.accessibilityGranted) }
                self.trackPermissions()
            }
        }
    }
}
