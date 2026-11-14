import Foundation
import MurmurCore
import Testing
@testable import Murmur

@Suite("Brief no-words line")
@MainActor
struct BriefFailureTests {
    @Test("the brief line is one short line, makes no sound and has no detail")
    func words() {
        let heard = DictationFailure.missedWords(heardSpeech: true)
        #expect(heard.line == "Didn't catch any words")
        #expect(DictationFailure.missedWords(heardSpeech: false).line == "Didn't hear any words")
        #expect(heard.isBrief)
        #expect(!heard.playsErrorSound)
        #expect(!heard.canRetry)
        #expect(!DictationFailure.noWords.isBrief, "the hint rows still stay until dismissed")
        #expect(!DictationFailure.micSilent.isBrief)
    }

    @Test("the brief line leaves by itself, and a newer state is never touched")
    func leaves() async throws {
        let pill = PillModel()
        pill.present(failure: .missedWords(heardSpeech: true), briefFor: .milliseconds(40))
        #expect(pill.state == .failed(.missedWords(heardSpeech: true)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(pill.state == .idle)

        pill.present(failure: .missedWords(heardSpeech: false), briefFor: .milliseconds(40))
        pill.state = .listening
        try await Task.sleep(for: .milliseconds(150))
        #expect(pill.state == .listening)
    }

    @Test("a hint row does not leave by itself")
    func hintStays() async throws {
        let pill = PillModel()
        pill.present(failure: .heardNothing, briefFor: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(80))
        #expect(pill.state == .failed(.heardNothing))
    }
}
