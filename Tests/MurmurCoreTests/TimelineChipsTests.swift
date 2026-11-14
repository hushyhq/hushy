import Foundation
import Testing
@testable import MurmurCore

@Suite("TimelineChips")
struct TimelineChipsTests {
    @Test("identical text produces no chips")
    func identicalTextNoChips() {
        let chips = TimelineChips.chips(rawText: "Let's meet at nine.", cleanedText: "Let's meet at nine.")
        #expect(chips.isEmpty)
    }

    @Test("empty raw text produces no chips")
    func emptyRawTextNoChips() {
        let chips = TimelineChips.chips(rawText: "", cleanedText: "Hello.")
        #expect(chips.isEmpty)
    }

    @Test("a single named filler produces a quoted-word chip")
    func singleFillerNamed() {
        let chips = TimelineChips.chips(rawText: "uh let's meet at nine", cleanedText: "let's meet at nine")
        #expect(chips == ["“uh” removed"])
    }

    @Test("multiple fillers produce a count chip, not named words")
    func multipleFillersCounted() {
        let chips = TimelineChips.chips(rawText: "um so let's meet at nine", cleanedText: "let's meet at nine")
        #expect(chips.contains("2 fillers removed"))
    }

    @Test("never produces a word-substitution chip like 'X to Y'")
    func neverProducesSubstitutionChip() {
        let chips = TimelineChips.chips(rawText: "let's meet tomorrow no wait nine", cleanedText: "let's meet at nine")
        for chip in chips {
            #expect(!chip.contains("→"))
        }
    }

    @Test("a removed non-filler word produces a correction chip")
    func nonFillerRemovalIsCorrection() {
        let chips = TimelineChips.chips(rawText: "call bob tomorrow please urgent", cleanedText: "call bob tomorrow please")
        #expect(chips.contains("1 correction"))
    }

    @Test("a number word becoming a digit adds a number chip")
    func numberWordToDigitAddsNumberChip() {
        let chips = TimelineChips.chips(rawText: "meet at nine tomorrow", cleanedText: "meet at 9 tomorrow")
        #expect(chips.contains("1 number"))
    }

    @Test("a self-correction run collapses to one correction event, not one per removed word")
    func selfCorrectionRunIsOneCorrection() {
        let chips = TimelineChips.chips(
            rawText: "Let's meet at ten, no, nine, and bring your laptop.",
            cleanedText: "Let's meet at 9 and bring your laptop.")
        #expect(chips.contains("1 correction"))
        #expect(!chips.contains(where: { $0.contains("2 correction") || $0.contains("3 correction") }))
    }

    @Test("two separate self-corrections give 2 corrections")
    func twoSeparateSelfCorrectionsGiveTwoCorrections() {
        let chips = TimelineChips.chips(
            rawText: "Call bob, actually sarah, at ten, no, nine.",
            cleanedText: "Call sarah at nine.")
        #expect(chips.contains("2 corrections"))
    }

    @Test("fillers only, with no correction cue, produce no correction chip")
    func fillersOnlyProduceNoCorrectionChip() {
        let chips = TimelineChips.chips(rawText: "um so let's meet at nine", cleanedText: "let's meet at nine")
        #expect(!chips.contains(where: { $0.contains("correction") }))
    }
}
