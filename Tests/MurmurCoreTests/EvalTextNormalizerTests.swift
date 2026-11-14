import Testing
@testable import MurmurCore

/// Unit tests for the Whisper/ESB-style ASR corpus normalizer (`EvalTextNormalizer`), covering
/// each principled normalization it applies symmetrically to reference and hypothesis text.
struct EvalTextNormalizerTests {
    @Test func numberWordsToDigits() {
        #expect(EvalTextNormalizer.normalizedWords("twenty three") == EvalTextNormalizer.normalizedWords("23"))
        #expect(EvalTextNormalizer.normalizedWords("one hundred and five") == EvalTextNormalizer.normalizedWords("105"))
        #expect(EvalTextNormalizer.normalizedWords("two thousand twenty four") == EvalTextNormalizer.normalizedWords("2024"))
        #expect(EvalTextNormalizer.normalizedWords("nine") == EvalTextNormalizer.normalizedWords("9"))
    }

    @Test func ordinalWordsToDigits() {
        #expect(EvalTextNormalizer.normalizedWords("the third floor") == EvalTextNormalizer.normalizedWords("the 3rd floor"))
    }

    @Test func contractionsExpand() {
        #expect(EvalTextNormalizer.normalizedWords("don't") == EvalTextNormalizer.normalizedWords("do not"))
        #expect(EvalTextNormalizer.normalizedWords("it's fine") == EvalTextNormalizer.normalizedWords("it is fine"))
        #expect(EvalTextNormalizer.normalizedWords("won't go") == EvalTextNormalizer.normalizedWords("will not go"))
        #expect(EvalTextNormalizer.normalizedWords("we're here") == EvalTextNormalizer.normalizedWords("we are here"))
        #expect(EvalTextNormalizer.normalizedWords("I'll call") == EvalTextNormalizer.normalizedWords("I will call"))
    }

    @Test func ukUSSpellingVariantsMatch() {
        #expect(EvalTextNormalizer.normalizedWords("favourite colour") == EvalTextNormalizer.normalizedWords("favorite color"))
        #expect(EvalTextNormalizer.normalizedWords("organised") == EvalTextNormalizer.normalizedWords("organized"))
        #expect(EvalTextNormalizer.normalizedWords("the theatre centre") == EvalTextNormalizer.normalizedWords("the theater center"))
    }

    @Test func hyphenationAndCompounds() {
        #expect(EvalTextNormalizer.normalizedWords("check-in") == EvalTextNormalizer.normalizedWords("check in"))
        #expect(EvalTextNormalizer.normalizedWords("well-known") == EvalTextNormalizer.normalizedWords("well known"))
    }

    @Test func fillersStrippedSymmetrically() {
        #expect(EvalTextNormalizer.normalizedWords("uh so let's meet") == EvalTextNormalizer.normalizedWords("so let's meet"))
        #expect(EvalTextNormalizer.normalizedWords("I um think so") == EvalTextNormalizer.normalizedWords("I think so"))
    }

    @Test func okayVariants() {
        #expect(EvalTextNormalizer.normalizedWords("okay let's go") == EvalTextNormalizer.normalizedWords("ok let's go"))
    }

    @Test func symbolsSpelledOut() {
        #expect(EvalTextNormalizer.normalizedWords("50% off") == EvalTextNormalizer.normalizedWords("50 percent off"))
        #expect(EvalTextNormalizer.normalizedWords("$5") == EvalTextNormalizer.normalizedWords("5 dollars"))
        #expect(EvalTextNormalizer.normalizedWords("cats & dogs") == EvalTextNormalizer.normalizedWords("cats and dogs"))
    }

    @Test func werUsesNormalizedTokens() {
        // "20%" vs "twenty percent" should be a perfect match under the new normalizer.
        #expect(EvalTextNormalizer.wer(reference: "20% off", hypothesis: "twenty percent off") == 0)
    }

    @Test func corpusWERAggregatesAcrossPairs() {
        let pairs: [(reference: String, hypothesis: String)] = [
            ("it's fine", "it is fine"),
            ("twenty three", "24"),
        ]
        // Second pair: 1 edit / 1 ref word (single-token numeric phrase) = 1.0; first pair: 0.
        // Aggregate: 1 edit over 3 reference words total ("it", "is", "fine" + "23").
        let wer = EvalTextNormalizer.corpusWER(pairs)
        #expect(wer > 0 && wer < 1)
    }

    @Test func doesNotAffectProductScoringNormalizer() {
        // EvalMetrics.normalizedWords (golden-set scoring) must remain unaffected by this file.
        #expect(EvalMetrics.normalizedWords("don't") == ["don't"])
    }
}
