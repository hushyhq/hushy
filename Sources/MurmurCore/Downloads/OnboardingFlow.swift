import Foundation

/// Onboarding's step sequence as a value: where the user is, what comes next, and which
/// optional "while it downloads" steps were shown or skipped. Every forward move re-runs
/// `OnboardingPacing` with the live ETA, so optional steps are chosen at the last moment (and
/// dropped the moment the model is ready). Back never re-plans; it just walks history.
public struct OnboardingFlow: Equatable, Sendable {
    /// Steps already visited plus the currently planned remainder.
    public private(set) var sequence: [OnboardingStep]
    public private(set) var index: Int
    /// Optional steps the user has seen (in order), and the subset they skipped.
    public private(set) var shownOptional: [OnboardingStep]
    public private(set) var skippedOptional: [OnboardingStep]
    /// Microphone or Accessibility left with Skip while access was still missing. The closing
    /// step reads this with the live permission: granted later, it says "You're set."; still
    /// missing, it says "Almost." (`OnboardingDoneCopy`).
    public private(set) var skippedPermissions: [OnboardingStep]
    /// The pace behind the most recent plan that could insert steps (for the funnel/tests).
    public private(set) var lastPace: OnboardingPace?

    public init() {
        sequence = OnboardingStep.required
        index = 0
        shownOptional = []
        skippedOptional = []
        skippedPermissions = []
        lastPace = nil
    }

    /// Snapshot/test entry point: open on `step` of the given sequence.
    public init(sequence: [OnboardingStep], at step: OnboardingStep) {
        self.sequence = sequence
        index = sequence.firstIndex(of: step) ?? 0
        shownOptional = sequence.prefix(index + 1).filter(\.isOptional)
        skippedOptional = []
        skippedPermissions = []
        lastPace = nil
    }

    public var current: OnboardingStep { sequence[index] }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { current == .done }
    public var upcoming: [OnboardingStep] { Array(sequence.dropFirst(index + 1)) }

    /// Paced optional steps in the plan (visited or still ahead), for the stepper's "while it
    /// downloads" group. The invite step belongs to the first group, not this one.
    public var plannedOptional: [OnboardingStep] { sequence.filter(OnboardingStep.optionalByValue.contains) }

    /// Moves forward one step. `skipped` marks the step being left as skipped. Optional steps are
    /// recorded in `skippedOptional`. Microphone and Accessibility are recorded in
    /// `skippedPermissions`, so the closing step can tell a Skip from a grant. `eligible` is the
    /// set of optional steps whose preconditions hold (e.g. hotkey practice needs Accessibility,
    /// the mic check needs the microphone).
    public func advancing(eta: DownloadETA, eligible: Set<OnboardingStep>, skipped: Bool = false) -> OnboardingFlow {
        guard !isLast else { return self }
        var next = self
        if skipped, current.isOptional, !next.skippedOptional.contains(current) {
            next.skippedOptional.append(current)
        }
        if skipped, current == .microphone || current == .accessibility, !next.skippedPermissions.contains(current) {
            next.skippedPermissions.append(current)
        }
        let visited = sequence.prefix(index + 1)
        let pool = OnboardingStep.optionalByValue.filter {
            eligible.contains($0) && !visited.contains($0) && !shownOptional.contains($0)
        }
        let requiredAhead = upcoming.filter { !$0.isOptional }
        let plan = OnboardingPacing.plan(eta: eta, after: current, remaining: requiredAhead, optionalPool: pool)
        if requiredAhead.contains(.tryIt) { next.lastPace = plan.pace }
        var upcoming = plan.upcoming
        // Not pacing's call: the invite step follows welcome whenever it is eligible.
        if current == .welcome, eligible.contains(.invite) { upcoming.insert(.invite, at: 0) }
        next.sequence = Array(visited) + upcoming
        next.index = index + 1
        if next.current.isOptional, !next.shownOptional.contains(next.current) {
            next.shownOptional.append(next.current)
        }
        return next
    }

    /// Jumps forward to `step` if it is ahead in the plan (a permission granted elsewhere moves
    /// the flow on by itself); re-plans through each intermediate step so optional steps still
    /// get their chance. No-op if `step` isn't ahead.
    public func advancing(to step: OnboardingStep, eta: DownloadETA, eligible: Set<OnboardingStep>) -> OnboardingFlow {
        var flow = self
        var guardCount = 0
        while flow.current != step, !flow.isLast, flow.upcoming.contains(step), guardCount < 16 {
            flow = flow.advancing(eta: eta, eligible: eligible)
            guardCount += 1
        }
        return flow
    }

    public func goingBack() -> OnboardingFlow {
        guard index > 0 else { return self }
        var previous = self
        previous.index = index - 1
        return previous
    }
}
