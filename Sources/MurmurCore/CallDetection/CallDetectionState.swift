import Foundation

/// Pure decision logic for "ask to record when a call starts," entirely independent of Core
/// Audio/AppKit so it can be unit-tested without a live microphone or process list.
///
/// Detection itself never looks at window titles or screen content — the only inputs this type
/// ever sees are "some other process is actively using the microphone" (from Core Audio's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` plus per-process `kAudioProcessPropertyIsRunningInput`,
/// see `CallDetector`) and that process's bundle id, mapped to a `MeetingApp`. Everything below
/// this line is pure and side-effect-free: given a sequence of "mic in use by app X at time T"
/// samples, it decides when to show a prompt, when it expires, and when to fire the "record"
/// action — nothing here touches `AVAudioSession`, `NSWorkspace`, `UserDefaults`, or a `Timer`.
public struct CallDetectionState: Sendable, Equatable {
    /// A visible "Zoom call detected · Record notes?" prompt, timed to auto-dismiss.
    public struct Prompt: Sendable, Equatable {
        public let app: MeetingApp
        /// When the prompt should disappear on its own if the user doesn't act.
        public let expiresAt: Date

        public init(app: MeetingApp, expiresAt: Date) {
            self.app = app
            self.expiresAt = expiresAt
        }
    }

    /// A cancellable "stop recording" countdown, shown after the call has looked over for a while.
    public struct StopCountdown: Sendable, Equatable {
        public let startedAt: Date
        public let fireAt: Date

        public init(startedAt: Date, fireAt: Date) {
            self.startedAt = startedAt
            self.fireAt = fireAt
        }
    }

    /// How long a call-detected prompt stays on screen before disappearing unanswered — the
    /// task's "disappears after 20 s."
    public static let promptDuration: TimeInterval = 20
    /// How long the mic must look idle (no app using it) before a stop countdown begins — the
    /// task's "after about 10 s without the mic in use."
    public static let stopDebounce: TimeInterval = 10
    /// Length of the cancellable countdown itself — the task's "5 s cancellable countdown."
    public static let stopCountdownDuration: TimeInterval = 5
    /// How long before the max-length limit fires that a warning should show.
    public static let maxLengthWarning: TimeInterval = 120

    /// Currently displayed prompt asking whether to record, or `nil` if none is showing.
    public private(set) var pendingPrompt: Prompt?
    /// The in-progress "call looks over, stopping in N…" countdown, or `nil` if not counting down.
    public private(set) var stopCountdown: StopCountdown?
    /// The meeting app Hushy is currently recording notes for (set once a prompt is accepted, or
    /// a recording is started some other way while a call is detected), or `nil` when idle.
    public private(set) var activeApp: MeetingApp?
    /// When the mic was last seen in use by some other process; `nil` once that gap has already
    /// produced a stop countdown or fired a stop, so repeated debounce evaluations are idempotent.
    private var lastMicActiveAt: Date?
    /// Apps the user chose "Never for <App>" for — never prompted again this run (and persisted
    /// by the caller across launches; see `CallDetectionSettings`/`AppSettings`).
    public private(set) var neverList: Set<MeetingApp>

    public init(neverList: Set<MeetingApp> = []) {
        self.neverList = neverList
    }

    // MARK: - Never-list

    public mutating func addToNeverList(_ app: MeetingApp) {
        neverList.insert(app)
        if pendingPrompt?.app == app { pendingPrompt = nil }
    }

    public mutating func removeFromNeverList(_ app: MeetingApp) {
        neverList.remove(app)
    }

    // MARK: - Call start / mic activity

    /// Effect: a decision the caller should act on.
    public enum Effect: Sendable, Equatable {
        case none
        /// Show the "App call detected · Record?" prompt near the pill.
        case showPrompt(MeetingApp)
        /// Dismiss whatever prompt is showing (expired, or the mic activity moved on).
        case dismissPrompt
        /// Start a cancellable stop countdown.
        case startStopCountdown
        /// Cancel an in-progress stop countdown (the call resumed before it fired).
        case cancelStopCountdown
        /// Stop recording now — the countdown reached zero.
        case stopRecording
        /// Show the "recording will stop in 2 minutes" warning.
        case showMaxLengthWarning
        /// Stop recording now — the max length was reached.
        case stopForMaxLength
    }

    /// Feeds one observation: as of `now`, is some other process actively using the microphone,
    /// and if so which app? Called on every poll tick (see `CallDetector`), whether or not
    /// anything changed since the last call — so this must be safe to call redundantly.
    ///
    /// - Parameters:
    ///   - app: the `MeetingApp` currently using the mic, or `nil` if no recognized call app is.
    ///   - isRecording: whether a note is already recording (never prompt while recording — the
    ///     task's "no prompt while already recording").
    ///   - now: injected for deterministic tests; production code passes `Date()`.
    public mutating func observeMicActivity(app: MeetingApp?, isRecording: Bool, now: Date) -> Effect {
        if let app {
            lastMicActiveAt = now
            // Any live mic activity cancels a pending stop countdown — the call resumed.
            if stopCountdown != nil {
                stopCountdown = nil
                return .cancelStopCountdown
            }
            guard !isRecording, activeApp == nil, pendingPrompt == nil, !neverList.contains(app) else {
                return .none
            }
            pendingPrompt = Prompt(app: app, expiresAt: now.addingTimeInterval(Self.promptDuration))
            return .showPrompt(app)
        }

        // No recognized call app is using the mic right now.
        if let prompt = pendingPrompt, now >= prompt.expiresAt {
            pendingPrompt = nil
            return .dismissPrompt
        }
        guard isRecording, activeApp != nil, stopCountdown == nil else { return .none }
        guard let lastActive = lastMicActiveAt, now.timeIntervalSince(lastActive) >= Self.stopDebounce else {
            return .none
        }
        stopCountdown = StopCountdown(startedAt: now, fireAt: now.addingTimeInterval(Self.stopCountdownDuration))
        return .startStopCountdown
    }

    /// Advances time without a fresh mic-activity sample — used to check whether a pending
    /// prompt has expired or a stop countdown has reached zero between poll ticks.
    public mutating func tick(now: Date) -> Effect {
        if let prompt = pendingPrompt, now >= prompt.expiresAt {
            pendingPrompt = nil
            return .dismissPrompt
        }
        if let countdown = stopCountdown, now >= countdown.fireAt {
            stopCountdown = nil
            activeApp = nil
            lastMicActiveAt = nil
            return .stopRecording
        }
        return .none
    }

    /// User tapped "Record" on the prompt: starts a note for `pendingPrompt.app`.
    public mutating func acceptPrompt() -> MeetingApp? {
        guard let app = pendingPrompt?.app else { return nil }
        pendingPrompt = nil
        activeApp = app
        return app
    }

    /// User tapped "Not now" (or the prompt expired): dismiss without recording.
    public mutating func dismissPrompt() {
        pendingPrompt = nil
    }

    /// User tapped the countdown's cancel control: keep recording.
    public mutating func cancelStopCountdown() {
        stopCountdown = nil
        lastMicActiveAt = Date()
    }

    /// Marks a recording as started outside the prompt flow (e.g. the user pressed record
    /// manually while a call happened to be active) so a later mic dropout still triggers the
    /// auto-stop countdown for it.
    public mutating func beginTrackingActiveCall(app: MeetingApp) {
        activeApp = app
        pendingPrompt = nil
    }

    /// Clears all in-progress state — called when a note recording ends for any reason (manual
    /// stop, max length, error) so stale prompts/countdowns from a previous note never leak into
    /// the next one.
    public mutating func reset() {
        pendingPrompt = nil
        stopCountdown = nil
        activeApp = nil
        lastMicActiveAt = nil
    }
}

/// Pure logic for "Maximum length," independent of `CallDetectionState` since a max-length note
/// need not have started from call detection at all (a manually-started note is capped too).
public enum MaxRecordingLength: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    case thirtyMinutes, oneHour, twoHours, fourHours

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .fourHours: 4 * 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .fourHours: "4 hours"
        }
    }

    /// Default per the task's contract ("2 hours (default)").
    public static let `default`: MaxRecordingLength = .twoHours

    /// Given how long a note has been recording, what (if anything) should happen: nothing, a
    /// warning at `CallDetectionState.maxLengthWarning` before the limit, or a stop once the
    /// limit is reached. Pure function of duration so it's trivial to test at exact boundaries.
    public func effect(elapsedSeconds: Double, warningAlreadyShown: Bool) -> CallDetectionState.Effect {
        if elapsedSeconds >= seconds { return .stopForMaxLength }
        if !warningAlreadyShown, elapsedSeconds >= seconds - CallDetectionState.maxLengthWarning {
            return .showMaxLengthWarning
        }
        return .none
    }
}
