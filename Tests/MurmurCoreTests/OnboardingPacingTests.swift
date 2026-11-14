import Foundation
import Testing
@testable import MurmurCore

@Suite("Onboarding pacing policy")
struct OnboardingPacingTests {
    private let allOptional = OnboardingStep.optionalByValue

    /// Leaving the key lesson: only Try it and Done are left, so the time to Try it is zero and
    /// the whole ETA is the gap to fill.
    private func planLeavingKeyLesson(_ eta: DownloadETA, pool: [OnboardingStep]? = nil) -> PacingPlan {
        OnboardingPacing.plan(eta: eta, after: .hotkeyPractice, remaining: [.tryIt, .done], optionalPool: pool ?? allOptional)
    }

    struct Row: CustomTestStringConvertible, Sendable {
        let eta: DownloadETA
        let pace: OnboardingPace
        let inserted: [OnboardingStep]
        var testDescription: String { "\(eta) → \(pace)" }
    }

    @Test("leaving the key lesson, by ETA", arguments: [
        Row(eta: .ready, pace: .onTime, inserted: []),
        Row(eta: .seconds(0), pace: .onTime, inserted: []),
        Row(eta: .seconds(10), pace: .onTime, inserted: []),
        // 15 s gap, 5 s beyond the slack: one step covers it.
        Row(eta: .seconds(15), pace: .slow, inserted: [.micCheck]),
        // 40 s: mic check (15) + dictionary (30) = 45 ≥ 40 − 10.
        Row(eta: .seconds(40), pace: .slow, inserted: [.micCheck, .dictionary]),
        Row(eta: .seconds(75), pace: .slow, inserted: [.micCheck, .dictionary, .writingStyle]),
        // Capacity is 80 s; exactly at capacity is still slow and takes everything.
        Row(eta: .seconds(80), pace: .slow, inserted: [.micCheck, .dictionary, .writingStyle, .privacy]),
        Row(eta: .seconds(81), pace: .verySlow, inserted: [.micCheck, .dictionary, .writingStyle, .privacy]),
        Row(eta: .seconds(1_800), pace: .verySlow, inserted: [.micCheck, .dictionary, .writingStyle, .privacy]),
        Row(eta: .estimating, pace: .unknown, inserted: []),
        Row(eta: .waiting(.offline), pace: .stalled, inserted: []),
        Row(eta: .waiting(.failed), pace: .stalled, inserted: []),
        Row(eta: .waiting(.meteredNetwork), pace: .stalled, inserted: []),
    ])
    func table(_ row: Row) {
        let plan = planLeavingKeyLesson(row.eta)
        #expect(plan.pace == row.pace)
        #expect(plan.inserted == row.inserted)
        #expect(plan.upcoming == row.inserted + [.tryIt, .done])
    }

    @Test("steps still ahead count toward reaching Try it")
    func requiredStepsAheadAbsorbTheWait() {
        // From Welcome: Microphone (12) + Accessibility (25) + the key lesson (20) = 57 s until Try it.
        let ahead: [OnboardingStep] = [.microphone, .accessibility, .hotkeyPractice, .tryIt, .done]
        let early = OnboardingPacing.plan(eta: .seconds(65), after: .welcome, remaining: ahead, optionalPool: allOptional)
        #expect(early.pace == .onTime)
        #expect(early.upcoming == ahead)

        let slower = OnboardingPacing.plan(eta: .seconds(80), after: .welcome, remaining: ahead, optionalPool: allOptional)
        #expect(slower.pace == .slow)
        // Optional steps always go right before Try it: never between permissions, never before the key.
        #expect(slower.upcoming == [.microphone, .accessibility, .hotkeyPractice, .micCheck, .tryIt, .done])
    }

    @Test("only eligible, unseen steps are chosen, in value order")
    func respectsPool() {
        let plan = planLeavingKeyLesson(.seconds(40), pool: [.privacy, .dictionary])
        #expect(plan.inserted == [.dictionary])
        #expect(plan.pace == .slow)
        // Capacity is what's left in the pool: 45 s here, so a 60 s gap is already "very slow".
        let longer = planLeavingKeyLesson(.seconds(60), pool: [.privacy, .dictionary])
        #expect(longer.inserted == [.dictionary, .privacy])
        #expect(longer.pace == .verySlow)
        let empty = planLeavingKeyLesson(.seconds(600), pool: [])
        #expect(empty.inserted.isEmpty)
        #expect(empty.upcoming == [.tryIt, .done])
    }

    @Test("past Try it nothing is inserted")
    func afterTryIt() {
        let plan = OnboardingPacing.plan(eta: .seconds(600), after: .tryIt, remaining: [.done], optionalPool: allOptional)
        #expect(plan.inserted.isEmpty)
        #expect(plan.upcoming == [.done])
    }

    @Test("Try it variant follows the live ETA")
    func tryItVariants() {
        #expect(OnboardingPacing.tryItVariant(for: .ready) == .ready)
        #expect(OnboardingPacing.tryItVariant(for: .estimating) == .almostReady(nil))
        #expect(OnboardingPacing.tryItVariant(for: .seconds(30)) == .almostReady(30))
        #expect(OnboardingPacing.tryItVariant(for: .seconds(45)) == .almostReady(45))
        #expect(OnboardingPacing.tryItVariant(for: .seconds(240)) == .stillDownloading(240))
        #expect(OnboardingPacing.tryItVariant(for: .waiting(.offline)) == .waiting(.offline))
        #expect(OnboardingPacing.tryItVariant(for: .waiting(.meteredNetwork)) == .waiting(.meteredNetwork))
    }
}

@Suite("Onboarding step sequencing")
struct OnboardingFlowTests {
    private let everything = Set(OnboardingStep.optionalByValue)

    /// Walks the flow to the end, taking `etaAt(step)` as the ETA when leaving each step.
    private func walk(eligible: Set<OnboardingStep>, skipAll: Bool = false, _ etaAt: (OnboardingStep) -> DownloadETA) -> (OnboardingFlow, [OnboardingStep]) {
        var flow = OnboardingFlow()
        var visited = [flow.current]
        while !flow.isLast {
            flow = flow.advancing(eta: etaAt(flow.current), eligible: eligible, skipped: skipAll && flow.current.isOptional)
            visited.append(flow.current)
        }
        return (flow, visited)
    }

    @Test("fast connection: the flow is the gate-11 flow plus the key lesson")
    func fast() {
        let (flow, visited) = walk(eligible: everything) { _ in .ready }
        #expect(visited == OnboardingStep.required)
        #expect(flow.shownOptional.isEmpty)
        #expect(flow.lastPace == .onTime)
    }

    @Test("fast enough: a download finishing during the permissions changes nothing")
    func finishesDuringPermissions() {
        let (_, visited) = walk(eligible: everything) { step in
            step == .welcome ? .seconds(30) : .ready
        }
        #expect(visited == OnboardingStep.required)
    }

    @Test("slow connection: a couple of optional steps, then Try it")
    func slow() {
        // 50 s left when leaving Accessibility, 28 s after the key lesson, 8 s after the mic
        // check: the policy re-plans each time and stops adding steps once it's close enough.
        let (flow, visited) = walk(eligible: everything) { step in
            switch step {
            case .welcome, .microphone: .estimating
            case .accessibility: .seconds(50)
            case .hotkeyPractice: .seconds(28)
            case .micCheck: .seconds(8)
            default: .ready
            }
        }
        #expect(visited == [.welcome, .microphone, .accessibility, .hotkeyPractice, .micCheck, .tryIt, .done])
        #expect(flow.shownOptional == [.micCheck])
        #expect(flow.lastPace == .onTime)  // by the last re-plan the model was nearly there
    }

    @Test("slow connection: the model finishing mid-way drops the rest")
    func dropsRemainingWhenReady() {
        let (flow, visited) = walk(eligible: everything) { step in
            switch step {
            case .accessibility: .seconds(95)
            case .hotkeyPractice: .seconds(60)
            case .micCheck: .ready
            default: .estimating
            }
        }
        #expect(visited == [.welcome, .microphone, .accessibility, .hotkeyPractice, .micCheck, .tryIt, .done])
        #expect(flow.shownOptional == [.micCheck])
    }

    @Test("very slow connection: every optional step, each skippable, then Try it")
    func verySlow() {
        let (flow, visited) = walk(eligible: everything, skipAll: true) { _ in .seconds(1_200) }
        #expect(visited == [.welcome, .microphone, .accessibility, .hotkeyPractice, .micCheck, .dictionary,
                            .writingStyle, .privacy, .tryIt, .done])
        #expect(flow.skippedOptional == OnboardingStep.optionalByValue)
        #expect(OnboardingPacing.tryItVariant(for: .seconds(1_200)) == .stillDownloading(1_200))
    }

    @Test("offline: nothing padded in; the user finishes anyway")
    func offline() {
        let (flow, visited) = walk(eligible: everything) { _ in .waiting(.offline) }
        #expect(visited == OnboardingStep.required)
        #expect(flow.shownOptional.isEmpty)
        #expect(flow.lastPace == .stalled)
    }

    @Test("steps whose permission is missing are never offered")
    func eligibility() {
        let (_, visited) = walk(eligible: [.dictionary, .privacy]) { _ in .seconds(1_200) }
        #expect(visited == [.welcome, .microphone, .accessibility, .hotkeyPractice, .dictionary, .privacy, .tryIt, .done])
    }

    @Test("back walks history without re-planning; an optional step is shown once")
    func back() {
        var flow = OnboardingFlow()
        flow = flow.advancing(eta: .estimating, eligible: everything)       // microphone
        flow = flow.advancing(eta: .estimating, eligible: everything)       // accessibility
        flow = flow.advancing(eta: .seconds(30), eligible: everything)      // hotkeyPractice (required)
        #expect(flow.current == .hotkeyPractice)
        flow = flow.advancing(eta: .seconds(25), eligible: everything)      // micCheck
        #expect(flow.current == .micCheck)
        flow = flow.goingBack()
        #expect(flow.current == .hotkeyPractice)
        flow = flow.advancing(eta: .seconds(25), eligible: everything)
        #expect(flow.current == .dictionary, "the mic check was shown once and is not offered again")
        #expect(flow.shownOptional == [.micCheck, .dictionary])
    }

    @Test("skipping Microphone or Accessibility is remembered for the closing step")
    func skippedPermissions() {
        var flow = OnboardingFlow()
        flow = flow.advancing(eta: .ready, eligible: everything, skipped: true)
        #expect(flow.current == .microphone)
        #expect(flow.skippedPermissions.isEmpty, "Welcome is not a permission")
        flow = flow.advancing(eta: .ready, eligible: everything, skipped: true)
        #expect(flow.skippedPermissions == [.microphone])
        flow = flow.advancing(eta: .ready, eligible: everything, skipped: true)
        #expect(flow.skippedPermissions == [.microphone, .accessibility])
        let again = flow.goingBack().advancing(eta: .ready, eligible: everything, skipped: true)
        #expect(again.skippedPermissions == [.microphone, .accessibility], "a second Skip does not record the step twice")
    }

    @Test("a permission granted elsewhere jumps forward through re-planning")
    func jump() {
        let flow = OnboardingFlow().advancing(eta: .estimating, eligible: everything)
            .advancing(to: .accessibility, eta: .estimating, eligible: everything)
        #expect(flow.current == .accessibility)
        let unchanged = flow.advancing(to: .welcome, eta: .ready, eligible: everything)
        #expect(unchanged == flow)
    }
}
