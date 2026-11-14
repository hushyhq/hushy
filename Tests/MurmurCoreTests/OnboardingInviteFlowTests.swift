import Foundation
import Testing
@testable import MurmurCore

/// Where the optional invite-code step sits in the onboarding sequence and when it is skipped.
@Suite("Onboarding invite step", .timeLimit(.minutes(1)))
struct OnboardingInviteFlowTests {
    private let eligible: Set<OnboardingStep> = [.invite]

    private func leavingWelcome(eta: DownloadETA = .ready, eligible: Set<OnboardingStep>) -> OnboardingFlow {
        OnboardingFlow().advancing(eta: eta, eligible: eligible)
    }

    @Test("the step sits right after welcome and before permissions")
    func placement() {
        let flow = leavingWelcome(eligible: eligible)
        #expect(flow.current == .invite)
        #expect(flow.sequence == [.welcome, .invite, .microphone, .accessibility, .hotkeyPractice, .tryIt, .done])
    }

    @Test("it is optional but never part of the paced 'while it downloads' pool")
    func optionalButNotPaced() {
        #expect(OnboardingStep.invite.isOptional)
        #expect(!OnboardingStep.optionalByValue.contains(.invite))
        #expect(!OnboardingStep.required.contains(.invite))
        #expect(!leavingWelcome(eligible: eligible).plannedOptional.contains(.invite))
    }

    @Test("it is skipped when an invite grant is already active (not eligible)")
    func skippedWhenGrantActive() {
        let flow = leavingWelcome(eligible: [])
        #expect(flow.current == .microphone)
        #expect(!flow.sequence.contains(.invite))
    }

    @Test("'I don't have one' advances to the microphone step and is recorded as skipped")
    func skipAdvances() {
        let atInvite = leavingWelcome(eligible: eligible)
        let next = atInvite.advancing(eta: .ready, eligible: eligible, skipped: true)
        #expect(next.current == .microphone)
        #expect(next.skippedOptional == [.invite])
        #expect(next.shownOptional == [.invite])
    }

    @Test("redeeming and continuing advances the same way, without a skip")
    func continueAdvances() {
        let next = leavingWelcome(eligible: eligible).advancing(eta: .ready, eligible: eligible)
        #expect(next.current == .microphone)
        #expect(next.skippedOptional.isEmpty)
    }

    @Test("Back from the microphone step returns to the invite step, and going forward again does not duplicate it")
    func backAndForward() {
        let atMic = leavingWelcome(eligible: eligible).advancing(eta: .ready, eligible: eligible)
        let back = atMic.goingBack()
        #expect(back.current == .invite)
        let welcome = back.goingBack()
        #expect(welcome.current == .welcome)
        let again = welcome.advancing(eta: .ready, eligible: eligible)
        #expect(again.sequence.filter { $0 == .invite }.count == 1)
    }

    @Test("a slow download still gets its paced steps before Try it, after the invite step")
    func pacingUnchanged() {
        var flow = leavingWelcome(eta: .seconds(600), eligible: eligible.union(OnboardingStep.optionalByValue))
        #expect(flow.current == .invite)
        flow = flow.advancing(eta: .seconds(600), eligible: eligible.union(OnboardingStep.optionalByValue))
        flow = flow.advancing(eta: .seconds(600), eligible: eligible.union(OnboardingStep.optionalByValue))
        flow = flow.advancing(eta: .seconds(600), eligible: eligible.union(OnboardingStep.optionalByValue))
        #expect(flow.sequence.prefix(4) == [.welcome, .invite, .microphone, .accessibility])
        #expect(flow.current == .hotkeyPractice)
        #expect(flow.sequence.contains(.tryIt))
    }
}
