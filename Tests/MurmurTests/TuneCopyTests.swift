import Foundation
import Testing

@testable import Murmur

/// A Tune run does not apply its winner to dictation, so no Tune text may say it picks, finds,
/// applies or improves settings.
@Suite("Tune copy claims only what a run does")
struct TuneCopyTests {
    private static let all: [String] = [
        TuneCopy.onboardingOffer, TuneCopy.settingsRowDetail, TuneCopy.intro, TuneCopy.stepRead,
        TuneCopy.stepRoom, TuneCopy.stepShow, TuneCopy.termsHint, TuneCopy.roomTone, TuneCopy.resultNote,
        TuneCopy.resultHeadline(passed: 3, total: 4),
    ]

    @Test("no promise to pick, find or improve settings", arguments: ["best settings", "picks", "find the best", "more accurate", "accuracy on your voice"])
    func noOverPromise(phrase: String) {
        for text in Self.all { #expect(!text.lowercased().contains(phrase)) }
    }

    @Test("the result says it changed nothing")
    func resultSaysUnchanged() {
        #expect(TuneCopy.resultNote.contains("didn’t change"))
    }

    @Test("headline counts sentences")
    func headline() {
        #expect(TuneCopy.resultHeadline(passed: 4, total: 4) == "Hushy got 4 of 4 sentences right")
    }

    @Test("the onboarding line names what a run does: misheard words and whisper level")
    func onboardingNamesWhatItDoes() {
        #expect(TuneCopy.onboardingOffer.contains("dictionary"))
        #expect(TuneCopy.onboardingOffer.contains("whispering"))
    }
}
