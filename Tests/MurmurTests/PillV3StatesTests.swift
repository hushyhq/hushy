import Foundation
import Testing
@testable import Murmur

/// The founder-approved dictation states (design v3, 2026-10-04): Listening, Hands-free,
/// Writing and Done. Everything here is pure — timing, copy and sizes — so no window is needed.
@Suite("Pill v3 — dictation states")
@MainActor
struct PillV3StatesTests {
    // MARK: Writing

    @Test("Writing shows only the dots for the first second")
    func dotsFirst() {
        #expect(WritingPhase.phase(after: 0) == .dots)
        #expect(WritingPhase.phase(after: 0.99) == .dots)
        #expect(WritingPhase.dots.label == nil)
    }

    @Test("the Writing label appears at 1 s and becomes Still writing at 5 s")
    func labelTimings() {
        #expect(WritingPhase.phase(after: 1) == .writing)
        #expect(WritingPhase.phase(after: 4.99) == .writing)
        #expect(WritingPhase.phase(after: 5) == .stillWriting)
        #expect(WritingPhase.phase(after: 60) == .stillWriting)
        #expect(WritingPhase.writing.label == "Writing…")
        #expect(WritingPhase.stillWriting.label == WritingPhase.stillWritingMessage)
        #expect(WritingPhase.label(after: 1, ink: nil) == "Writing…")
        #expect(WritingPhase.label(after: 2, ink: "meet at nine and bring the deck tomorrow morning")
            == "the deck tomorrow morning")
        #expect(WritingPhase.label(after: 5, ink: "bring the deck") == WritingPhase.stillWritingMessage)
        #expect(WritingPhase.preview("  ") == nil)
    }

    @Test("a negative elapsed time (clock skew) is still the dots")
    func negativeElapsed() {
        #expect(WritingPhase.phase(after: -3) == .dots)
    }

    @Test("entering processing stamps its start; leaving clears it")
    func processingStart() {
        let pill = PillModel()
        #expect(pill.processingStartedAt == nil)
        pill.state = .processing()
        let first = pill.processingStartedAt
        #expect(first != nil)
        // A mode name arriving mid-run is the same run: the clock keeps going.
        pill.state = .processing(modeName: "Email")
        #expect(pill.processingStartedAt == first)
        pill.state = .done(words: 3)
        #expect(pill.processingStartedAt == nil)
    }

    @Test("the user never sees Hearing, Polishing or Typing — not even through VoiceOver")
    func internalStagesStayInternal() {
        let pill = PillModel()
        pill.state = .processing()
        for stage: PillModel.ProcessingStage in [.hearing, .polishing, .typing] {
            pill.advance(to: stage, ink: "raw words")
            #expect(pill.accessibilityLabel == "Writing")
        }
        pill.state = .processing(modeName: "Email")
        #expect(pill.accessibilityLabel == "Writing")
    }

    // MARK: Hands-free timer

    @Test("the hands-free timer reads m:ss")
    func elapsedFormat() {
        #expect(ElapsedTime.format(seconds: 0) == "0:00")
        #expect(ElapsedTime.format(seconds: 9) == "0:09")
        #expect(ElapsedTime.format(seconds: 42) == "0:42")
        #expect(ElapsedTime.format(seconds: 724) == "12:04")
        #expect(ElapsedTime.format(seconds: 3_665) == "61:05")
        #expect(ElapsedTime.format(seconds: -2) == "0:00")
    }

    // MARK: Done

    @Test("Done says nothing for a short result and the count from 20 words")
    @MainActor
    func doneParts() {
        #expect(PillModel.doneParts(words: 4, asHeard: false, notSent: false).isEmpty)
        #expect(PillModel.doneParts(words: 19, asHeard: false, notSent: false).isEmpty)
        #expect(PillModel.doneParts(words: 20, asHeard: false, notSent: false) == ["20 words"])
        #expect(PillModel.doneParts(words: 142, asHeard: false, notSent: false) == ["142 words"])
    }

    @Test("as heard and a withheld Return still say so")
    @MainActor
    func doneQualifiers() {
        #expect(PillModel.doneParts(words: 4, asHeard: true, notSent: false) == ["quick cleanup only"])
        #expect(PillModel.doneParts(words: 142, asHeard: true, notSent: true) == ["quick cleanup only", "Return not pressed"], "Pasted stands in for the count")
        #expect(PillModel.doneParts(words: 4, asHeard: true, notSent: false, notARewrite: true) == ["as heard"])
    }

    @Test("a withheld Return reads as pasted, with only Return not pressed")
    @MainActor
    func doneLineForWithheldReturn() {
        #expect(PillModel.doneLine(words: 4, asHeard: false, notSent: false) == nil, "a short clean paste is the ✓ alone")
        #expect(PillModel.doneLine(words: 142, asHeard: false, notSent: false) == "142 words")
        #expect(PillModel.doneLine(words: 4, asHeard: false, notSent: true) == "Pasted · Return not pressed")
        #expect(PillModel.doneLine(words: 42, asHeard: true, notSent: true) == "Pasted · quick cleanup only · Return not pressed")
        #expect(PillModel.doneLine(words: 4, asHeard: true, notSent: false) == PillModel.quickCleanupLine)
        #expect(PillModel.doneLine(words: 42, asHeard: true, notSent: true, notARewrite: true) == "Pasted · as heard · Return not pressed")
        #expect(PillPanel.size(for: .done(words: 42, asHeard: true, notSent: true)) == PillPanel.rowSize, "room for the longer line")
        #expect(PillPanel.size(for: .done(words: 4, asHeard: true)) == PillPanel.rowSize)
        #expect(PillPanel.size(for: .done(words: 42)) == PillPanel.size)
        let line = PillModel.doneLine(words: 4, asHeard: false, notSent: true) ?? ""
        #expect(!line.localizedCaseInsensitiveContains("not sent"), "“not sent” read as a failed paste")
        #expect(PillModel.doneExplanation(asHeard: false, notSent: true).hasPrefix("Your text was pasted."))
        #expect(PillModel.doneExplanation(asHeard: false, notSent: false).isEmpty)
        #expect(PillModel.doneExplanation(asHeard: true, notSent: false, notARewrite: true)
            == "A check protecting the meaning of what you said rejected the model’s rewrite.")
    }

    @Test("VoiceOver reads Pasted, with the count only from 20 words")
    func doneAccessibility() {
        let pill = PillModel()
        pill.state = .done(words: 4)
        #expect(pill.accessibilityLabel == "Pasted")
        pill.state = .done(words: 142)
        #expect(pill.accessibilityLabel == "Pasted, 142 words")
        pill.state = .done(words: 4, usedContext: true, asHeard: true, notSent: true)
        #expect(pill.accessibilityLabel == "Pasted, quick cleanup only, Return not pressed, using context from the screen")
        pill.state = .done(words: 4, asHeard: true, notARewrite: true)
        #expect(pill.accessibilityLabel == "Pasted, as heard")
        pill.state = .done(words: 4, notSent: true)
        #expect(pill.accessibilityLabel == "Pasted, Return not pressed", "the same words the pill draws")
    }

    // MARK: Sizes

    @Test("Listening is fixed while Hands-free and notes fit their contents")
    func metrics() {
        #expect(PillMetrics.listening == CGSize(width: 104, height: 32))
        #expect(PillMetrics.size(for: .listening) == PillMetrics.listening)
        #expect(PillMetrics.size(for: .handsFree(startedAt: Date())) == nil)
        #expect(PillMetrics.size(for: .recordingNote(startedAt: Date())) == nil)
        #expect(PillMetrics.size(for: .idle) == nil)
        #expect(PillMetrics.size(for: .processing()) == nil)
    }

    @Test("dictation bars are 3 pt wide with 3 pt gaps, up to 22 pt tall")
    func waveformMetrics() {
        #expect(WaveformMetrics.dictation.barWidth == 3)
        #expect(WaveformMetrics.dictation.spacing == 3)
        #expect(WaveformMetrics.dictation.frameHeight == 22)
        #expect(WaveformMetrics.dictation.minHeight + WaveformMetrics.dictation.maxExtra == 22)
        #expect(WaveformMetrics.standard.barWidth == 2.5, "other states keep their bars")
    }

    // MARK: Idle (design v3: five neutral marks, not the lime squiggle)

    @Test("the resting capsule is 40×10")
    func idleSize() {
        #expect(PillMetrics.idle == CGSize(width: 40, height: 10))
    }

    @Test("the idle glyph is dot, bar, dot, bar, dot — symmetric, and it fits the capsule")
    func idleMarks() {
        let marks = PillIdleMark.marks
        #expect(marks.count == 5)
        #expect(marks.map(\.height) == marks.reversed().map(\.height), "symmetric")
        #expect(marks[0] == marks[4] && marks[0].height <= marks[2].height, "outer dots are no bigger than the middle one")
        #expect(marks[1].height > marks[2].height && marks[1] == marks[3], "the two bars are the tall marks")
        #expect(marks.allSatisfy { $0.height <= PillMetrics.idle.height - 2 }, "clear of the capsule edge")
        #expect(PillIdleMark.length + 2 * PillIdleMark.endPadding == PillMetrics.idle.width)
    }

    @Test("the idle glyph uses a theme token, not a lime or yellow")
    func idleTint() {
        #expect(PillIdleMark.tint == Theme.pillIdleMark)
        #expect(Theme.pillIdleMark != Theme.phosphorFill)
    }
}
