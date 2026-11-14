import Foundation
import Testing
@testable import Murmur

/// The pill's latency choreography (docs/design/DESIGN-LANGUAGE.md §3.1): real processing stages,
/// the wet → dry ink preview, and the afterglow peak ghosts.
@Suite("Pill model — processing stages, ink preview, afterglow")
@MainActor
struct PillChoreographyTests {
    @Test("entering processing starts at Hearing with no ink")
    func startsAtHearing() {
        let pill = PillModel()
        pill.state = .processing()
        #expect(pill.processingStage == .hearing)
        #expect(pill.ink == nil)
    }

    @Test("raw words appear as wet ink while polishing, cleaned words as dry ink while typing")
    func wetThenDry() {
        let pill = PillModel()
        pill.state = .processing()
        pill.advance(to: .polishing, ink: " so um ship it friday no thursday ")
        #expect(pill.processingStage == .polishing)
        #expect(pill.ink == PillModel.Ink(text: "so um ship it friday no thursday", isDry: false))
        pill.advance(to: .typing, ink: "Ship it Thursday.")
        #expect(pill.processingStage == .typing)
        #expect(pill.ink == PillModel.Ink(text: "Ship it Thursday.", isDry: true))
    }

    @Test("stages never go backwards within one run")
    func monotonic() {
        let pill = PillModel()
        pill.state = .processing()
        pill.advance(to: .typing, ink: "Done.")
        pill.advance(to: .polishing, ink: "late raw words")
        #expect(pill.processingStage == .typing)
        #expect(pill.ink?.text == "Done.")
    }

    @Test("a transform mode can advance without ink, keeping its Applying label")
    func noInkForTransform() {
        let pill = PillModel()
        pill.state = .processing(modeName: "Email")
        pill.advance(to: .polishing, ink: nil)
        #expect(pill.processingStage == .polishing)
        #expect(pill.ink == nil)
    }

    @Test("advancing outside processing is ignored")
    func ignoredWhenNotProcessing() {
        let pill = PillModel()
        pill.state = .listening
        pill.advance(to: .polishing, ink: "hello")
        #expect(pill.processingStage == .hearing)
        #expect(pill.ink == nil)
    }

    @Test("leaving processing clears the ink, and the next run starts fresh")
    func clearsOnExit() {
        let pill = PillModel()
        pill.state = .processing()
        pill.advance(to: .typing, ink: "Hello.")
        pill.state = .done(words: 1)
        #expect(pill.ink == nil)
        pill.state = .processing()
        #expect(pill.processingStage == .hearing)
        #expect(pill.ink == nil)
    }

    @Test("re-assigning processing mid-run keeps the stage")
    func processingToProcessingKeepsStage() {
        let pill = PillModel()
        pill.state = .processing()
        pill.advance(to: .polishing, ink: "words")
        pill.state = .processing()
        #expect(pill.processingStage == .polishing)
        #expect(pill.ink?.text == "words")
    }

    @Test("ink keeps only the tail of a long transcript")
    func inkTail() {
        let pill = PillModel()
        pill.state = .processing()
        let long = String(repeating: "word ", count: 100) + "the end"
        pill.advance(to: .polishing, ink: long)
        #expect(pill.ink?.text.count == PillModel.inkPreviewLimit)
        #expect(pill.ink?.text.hasSuffix("the end") == true)
    }

    @Test("empty text shows no ink")
    func emptyInk() {
        let pill = PillModel()
        pill.state = .processing()
        pill.advance(to: .polishing, ink: "   ")
        #expect(pill.ink == nil)
    }

    @Test("afterglow decays to about 5% over the cool duration")
    func peakDecay() {
        let ticks = Int((Theme.Motion.coolDuration / 0.03).rounded())
        let remaining = pow(PillModel.peakDecayPerTick, Double(ticks))
        #expect(remaining < 0.06)
        #expect(remaining > 0.02)
    }

    @Test("setLevels without peaks puts the ghosts on the bars; reset clears both")
    func peaksFollowLevels() {
        let pill = PillModel()
        pill.setLevels([0.2, 0.5])
        #expect(pill.peaks == [0.2, 0.5])
        pill.setLevels([0.1, 0.1], peaks: [0.9, 0.8])
        #expect(pill.peaks == [0.9, 0.8])
        pill.resetLevels()
        #expect(pill.peaks.allSatisfy { $0 == 0 })
    }

    @Test("stage labels say what is happening")
    func labels() {
        #expect(PillModel.ProcessingStage.hearing.label == "Hearing")
        #expect(PillModel.ProcessingStage.polishing.label == "Polishing")
        #expect(PillModel.ProcessingStage.typing.label == "Typing")
    }

    @Test("motion stagger is capped")
    func staggerCap() {
        #expect(Theme.Motion.staggerDelay(0) == 0)
        #expect(Theme.Motion.staggerDelay(100) == Theme.Motion.staggerDelay(Theme.Motion.staggerCap))
        #expect(Theme.Motion.staggerDelay(-1) == 0)
    }
}

/// 2026-09-27 pill-wait report: wet ink next to the waveform read as the finished text, so a slow
/// cleanup looked like a stuck paste, and a model timeout pasted the rules text as if polished.
@Suite("Pill honesty — Polishing label and as-heard paste")
@MainActor
struct PillHonestyTests {
    @Test("wet ink carries the Polishing label; dry ink and no ink don't")
    func polishingLabelFollowsWetInk() {
        let pill = PillModel()
        pill.state = .processing()
        #expect(!PillInkLabel.showsPolishingLabel(for: pill.ink))
        pill.advance(to: .polishing, ink: "so um ship it friday")
        #expect(PillInkLabel.showsPolishingLabel(for: pill.ink))
        pill.advance(to: .typing, ink: "Ship it Friday.")
        #expect(!PillInkLabel.showsPolishingLabel(for: pill.ink))
    }

    @Test("a speed fallback goes polishing → typing → done as heard; a polished paste is plain done")
    func asHeardDone() {
        let pill = PillModel()
        pill.state = .processing()
        pill.advance(to: .polishing, ink: "so um ship it friday")
        pill.advance(to: .typing, ink: "So ship it Friday.")
        #expect(pill.ink == PillModel.Ink(text: "So ship it Friday.", isDry: true))
        pill.state = .done(words: 4, asHeard: true)
        #expect(pill.ink == nil)
        #expect(pill.state == .done(words: 4, usedContext: false, asHeard: true))
        #expect(PillState.done(words: 4) == .done(words: 4, usedContext: false, asHeard: false))
        #expect(PillState.done(words: 4) != .done(words: 4, asHeard: true))
    }
}
