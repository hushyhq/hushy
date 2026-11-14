import Foundation

// Per-event facts. Each one is a closed vocabulary plus clamped numbers: there is no String
// property anywhere in this file, so no transcript, field text, app name, bundle ID, window
// title, URL, path, learned word or custom-mode name can be carried by construction.
// Events are in-memory inputs to `DailyMetricsBuilder`; only the daily aggregate is ever encoded.

/// Which preset shaped a dictation. Never a custom mode's name.
public enum MetricsModeKind: String, MetricsKey {
    case none
    /// The stock Default mode (raw value "default").
    case standard = "default"
    case email, message, note, bulletPoints
    case custom

    public static func kind(modeID: UUID?, isBuiltIn: Bool) -> MetricsModeKind {
        guard let modeID else { return .none }
        guard isBuiltIn else { return .custom }
        if modeID == Mode.BuiltInID.default { return .standard }
        if modeID == Mode.BuiltInID.email { return .email }
        if modeID == Mode.BuiltInID.message { return .message }
        if modeID == Mode.BuiltInID.note { return .note }
        if modeID == Mode.BuiltInID.bulletPoints { return .bulletPoints }
        return .custom
    }

    public static func kind(of mode: Mode?) -> MetricsModeKind {
        kind(modeID: mode?.id, isBuiltIn: mode?.isBuiltIn ?? false)
    }
}

/// The tone a dictation actually ran with. Never an app name, a custom mode's name or any text.
///
/// This is what ran, not the setting alone: the person's default tone, the tone for the kind of app,
/// an app's own choice, a mode that skips cleanup and an AI app that is written as a prompt all
/// decide it. `prompt` counts only when the prompt register line was really sent to the model; an AI
/// app on a model that is not sent register lines runs with its place's tone and counts as that tone.
public enum MetricsTone: String, MetricsKey {
    case refined, professional, casual, prompt
    /// Cleanup skipped: the person's setting, or a mode that is verbatim.
    case asSpoken

    /// - Parameters:
    ///   - registerSent: the model was sent register lines (`SmartCleaner.sendsRegisterLines`).
    public static func applied(
        by tones: ToneSettings, mode: Mode, category: AppCategory, bundleID: String?, registerSent: Bool
    ) -> MetricsTone {
        if mode.cleanupLevel == .verbatim { return .asSpoken }
        if registerSent, let register = tones.register(for: category, bundleID: bundleID) {
            switch register {
            case .prompt: return .prompt
            case .casual: return .casual
            case .professional: return .professional
            }
        }
        switch tones.plan(for: category, bundleID: bundleID).tone {
        case .casual: return .casual
        case .professional: return .professional
        case .refined, nil: return .refined
        }
    }
}

/// Whether the model that shaped the text was already loaded. Absent for rules-only output.
public enum MetricsModelState: String, MetricsKey {
    case cold, warm

    /// Whether the cleanup model had already answered a call recently enough to still be loaded.
    /// Nil when no model call was made for this dictation. `answeredAt` are the times earlier
    /// answered calls finished (the backend's own call log, cleared when the backend is switched);
    /// `idleUnloadSeconds` is how long the backend keeps the model resident (nil: session-long).
    public static func infer(
        outcome: ModelOutcome?, answeredAt: [Date], callStartedAt: Date, idleUnloadSeconds: TimeInterval?
    ) -> MetricsModelState? {
        guard let outcome, outcome.askedTheModel else { return nil }
        let warm = answeredAt.contains { answered in
            answered < callStartedAt && (idleUnloadSeconds.map { callStartedAt.timeIntervalSince(answered) <= $0 } ?? true)
        }
        return warm ? .warm : .cold
    }
}

extension ModelOutcome {
    /// A call to the model was actually made (as opposed to skipped, unavailable or never asked).
    var askedTheModel: Bool {
        switch self {
        case .used, .rejectedByGuard, .timeout, .modelError, .refused, .modelBusy: true
        case .notAsked, .skippedSlow, .breakerOpen, .releaseWindow, .prewarmLate, .unavailable, .thermalSerious,
             .notResponding: false
        }
    }
}

/// One finished dictation.
public struct DictationMetricEvent: Sendable, Equatable, Codable {
    /// Delivery outcome, cleanup profile, fallback reason, edit observation and coverage, and
    /// release-to-delivery milliseconds, already validated by `DictationFeedback`.
    public let feedback: DictationFeedback
    public let cleanupLevel: CleanupLevel
    public let modeKind: MetricsModeKind
    public let wordCount: Int
    /// Length of the captured audio (key down to key up, as recorded), in milliseconds.
    public let audioMilliseconds: Int
    /// Key release to the recognizer's final text. Nil when recognition never finished.
    public let speechMilliseconds: Int?
    /// Time spent in the cleanup stage. Nil when cleanup was not attempted.
    public let cleanupMilliseconds: Int?
    public let modelState: MetricsModelState?
    /// The tone it ran with; nil when cleanup never ran (a dictation that failed or was cancelled early)
    /// and for events recorded before tones were counted.
    public let tone: MetricsTone?
    /// The kind of app it was pasted into (never its name); nil for events recorded before this was counted.
    public let appKind: MetricsAppKind?
    /// How many words the person changed, set only when the edit watcher found the dictation edited and
    /// measured it. Nil for every other verdict, and for an edit whose size was not measured.
    public let editSize: MetricsEditSize?

    public init(
        feedback: DictationFeedback, cleanupLevel: CleanupLevel, modeKind: MetricsModeKind, wordCount: Int,
        audioMilliseconds: Int, speechMilliseconds: Int?, cleanupMilliseconds: Int?, modelState: MetricsModelState?,
        tone: MetricsTone? = nil, appKind: MetricsAppKind? = nil, editSize: MetricsEditSize? = nil
    ) {
        self.tone = tone
        self.appKind = appKind
        self.editSize = feedback.editObservation == .edited && editSize != MetricsEditSize.none ? editSize : nil
        self.feedback = feedback
        self.cleanupLevel = cleanupLevel
        self.modeKind = modeKind
        self.wordCount = MetricsMath.clamp(wordCount, to: 0...MetricsHistogramSpec.words.maximumValue)
        self.audioMilliseconds = MetricsMath.clamp(audioMilliseconds, to: 0...MetricsHistogramSpec.audioMilliseconds.maximumValue)
        self.speechMilliseconds = speechMilliseconds.map { MetricsMath.clamp($0, to: 0...MetricsHistogramSpec.speechMilliseconds.maximumValue) }
        self.cleanupMilliseconds = cleanupMilliseconds.map { MetricsMath.clamp($0, to: 0...MetricsHistogramSpec.cleanupMilliseconds.maximumValue) }
        self.modelState = modelState
    }

    public var releaseToDeliveryMilliseconds: Int? { feedback.releaseToDeliveryMilliseconds }

    /// The same dictation with the edit watcher's verdict; nil if the verdict contradicts the delivery.
    public func withEdit(
        observation: DictationFeedback.EditObservation, coverage: DictationFeedback.EditCoverage,
        size: MetricsEditSize? = nil
    ) -> DictationMetricEvent? {
        guard let updated = try? DictationFeedback(
            delivery: feedback.delivery, cleanupModelProfile: feedback.cleanupModelProfile,
            fallbackReason: feedback.fallbackReason, editObservation: observation, editCoverage: coverage,
            releaseToDeliveryMilliseconds: feedback.releaseToDeliveryMilliseconds) else { return nil }
        return DictationMetricEvent(
            feedback: updated, cleanupLevel: cleanupLevel, modeKind: modeKind, wordCount: wordCount,
            audioMilliseconds: audioMilliseconds, speechMilliseconds: speechMilliseconds,
            cleanupMilliseconds: cleanupMilliseconds, modelState: modelState, tone: tone, appKind: appKind, editSize: size)
    }
}

public enum VoiceActionOutcome: String, MetricsKey { case succeeded, failed, cancelled }

/// Why a voice action failed. A fixed list; never the error's message, which can contain a
/// calendar title, an app name or a shortcut name.
public enum VoiceActionFailureCategory: String, MetricsKey {
    case permissionDenied, notFound, ambiguousTarget, backendFailed, needsInput
    case modelUnavailable, timedOut, other

    public init(_ error: ActionExecutionError) {
        switch error {
        case .permissionDenied: self = .permissionDenied
        case .notFound, .targetNotFound: self = .notFound
        case .closestApps: self = .ambiguousTarget
        case .backendFailed, .saveFailed: self = .backendFailed
        // A Shortcut that may have run is not counted as a success: failed, by why it is unsure.
        case .mayHaveRun(let reason): self = reason == .timedOut ? .timedOut : .backendFailed
        case .needsInput, .missingStart: self = .needsInput
        }
    }
}

/// One voice action that reached a terminal state. "Attempted" is the sum of the three outcomes.
public struct VoiceActionMetricEvent: Sendable, Equatable, Codable {
    public let outcome: VoiceActionOutcome
    /// Present only when `outcome == .failed` (a failed action without a category becomes `.other`).
    public let failure: VoiceActionFailureCategory?

    public init(outcome: VoiceActionOutcome, failure: VoiceActionFailureCategory?) {
        self.outcome = outcome
        self.failure = outcome == .failed ? (failure ?? .other) : nil
    }
}

public enum MeetingOutcome: String, MetricsKey { case started, completed, discarded }

public struct MeetingMetricEvent: Sendable, Equatable, Codable {
    public let outcome: MeetingOutcome
    /// Whole minutes recorded; only for a meeting that ended (completed or discarded).
    public let minutesRecorded: Int?

    public init(outcome: MeetingOutcome, minutesRecorded: Int?) {
        self.outcome = outcome
        self.minutesRecorded = outcome == .started
            ? nil
            : minutesRecorded.map { MetricsMath.clamp($0, to: 0...MetricsLimits.maximumMeetingMinutes) }
    }
}

/// First-run milestones. Mirrors `OnboardingFunnel.Event` one to one.
public enum FunnelStep: String, MetricsKey {
    case onboardingStarted, speechDownloadStarted, speechDownloadFinished, modelReady
    case microphoneGranted, accessibilityGranted, firstDictation, onboardingCompleted

    public init(_ event: OnboardingFunnel.Event) {
        switch event {
        case .onboardingStarted: self = .onboardingStarted
        case .speechDownloadStarted: self = .speechDownloadStarted
        case .speechDownloadFinished: self = .speechDownloadFinished
        case .modelReady: self = .modelReady
        case .microphoneGranted: self = .microphoneGranted
        case .accessibilityGranted: self = .accessibilityGranted
        case .firstDictation: self = .firstDictation
        case .onboardingCompleted: self = .onboardingCompleted
        }
    }
}

public enum MetricEvent: Sendable, Equatable, Codable {
    case dictation(DictationMetricEvent)
    case voiceAction(VoiceActionMetricEvent)
    case meeting(MeetingMetricEvent)
    case funnel(FunnelStep)

    /// The same event passed back through its clamping initializer. Events read back from the
    /// local journal go through this, so a damaged or hand-edited file cannot smuggle an
    /// out-of-range number past the clamps.
    public var normalized: MetricEvent {
        switch self {
        case .dictation(let value):
            .dictation(DictationMetricEvent(
                feedback: value.feedback, cleanupLevel: value.cleanupLevel, modeKind: value.modeKind,
                wordCount: value.wordCount, audioMilliseconds: value.audioMilliseconds,
                speechMilliseconds: value.speechMilliseconds, cleanupMilliseconds: value.cleanupMilliseconds,
                modelState: value.modelState, tone: value.tone, appKind: value.appKind, editSize: value.editSize))
        case .voiceAction(let value): .voiceAction(VoiceActionMetricEvent(outcome: value.outcome, failure: value.failure))
        case .meeting(let value): .meeting(MeetingMetricEvent(outcome: value.outcome, minutesRecorded: value.minutesRecorded))
        case .funnel: self
        }
    }
}

/// An event with the calendar day it belongs to and the app build that was running. Only the day
/// is kept (never a time of day): it is all a daily batch needs, and it keeps the on-disk journal
/// no finer than what is eventually sent. Order within a day is the order of the journal lines.
public struct MetricEventRecord: Sendable, Equatable, Codable {
    public let day: MetricsDay
    public let appBuild: Int
    public let event: MetricEvent

    public init(day: MetricsDay, appBuild: Int, event: MetricEvent) {
        self.day = day
        self.appBuild = appBuild
        self.event = event
    }

    /// The record for an event at `date`, with its day taken in `calendar`'s time zone (Gregorian).
    public init(occurredAt date: Date, calendar: Calendar, appBuild: Int, event: MetricEvent) throws {
        try self.init(day: MetricsDay(date: date, calendar: calendar), appBuild: appBuild, event: event)
    }
}

extension MetricsDay {
    /// The calendar day `date` falls on in `calendar`'s time zone (always Gregorian, so a Buddhist
    /// or Islamic system calendar cannot produce a day the server would reject).
    public init(date: Date, calendar: Calendar) throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        try self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }
}
