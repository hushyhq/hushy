import Foundation
import MurmurCore
import Observation
import os

/// Wires "Ask to record when a call starts" end to end: polls `CallDetector` for which meeting
/// app (if any) is using the microphone, feeds that into the pure `CallDetectionState` machine,
/// and applies its `Effect`s to the pill banner and `NoteRecorder`. Also owns the "Maximum
/// length" timer for every note recording, call-detected or manual, since both need the same
/// "warn 2 minutes before, then stop" behavior.
///
/// Everything that decides *when* to prompt/stop lives in `CallDetectionState` (pure, unit
/// tested); this type is the thin, untestable glue around it — one polling `Timer`, reading
/// settings, and calling into `NoteRecorder`/`PillModel`.
@MainActor
final class CallDetectionCoordinator {
    private let settings: AppSettings
    private let recorder: NoteRecorder
    private let pill: PillModel
    private let startRecording: (MeetingApp?) async -> Void
    private var state = CallDetectionState()
    private var pollTimer: Timer?
    private var maxLengthWarningShown = false
    private let log = Logger(subsystem: "app.hushy", category: "call-detection")
    /// How often to poll Core Audio for mic-in-use — frequent enough that a 20 s prompt and a
    /// 5 s countdown both feel responsive, cheap enough (a handful of property reads) to run
    /// constantly in the background.
    private static let pollInterval: TimeInterval = 1

    init(
        settings: AppSettings, recorder: NoteRecorder, pill: PillModel,
        startRecording: @escaping (MeetingApp?) async -> Void
    ) {
        self.settings = settings
        self.recorder = recorder
        self.pill = pill
        self.startRecording = startRecording
        state = CallDetectionState(neverList: settings.neverAskForApps)
    }

    func start() {
        guard CallDetector.isSupported else { return }
        wireBannerCallbacks()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func wireBannerCallbacks() {
        pill.onBannerRecord = { [weak self] app in
            guard let self else { return }
            guard let accepted = self.state.acceptPrompt(), accepted == app else { return }
            self.pill.banner = nil
            Task { await self.startRecording(app) }
        }
        pill.onBannerDismiss = { [weak self] in
            guard let self else { return }
            self.state.dismissPrompt()
            self.pill.banner = nil
        }
        pill.onBannerNever = { [weak self] app in
            guard let self else { return }
            self.state.addToNeverList(app)
            self.settings.neverAskForApps.insert(app)
            self.pill.banner = nil
        }
        pill.onBannerCancelCountdown = { [weak self] in
            guard let self else { return }
            self.state.cancelStopCountdown()
            self.pill.banner = nil
        }
    }

    private func poll() {
        let now = Date()
        checkMaxLength(now: now)

        guard settings.askToRecordCalls else {
            // Detection is off: still let an in-progress call-detected note run its max-length
            // check above, but never show a new prompt or auto-stop countdown.
            return
        }
        let detectedApp = CallDetector.pollActiveMeetingApp()
        let effect = state.observeMicActivity(app: detectedApp, isRecording: recorder.isRecording, now: now)
        apply(effect, now: now)

        // A prompt or countdown can also expire purely from time passing with no change in mic
        // activity (e.g. the same app keeps using the mic, so `observeMicActivity` returns
        // `.none`, but the 20 s prompt window has elapsed) — `tick` catches that.
        if effect == .none {
            apply(state.tick(now: now), now: now)
        }
    }

    private func apply(_ effect: CallDetectionState.Effect, now: Date) {
        switch effect {
        case .none:
            break
        case .showPrompt(let app):
            let expiresAt = now.addingTimeInterval(CallDetectionState.promptDuration)
            pill.banner = .callDetected(app: app, expiresAt: expiresAt)
        case .dismissPrompt:
            switch pill.banner {
            case .callDetected: pill.banner = nil
            default: break
            }
        case .startStopCountdown:
            pill.banner = .stopCountdown(fireAt: now.addingTimeInterval(CallDetectionState.stopCountdownDuration))
        case .cancelStopCountdown:
            if case .stopCountdown = pill.banner { pill.banner = nil }
        case .stopRecording:
            pill.banner = nil
            if recorder.isRecording {
                log.notice("call ended; auto-stopping note")
                recorder.stop()
            }
        case .showMaxLengthWarning, .stopForMaxLength:
            // Handled in `checkMaxLength`, which computes these itself from elapsed duration
            // rather than routing through `CallDetectionState` (a manually-started note has no
            // `CallDetectionState` involvement at all, but is still subject to max length).
            break
        }
    }

    /// Enforces "Maximum length" for *any* recording note, call-detected or manual — the task's
    /// contract doesn't scope this to call-detected notes only. Runs on every poll tick
    /// regardless of `askToRecordCalls`, since it's a safety cap, not part of the ask-to-record
    /// flow.
    private func checkMaxLength(now: Date) {
        guard recorder.isRecording, let startedAt = recorder.activeNote?.createdAt else {
            maxLengthWarningShown = false
            return
        }
        let elapsed = now.timeIntervalSince(startedAt)
        switch settings.maxRecordingLength.effect(elapsedSeconds: elapsed, warningAlreadyShown: maxLengthWarningShown) {
        case .showMaxLengthWarning:
            maxLengthWarningShown = true
            pill.banner = .maxLengthWarning
        case .stopForMaxLength:
            log.notice("maximum recording length reached; stopping note")
            if case .maxLengthWarning = pill.banner { pill.banner = nil }
            recorder.stop()
            maxLengthWarningShown = false
        default:
            break
        }
    }
}
