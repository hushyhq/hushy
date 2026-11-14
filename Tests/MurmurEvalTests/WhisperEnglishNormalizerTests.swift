import Foundation
import Testing

@testable import murmur_eval
@testable import MurmurCore

/// Pins the Swift port of Whisper's `EnglishTextNormalizer` to the Python original. Every
/// expected string below was produced by `whisper/normalizers/english.py` (openai/whisper main,
/// fetched 2026-09-27), not written by hand — regenerate them from Python, never edit to make a
/// test pass. The full-corpus agreement check is described in docs/product/US-ENGLISH-ACCURACY.md.
@Suite("Whisper English normaliser (port)")
struct WhisperEnglishNormalizerTests {
    static let pythonReference: [(String, String)] = [
        ("Hello, World!", "hello world"),
        ("It's 3:30 PM on March 5th, 2024.", "it is 3 30 pm on march 5th 2024"),
        ("one hundred and five dollars", "$105"),
        ("twenty three thousand five hundred", "23500"),
        ("one oh one", "101"),
        ("double seven", "77"),
        ("three point one four", "3.14"),
        ("twelve point five percent", "12.5%"),
        ("$20 million", "$20000000"),
        ("five dollars and twenty cents", "$5.20"),
        ("the 1960s", "the 1960s"),
        ("twenty first century", "21st century"),
        ("nineteen ninety nine", "1999"),
        ("two and a half", "2.5"),
        ("Mr. Smith and Dr. Jones went to St. Louis", "mister smith and doctor jones went to saint louis"),
        ("I can't won't don't he's been she's got", "i can not will not do not he has been she has got"),
        ("um uh hmm mm the colour of the centre", "the color of the center"),
        ("e-mail check-in co-op", "e mail check in co op"),
        ("[laughter] (inaudible) <noise> hi", "hi"),
        ("café naïve résumé Œuvre straße", "cafe naive resume oeuvre strasse"),
        ("O.K. okay OK", "0 k okay ok"),
        ("It's 10:00 a.m.", "it is 10 0 a m"),
        ("call 415-555-0198", "call 415 555 198"),
        ("ninth tenth eleventh", "ninth 10th 11th"),
        ("first second third", "1st 2nd 3rd"),
        ("minus five degrees", "-5 degrees"),
        ("ten per cent", "10%"),
        ("one", "one"),
        ("ones and twos", "ones and 2s"),
        ("I have 1 apple", "i have one apple"),
        ("$1.50 and 1.5 and 3.1", "$1.50 and 1.5 and 3.1"),
        ("£5 €10 ¢7", "£5 €10.07"),
        ("the year two thousand and twenty", "the year 2020"),
        ("zero zero seven", "007"),
        ("sixty five percent", "65%"),
        ("1,250 dollars", "$1250"),
        ("version 2.3.1", "version 2.3.1"),
        ("a hundred people", "a 100 people"),
        ("hundreds of millions", "100s of 1000000s"),
        ("Ships 24/7 & returns 100%", "ships 24 7 returns 100%"),
        ("we're they'll you've I'm y'all gonna wanna gotta", "we are they will you have i am you all going to want to got to"),
        ("The U.S.A. is big.", "the u s a is big"),
        ("twenty twenty-five", "2025"),
        ("four hundred and twelve", "412"),
        ("seven eighths", "7 eighths"),
        ("a quarter past nine", "a quarter past 9"),
    ]

    @Test func matchesThePythonReferenceOnEveryProbe() {
        for (input, expected) in Self.pythonReference {
            #expect(WhisperEnglishNormalizer.normalize(input) == expected, "input: \(input)")
        }
    }

    @Test func spellingMapIsTheFullUpstreamList() {
        #expect(BritishAmericanSpellings.map.count == BritishAmericanSpellings.count)
        #expect(BritishAmericanSpellings.map["colour"] == "color")
        #expect(BritishAmericanSpellings.map["aeroplane"] == "airplane")
    }

    @Test func corpusWERSkipsReferencesThatNormaliseToNothing() {
        // "[noise]" normalises to "", so that pair contributes no words (leaderboard behaviour).
        let pairs = [("the cat sat", "the cat sat"), ("[noise]", "hello"), ("one two", "1 3")]
        let totals = WhisperEnglishNormalizer.editTotals(pairs)
        #expect(totals.words == 4)
        // "one two" -> "12", "1 3" -> "1 3": one substitution plus one insertion; the first pair has none.
        #expect(totals.edits == 2)
        #expect(abs(WhisperEnglishNormalizer.corpusWER(pairs) - 0.5) < 1e-9)
    }

    @Test func numberFormattingDifferencesStillCountUnderWhisperRules() {
        // Documented behaviour, not a bug: the normaliser does not reconcile clock times.
        #expect(WhisperEnglishNormalizer.words("three thirty") == ["330"])
        #expect(WhisperEnglishNormalizer.words("3:30") == ["3", "30"])
    }
}
