import Foundation

/// Every screen onboarding can show. The required ones are the gate-11 flow plus the key lesson
/// (Welcome · Microphone · Accessibility · Your key · Try it · You're set): setup ends when the
/// first dictation works. "Your key" (`hotkeyPractice`) became required on 2026-10-28: the key lights
/// when the person double-taps it, and Continue unlocks then, so Try it starts from a gesture they
/// have already done once.
/// The voice-action rehearsal is no longer a step (2026-10-11); it is an optional thing to try
/// from Settings → Voice actions. The four optional steps exist only to be useful *while the
/// speech model is still downloading* and are inserted by `OnboardingPacing` just before
/// "Try it", never on a fast connection.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case welcome, microphone, accessibility
    /// "Have an invite code?", right after welcome. Optional like the paced steps, but it is not
    /// part of their pool: it appears whenever it is eligible, whatever the download pace.
    case invite
    case hotkeyPractice, micCheck, dictionary, writingStyle, privacy
    case tryIt, done

    /// The flow on a fast connection: gate 11 plus the key lesson.
    public static let required: [OnboardingStep] = [.welcome, .microphone, .accessibility, .hotkeyPractice, .tryIt, .done]

    /// Optional steps in the order they earn their place. The first decides whether the first
    /// dictation works at all (the right mic is picked); the next two make it better (names spelled
    /// right; the writing level you want); privacy is reassurance the welcome screen already states
    /// in one line.
    public static let optionalByValue: [OnboardingStep] = [.micCheck, .dictionary, .writingStyle, .privacy]

    public var isOptional: Bool { self == .invite || Self.optionalByValue.contains(self) }

    /// What a typical person spends on the step, from the gate-11 target (≤ 90 s to the first
    /// dictation) and the lengths of the optional screens. Only used to estimate "how long until
    /// the user reaches Try it", so rough is fine; being slightly short errs toward *not* adding
    /// a step, which is the safe side (a fake wait is worse than a short one).
    public var typicalSeconds: TimeInterval {
        switch self {
        case .welcome: 10
        case .invite: 10
        case .microphone: 12
        case .accessibility: 25
        case .hotkeyPractice: 20
        case .micCheck: 15
        case .dictionary: 30
        case .writingStyle: 20
        case .privacy: 15
        case .tryIt: 20
        case .done: 10
        }
    }
}

/// The required model's time-to-ready as pacing sees it.
public enum DownloadETA: Equatable, Sendable {
    /// Downloaded and loaded (or loading from disk: seconds away, not a wait).
    case ready
    /// Downloading, but not enough data for an honest estimate yet.
    case estimating
    /// Downloading; smoothed seconds left.
    case seconds(TimeInterval)
    /// Not downloading: offline, failed, or paused on a metered network waiting for the user.
    case waiting(WaitReason)

    public enum WaitReason: String, Equatable, Sendable {
        case offline, failed, meteredNetwork
    }
}

/// How the connection compares with the time onboarding naturally takes.
public enum OnboardingPace: String, Codable, Sendable {
    /// Ready before the user reaches "Try it": onboarding is unchanged.
    case onTime
    /// A wait that a few optional steps can cover.
    case slow
    /// A wait longer than every optional step together; the user finishes anyway.
    case verySlow
    /// Nothing is arriving (offline, failed, paused for consent); no steps are padded in.
    case stalled
    /// Too early to know (no rate yet); decided again at the next step.
    case unknown
}

/// What the "Try it" step shows, as a function of the live ETA.
public enum TryItVariant: Equatable, Sendable {
    /// Practice box, ready to go.
    case ready
    /// Practice box, with "ready in about N s" under it (nil while estimating).
    case almostReady(TimeInterval?)
    /// No practice box: "Your speech model is still downloading (4 min left). We'll let you
    /// know when it's ready." and a Finish button.
    case stillDownloading(TimeInterval)
    /// No practice box: offline / failed / waiting for the user's OK on a metered network.
    case waiting(DownloadETA.WaitReason)
}

public struct PacingPlan: Equatable, Sendable {
    public let pace: OnboardingPace
    /// The steps after the current one, in order, with any optional steps inserted.
    public let upcoming: [OnboardingStep]
    /// Just the optional steps this plan inserted.
    public let inserted: [OnboardingStep]
}

/// The pacing policy: a pure function of (download ETA, where the user is, what's left), so it
/// can be tested as a table and re-run at every step change with fresh numbers.
///
/// - **On time** (ready, or ETA ≤ time to reach Try it + `onTimeSlack`): no optional steps.
/// - **Slow** (the gap fits inside the optional steps): the fewest optional steps, in value
///   order, whose typical time covers the gap. Each is skippable; skipping just moves on.
/// - **Very slow** (the gap is longer than all of them): every optional step (they are useful
///   on their own and each is skippable), then Try it says "still downloading, N min left,
///   we'll let you know".
/// - **Stalled** (offline / failed / paused for consent): none. There is no wait with an end to
///   fill, so padding would be a fake wait; the user finishes and is notified later.
/// - **Unknown** (estimating): none yet; the next step change decides with a measured rate.
public enum OnboardingPacing {
    /// Within this many seconds of arriving on time counts as on time: Try it's own first
    /// seconds (reading the prompt, clicking the box) absorb it, and "Ready in about 10 s"
    /// under the practice box is honest.
    public static let onTimeSlack: TimeInterval = 10
    /// At or below this many seconds left, Try it keeps the practice box ("almost ready").
    public static let almostReadyThreshold: TimeInterval = 45

    /// - Parameters:
    ///   - eta: the required model's current ETA.
    ///   - step: the step the user is leaving (its own time is already spent).
    ///   - remaining: the *required* steps after `step`, in order (optional steps are chosen
    ///     here, not passed in).
    ///   - optionalPool: optional steps still available (eligible and not yet shown/skipped).
    public static func plan(
        eta: DownloadETA, after step: OnboardingStep, remaining: [OnboardingStep], optionalPool: [OnboardingStep]
    ) -> PacingPlan {
        let required = remaining.filter { !$0.isOptional }
        let pool = OnboardingStep.optionalByValue.filter(optionalPool.contains)
        guard required.contains(.tryIt), !pool.isEmpty else {
            return PacingPlan(pace: pace(for: eta, gap: nil, capacity: 0), upcoming: required, inserted: [])
        }
        let timeToTryIt = required.prefix { $0 != .tryIt }.reduce(0) { $0 + $1.typicalSeconds }
        let capacity = pool.reduce(0) { $0 + $1.typicalSeconds }
        let gap: TimeInterval? = if case .seconds(let seconds) = eta { seconds - timeToTryIt } else { nil }
        let pace = pace(for: eta, gap: gap, capacity: capacity)
        let inserted: [OnboardingStep]
        switch pace {
        case .onTime, .stalled, .unknown:
            inserted = []
        case .verySlow:
            inserted = pool
        case .slow:
            inserted = fewestCovering(gap ?? 0, from: pool)
        }
        return PacingPlan(pace: pace, upcoming: insert(inserted, beforeTryItIn: required), inserted: inserted)
    }

    /// The Try-it variant for the live ETA (re-evaluated while the step is on screen).
    public static func tryItVariant(for eta: DownloadETA) -> TryItVariant {
        switch eta {
        case .ready: .ready
        case .estimating: .almostReady(nil)
        case .seconds(let seconds) where seconds <= almostReadyThreshold: .almostReady(seconds)
        case .seconds(let seconds): .stillDownloading(seconds)
        case .waiting(let reason): .waiting(reason)
        }
    }

    static func pace(for eta: DownloadETA, gap: TimeInterval?, capacity: TimeInterval) -> OnboardingPace {
        switch eta {
        case .ready: return .onTime
        case .estimating: return .unknown
        case .waiting: return .stalled
        case .seconds:
            guard let gap else { return .onTime }
            if gap <= onTimeSlack { return .onTime }
            return gap <= capacity ? .slow : .verySlow
        }
    }

    private static func fewestCovering(_ gap: TimeInterval, from pool: [OnboardingStep]) -> [OnboardingStep] {
        var chosen: [OnboardingStep] = []
        var covered: TimeInterval = 0
        for step in pool where covered < gap - onTimeSlack {
            chosen.append(step)
            covered += step.typicalSeconds
        }
        return chosen
    }

    private static func insert(_ steps: [OnboardingStep], beforeTryItIn required: [OnboardingStep]) -> [OnboardingStep] {
        guard !steps.isEmpty, let index = required.firstIndex(of: .tryIt) else { return required }
        var result = required
        result.insert(contentsOf: steps, at: index)
        return result
    }
}
