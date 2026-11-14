import Foundation

/// What the live meeting screen says about capture, so a meeting never comes out empty without
/// anyone noticing. Each side of the call (your microphone, the call's audio) reports when it last
/// heard sound above a speech-level floor; the verdict is a pure function of those times.
public struct MeetingCapture: Sendable, Equatable {
    public enum Side: Sendable, Equatable { case microphone, call }

    public enum Signal: Sendable, Equatable {
        /// Sound in the last few seconds.
        case hearing
        /// Silent for a while; normal in a conversation.
        case quiet
        /// This side has been silent long enough, while the other side talked, that something is
        /// probably wrong (muted mic, call audio not allowed).
        case silent
        /// Not being recorded in this meeting (call audio off or not permitted).
        case off
    }

    public struct Warning: Sendable, Equatable {
        public let side: Side
        public let title: String
        public let detail: String
    }

    /// Below this RMS a buffer is room noise, not speech (about −40 dBFS).
    public static let heardFloor: Float = 0.01
    static let hearingWindow: TimeInterval = 3
    /// A side is called silent only after this long with nothing, while the other side spoke.
    static let silentAfter: TimeInterval = 120

    public var startedAt: Date
    public var microphoneLastHeard: Date?
    public var callLastHeard: Date?
    public var isCapturingCall: Bool
    /// The person asked for the call's audio (Settings), whether or not macOS allowed it.
    public var callRequested: Bool
    /// What capture health found wrong with each side right now (stalled, or exact zeros), from the journal ticks.
    public var microphoneProblem: CaptureHealth.Problem?
    public var callProblem: CaptureHealth.Problem?

    public init(startedAt: Date, microphoneLastHeard: Date? = nil, callLastHeard: Date? = nil, isCapturingCall: Bool,
                callRequested: Bool = false) {
        self.startedAt = startedAt
        self.microphoneLastHeard = microphoneLastHeard
        self.callLastHeard = callLastHeard
        self.isCapturingCall = isCapturingCall
        self.callRequested = callRequested || isCapturingCall
    }

    /// Records one level reading for a side; quiet readings change nothing.
    public mutating func heard(_ side: Side, rms: Float, at now: Date) {
        guard rms >= Self.heardFloor else { return }
        switch side {
        case .microphone: microphoneLastHeard = now
        case .call: callLastHeard = now
        }
    }

    public func signal(_ side: Side, now: Date) -> Signal {
        if side == .call, !isCapturingCall { return .off }
        let mine = side == .microphone ? microphoneLastHeard : callLastHeard
        let other = side == .microphone ? (isCapturingCall ? callLastHeard : nil) : microphoneLastHeard
        if let mine, now.timeIntervalSince(mine) <= Self.hearingWindow { return .hearing }
        let silentFor = now.timeIntervalSince(mine ?? startedAt)
        let otherSpokeRecently = other.map { now.timeIntervalSince($0) <= Self.silentAfter } ?? false
        if silentFor >= Self.silentAfter, otherSpokeRecently || (side == .microphone && other == nil && mine == nil) {
            return .silent
        }
        return .quiet
    }

    /// The one problem worth interrupting the person for, if any.
    public func warning(now: Date) -> Warning? {
        // A dead side, seen within seconds by capture health (notes audit B4). Copy waits for the batch review.
        if callProblem != nil, isCapturingCall {
            return Warning(side: .call, title: "[placeholder]", detail: "[placeholder]")
        }
        if microphoneProblem != nil {
            return Warning(side: .microphone, title: "[placeholder]", detail: "[placeholder]")
        }
        if callRequested, !isCapturingCall {
            return Warning(
                side: .call, title: "Only your side is being recorded",
                detail: "macOS didn't let Hushy hear the call's audio. Allow Hushy in System Settings → Privacy & Security → Screen & System Audio Recording, then start the next meeting.")
        }
        if signal(.call, now: now) == .silent {
            return Warning(
                side: .call, title: "Is the other side coming through?",
                detail: "Your microphone hears you, but the call's audio has been silent for two minutes. If people are talking, check the call isn't muted.")
        }
        if signal(.microphone, now: now) == .silent {
            return Warning(
                side: .microphone, title: "Is your microphone muted?",
                detail: isCapturingCall
                    ? "The other side is coming through, but nothing from your microphone for two minutes."
                    : "Nothing has come through the microphone for two minutes. Check the input in Settings → Microphone.")
        }
        return nil
    }
}

/// Where the transcript is, in words a person can check: what has been recorded and how much of it
/// is already written down. Pure, so the live screen and its snapshot say the same thing.
public struct MeetingTranscriptProgress: Sendable, Equatable {
    public let recordedSeconds: Double
    public let transcribedSeconds: Double
    public let chunkSeconds: Double

    public init(recordedSeconds: Double, transcribedSeconds: Double, chunkSeconds: Double) {
        self.recordedSeconds = recordedSeconds
        self.transcribedSeconds = min(transcribedSeconds, recordedSeconds)
        self.chunkSeconds = chunkSeconds
    }

    /// "Written down to 12:30" or, before the first part, "First lines in about 20 s".
    public var line: String {
        if transcribedSeconds <= 0 {
            let wait = max(5, Int((chunkSeconds - recordedSeconds).rounded(.up)))
            return recordedSeconds < chunkSeconds ? "First lines in about \(wait) s" : "Writing down the first part…"
        }
        return "Written down to \(MeetingMoment.clock(transcribedSeconds))"
    }

    /// Seconds recorded but not yet written down.
    public var behindSeconds: Double { max(0, recordedSeconds - transcribedSeconds) }
}

/// The stages a meeting goes through after Stop, as the page reports them. Ordered: each later
/// stage means every earlier one is finished.
public enum MeetingAfterStage: Int, Sendable, Equatable, Comparable, CaseIterable {
    case finishingTranscript
    case writingPage
    case namingSpeakers
    case ready

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .finishingTranscript: "Writing down the last part"
        case .writingPage: "Writing the page on your Mac"
        case .namingSpeakers: "Telling the voices apart"
        case .ready: "Ready"
        }
    }

    /// Where a meeting is, from what is stored: the note's status, whether its recording is still
    /// being transcribed, and whether speaker turns have landed yet.
    public static func stage(status: Note.Status, isTranscribing: Bool, hasSpeakerTurns: Bool, expectsSpeakerTurns: Bool) -> Self {
        switch status {
        case .recording: .finishingTranscript
        case .processing: isTranscribing ? .finishingTranscript : .writingPage
        case .ready, .failed: (expectsSpeakerTurns && !hasSpeakerTurns) ? .namingSpeakers : .ready
        }
    }
}
