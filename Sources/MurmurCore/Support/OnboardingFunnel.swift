import Foundation

/// A local-only first-run funnel: the timestamps that let us measure gate 11's
/// "time to first successful dictation" on a real install without any network or telemetry.
///
/// Stored as JSON in `AppSettings` (UserDefaults) and shown in the DEBUG Developer pane.
/// Each event is recorded once — the *first* occurrence wins — so a user who re-grants a
/// permission later, or dictates a hundred times, never moves the original numbers.
/// Values only; never text, audio, or app names.
public struct OnboardingFunnel: Codable, Equatable, Sendable {
    public enum Event: String, CaseIterable, Codable, Sendable {
        /// The onboarding window first appeared.
        case onboardingStarted
        /// The speech model's download began (usually at first launch, before the welcome screen
        /// is done — recorded against the onboarding clock once it starts).
        case speechDownloadStarted
        /// Its bytes are all on disk and verified (loading follows).
        case speechDownloadFinished
        /// The speech model finished downloading/loading and can transcribe.
        case modelReady
        case microphoneGranted
        case accessibilityGranted
        /// First dictation that produced text (pasted, or shown in the pill when no field had
        /// focus). "Onboarding start → first paste" is the gate-11 number.
        case firstDictation
        /// "Start using Hushy" pressed (or onboarding otherwise dismissed).
        case onboardingCompleted

        public var title: String {
            switch self {
            case .onboardingStarted: "Onboarding started"
            case .speechDownloadStarted: "Speech model download started"
            case .speechDownloadFinished: "Speech model download finished"
            case .modelReady: "Speech model ready"
            case .microphoneGranted: "Microphone granted"
            case .accessibilityGranted: "Accessibility granted"
            case .firstDictation: "First dictation"
            case .onboardingCompleted: "Onboarding completed"
            }
        }
    }

    public private(set) var timestamps: [Event: Date]
    /// The first measured throughput bucket of the speech-model download (first one wins).
    public private(set) var speedBucket: SpeedBucket?
    /// The pace behind the first pacing decision that reached "Try it" (first one wins).
    public private(set) var pace: OnboardingPace?
    /// Optional "while it downloads" steps shown, in order, and the ones the user skipped.
    public private(set) var optionalStepsShown: [OnboardingStep]
    public private(set) var optionalStepsSkipped: [OnboardingStep]

    public init(
        timestamps: [Event: Date] = [:], speedBucket: SpeedBucket? = nil, pace: OnboardingPace? = nil,
        optionalStepsShown: [OnboardingStep] = [], optionalStepsSkipped: [OnboardingStep] = []
    ) {
        self.timestamps = timestamps
        self.speedBucket = speedBucket
        self.pace = pace
        self.optionalStepsShown = optionalStepsShown
        self.optionalStepsSkipped = optionalStepsSkipped
    }

    private enum CodingKeys: String, CodingKey {
        case timestamps, speedBucket, pace, optionalStepsShown, optionalStepsSkipped
    }

    /// Funnels saved before the download fields existed decode with them empty. Unknown step or
    /// bucket names (a newer build's values) are dropped rather than failing the whole funnel.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamps = try container.decodeIfPresent([Event: Date].self, forKey: .timestamps) ?? [:]
        speedBucket = (try? container.decodeIfPresent(SpeedBucket.self, forKey: .speedBucket)) ?? nil
        pace = (try? container.decodeIfPresent(OnboardingPace.self, forKey: .pace)) ?? nil
        let shown = (try? container.decodeIfPresent([String].self, forKey: .optionalStepsShown)) ?? nil
        let skipped = (try? container.decodeIfPresent([String].self, forKey: .optionalStepsSkipped)) ?? nil
        optionalStepsShown = (shown ?? []).compactMap(OnboardingStep.init(rawValue:))
        optionalStepsSkipped = (skipped ?? []).compactMap(OnboardingStep.init(rawValue:))
    }

    public static let empty = OnboardingFunnel()

    public subscript(event: Event) -> Date? { timestamps[event] }

    public var hasStarted: Bool { timestamps[.onboardingStarted] != nil }

    /// Returns a copy with `event` recorded at `date` — unless it was already recorded, in which
    /// case the original is kept (first occurrence wins). Events other than
    /// `onboardingStarted` are ignored until the funnel has started, so a permission granted
    /// on a long-ago install can't produce a negative or meaningless duration later.
    public func marking(_ event: Event, at date: Date = Date()) -> OnboardingFunnel {
        if timestamps[event] != nil { return self }
        if event != .onboardingStarted, !hasStarted { return self }
        var copy = self
        copy.timestamps[event] = date
        return copy
    }

    /// Records the first measured speed bucket (ignored before onboarding starts, like events).
    public func recordingSpeed(_ bucket: SpeedBucket) -> OnboardingFunnel {
        guard hasStarted, speedBucket == nil else { return self }
        var copy = self
        copy.speedBucket = bucket
        return copy
    }

    /// Records the pace of the first plan that reached "Try it".
    public func recordingPace(_ newPace: OnboardingPace) -> OnboardingFunnel {
        guard hasStarted, pace == nil else { return self }
        var copy = self
        copy.pace = newPace
        return copy
    }

    /// Records that an optional step was shown (once) and, if so, skipped (once).
    public func recordingOptionalStep(_ step: OnboardingStep, skipped: Bool) -> OnboardingFunnel {
        guard hasStarted, step.isOptional else { return self }
        var copy = self
        if !copy.optionalStepsShown.contains(step) { copy.optionalStepsShown.append(step) }
        if skipped, !copy.optionalStepsSkipped.contains(step) { copy.optionalStepsSkipped.append(step) }
        return copy
    }

    /// Seconds from onboarding start to `event`; nil until both are recorded.
    public func secondsToEvent(_ event: Event) -> TimeInterval? {
        guard let start = timestamps[.onboardingStarted], let at = timestamps[event] else { return nil }
        return max(0, at.timeIntervalSince(start))
    }

    /// The gate-11 number: onboarding start → first dictation, in seconds.
    public var timeToFirstDictation: TimeInterval? { secondsToEvent(.firstDictation) }

    /// One row per event, in funnel order, for the Developer pane: the title, the wall-clock
    /// timestamp (or "—"), and "+12.3 s" since onboarding started.
    public struct Row: Equatable, Sendable {
        public let event: Event
        public let timestamp: Date?
        public let offsetSeconds: TimeInterval?
    }

    public var rows: [Row] {
        Event.allCases.map { event in
            Row(event: event, timestamp: timestamps[event], offsetSeconds: secondsToEvent(event))
        }
    }

    /// "12.3 s", "1 min 5 s" — the compact duration used in the Developer pane.
    public static func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes) min \(rest) s"
    }
}
