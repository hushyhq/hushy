import Testing
@testable import MurmurCore

@Suite("InverseTextNormalizer")
struct InverseTextNormalizerTests {
    @Test("cardinals ten and up become digits in prose", arguments: [
        ("Set the timer for twenty-five minutes.", "Set the timer for 25 minutes."),
        ("Set the timer for twenty five minutes.", "Set the timer for 25 minutes."),
        ("There were thirty people at the meeting.", "There were 30 people at the meeting."),
        ("We need four hundred and twelve chairs.", "We need 412 chairs."),
    ])
    func cardinalsBecomeDigits(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("small cardinals one through nine stay as words in plain prose", arguments: [
        "I have three cats.",
        "We ordered two pizzas for the party.",
        "There are nine planets in the old model.",
        "Give me five minutes.",
    ])
    func smallCardinalsStayWords(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("money converts to a dollar sign", arguments: [
        ("Four hundred and twelve dollars and it's ours.", "$412 and it's ours."),
        ("The budget is six hundred dollars.", "The budget is $600."),
        ("It cost three dollars and fifty cents.", "It cost $3.50."),
        ("Pay the seventy five dollars today.", "Pay the $75 today."),
    ])
    func money(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("percentages convert with a percent sign", arguments: [
        ("Conversion improved by fifteen percent.", "Conversion improved by 15%."),
        ("Sales grew twelve point five percent.", "Sales grew 12.5%."),
    ])
    func percentages(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("versions convert to dotted digits", arguments: [
        ("We shipped version two point three point one.", "We shipped version 2.3.1."),
        ("Please upgrade to version two.", "Please upgrade to version 2."),
    ])
    func versions(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("decimals convert with a dot", arguments: [
        ("Set the threshold to three point five.", "Set the threshold to 3.5."),
        ("It weighs zero point zero five kilograms.", "It weighs 0.05 kilograms."),
    ])
    func decimals(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("clock times convert when the context marks them as a time", arguments: [
        ("Call me at three thirty this afternoon.", "Call me at 3:30 this afternoon."),
        ("Let's meet at nine fifteen in the morning.", "Let's meet at 9:15 in the morning."),
        ("The call is at ten am.", "The call is at 10:00am."),
        ("Ping me at nine p.m. tonight.", "Ping me at 9:00pm tonight."),
    ])
    func clockTimes(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("ambiguous number phrases without a time cue are left as words", arguments: [
        "We need three thirty of them.",
        "Half past two works for me.",
    ])
    func ambiguousTimesUntouched(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("ordinal dates normalize to Month Day", arguments: [
        ("Let's ship on the twenty third of March.", "Let's ship on March 23."),
        ("The deadline is March the twenty third.", "The deadline is March 23."),
        ("It happens on the first of May.", "It happens on May 1."),
    ])
    func ordinalDates(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("phone-like digit runs convert to a hyphenated number")
    func phoneLikeSequences() {
        let result = InverseTextNormalizer.apply("Call me at five five five one two three four five six seven.")
        #expect(result == "Call me at 555-123-4567.")
    }

    @Test("idioms and fixed phrases are left untouched", arguments: [
        "That's one of the best ideas I've heard.",
        "On the one hand, it's cheaper.",
        "It's a hundred times better now.",
        "Seven Eleven is on the corner.",
    ])
    func idiomsUntouched(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("numbers already written as digits are left untouched", arguments: [
        "The invoice total is $1,250 due Friday.",
        "Conversion improved by 12.5% after the change.",
        "Please upgrade to v2.3.1 before the demo.",
        "Let's push the call to 9:30am tomorrow.",
    ])
    func alreadyDigitsUntouched(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("code, URLs and identifiers are left untouched", arguments: [
        "Run the script with --dry-run first to be safe.",
        "Email ada@example.com when the build is ready.",
        "Open https://example.com/docs for the setup guide.",
    ])
    func technicalStringsUntouched(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }
}

@Suite("TextCleaner + InverseTextNormalizer integration")
struct TextCleanerITNIntegrationTests {
    let cleaner = TextCleaner()

    @Test("ITN examples from real dictation convert as expected", arguments: [
        ("Set the timer for twenty-five minutes.", "Set the timer for 25 minutes."),
        ("Call me at three thirty this afternoon.", "Call me at 3:30 this afternoon."),
        ("Version two point three point one.", "Version 2.3.1."),
        ("Four hundred and twelve dollars.", "$412."),
        ("Fifteen percent.", "15%."),
    ])
    func realDictationExamples(input: String, expected: String) {
        #expect(cleaner.clean(input).text == expected)
    }

    @Test("a spoken version number is never turned into a list by ListFormatter")
    func versionNeverBecomesList() {
        let result = cleaner.clean("We shipped version two point three point one.")
        #expect(result.text == "We shipped version 2.3.1.")
        #expect(!result.text.contains("\n"))
        #expect(!result.text.contains("- "))
    }

    @Test("verbatim level does not apply ITN")
    func verbatimSkipsITN() {
        let verbatim = TextCleaner(options: CleanupOptions(level: .verbatim))
        #expect(verbatim.clean("Set the timer for twenty five minutes.").text == "Set the timer for twenty five minutes.")
    }

    @Test("ITN still lets self-correction resolve number corrections")
    func itnDoesNotBreakSelfCorrection() {
        #expect(cleaner.clean("Let's meet at 10, no, 9 tomorrow.").text == "Let's meet at 9 tomorrow.")
        #expect(cleaner.clean("Call me at three, no, four, no, five.").text == "Call me at five.")
    }
}

@Suite("ListFormatter point-sequence guard")
struct ListFormatterPointGuardTests {
    @Test("a colon-introduced decimal/version reading is never turned into a list", arguments: [
        "We shipped version two: point three point one",
        "The setting is three: point five",
        "It's version two, point three, point one",
    ])
    func decimalSequencesNeverBecomeLists(input: String) {
        let result = ListFormatter.format(input)
        #expect(!result.contains("\n- "))
        #expect(!result.contains("\n1. "))
    }
}

@Suite("ListFormatter splitInlineBullets point guard")
struct SplitInlineBulletsPointGuardTests {
    @Test("a model-emitted decimal/version dash-list line is not treated as a real list")
    func modelEmittedPointListIsRejoined() {
        let input = "Mission version two: - Point three - Point one"
        let result = ListFormatter.splitInlineBullets(input)
        #expect(!result.contains("\n- "), "got: \(result)")
    }
}

@Suite("ListFormatter ordinal bounds")
struct ListFormatterOrdinalBoundsTests {
    @Test("more ordinal markers than the table holds never traps")
    func longOrdinalRunDoesNotTrap() {
        // 11 markers whose first ten are in order: the old code indexed ordinals[10].
        let input = "First, one. Second, two. Third, three. Fourth, four. Fifth, five. Sixth, six. Seventh, seven. Eighth, eight. Ninth, nine. Tenth, ten. First, again."
        let result = ListFormatter.format(input)
        #expect(!result.contains("\n11. "))
    }
}

@Suite("InverseTextNormalizer overflow")
struct InverseTextNormalizerOverflowTests {
    @Test("absurdly large spoken numbers are left as words instead of overflowing")
    func rejectsOverflow() {
        let phrase = Array(repeating: "hundred", count: 12).joined(separator: " ")
        #expect(InverseTextNormalizer.parseCardinal(phrase) == nil)
        #expect(InverseTextNormalizer.parseCardinal("nine hundred billion billion billion") == nil)
        let text = "We counted \(phrase) stars."
        #expect(InverseTextNormalizer.apply(text) == text)
    }

    @Test("a scale word on its own stays a word (was \"$4.5 1,000,000\", \"a 100 tries\")", arguments: [
        ("We raised $4.5 million in the seed round.", "We raised $4.5 million in the seed round."),
        ("Revenue passed 2 billion last year.", "Revenue passed 2 billion last year."),
        ("It took a hundred tries.", "It took a hundred tries."),
        ("A thousand thanks.", "A thousand thanks."),
        ("We need four hundred and twelve chairs.", "We need 412 chairs."),
        ("About two million people.", "About 2,000,000 people."),
    ])
    func bareScaleWordsStayWords(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("dotted clock times become colon times only with a time cue", arguments: [
        ("Let's meet at 3.30 on Thursday in room B.", "Let's meet at 3:30 on Thursday in room B."),
        ("My flight leaves at 6.45 in the morning.", "My flight leaves at 6:45 in the morning."),
        ("Call me after 5.15 pm.", "Call me after 5:15 pm."),
        ("Be there by 9.05 tomorrow.", "Be there by 9:05 tomorrow."),
        ("The stock closed at 3.30.", "The stock closed at 3.30."),
        ("Upgrade to 2.10 today.", "Upgrade to 2.10 today."),
        ("It costs 3.30 on Thursday.", "It costs 3.30 on Thursday."),
        ("Meet at 13.30 on Friday.", "Meet at 13.30 on Friday."),
    ])
    func dottedClockTimes(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }
}

/// One range or alternative is one quantity, so its numbers share a style: a number below ten next to one from
/// ten up is written as digits too, instead of "five to 10".
@Suite("Range numerals share a style")
struct RangeNumeralTests {
    @Test("a small number beside a large one in a range becomes digits", arguments: [
        ("We expect five to ten people.", "We expect 5 to 10 people."),
        ("It takes three or fifteen minutes.", "It takes 3 or 15 minutes."),
        ("Between twelve or four hundred rows.", "Between 12 or 400 rows."),
        ("We need nine to fifteen volunteers.", "We need 9 to 15 volunteers."),
        ("About thirty or four people came.", "About 30 or 4 people came."),
        ("It took a hundred to hundred and fifty milliseconds.", "It took 100 to 150 milliseconds."),
        ("We saw a thousand to two thousand requests.", "We saw 1,000 to 2,000 requests."),
        ("Plan on fifty to a hundred people.", "Plan on 50 to 100 people."),
        ("Each batch holds ten to a hundred records.", "Each batch holds 10 to 100 records."),
        ("It costs two to three hundred dollars a month.", "It costs $200 to $300 a month."),
        ("Budget five to ten thousand dollars for the booth.", "Budget $5,000 to $10,000 for the booth."),
        ("It runs six or seven hundred dollars per seat.", "It runs $600 or $700 per seat."),
        ("Expect twenty to thirty thousand visitors.", "Expect 20,000 to 30,000 visitors."),
        ("The team estimates two to three hundred hours.", "The team estimates 200 to 300 hours."),
        ("Twenty five to thirty thousand dollars is the range.", "$25,000 to $30,000 is the range."),
        ("We expect a hundred or a hundred and twenty guests.", "We expect 100 or 120 guests."),
        ("It held a hundred to a hundred and fifty jobs.", "It held 100 to 150 jobs."),
        ("About a thousand or twelve hundred people signed up.", "About 1,000 or 1,200 people signed up."),
    ])
    func mixedRangeBecomesDigits(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("the scale word goes to the first end only when it makes a range of like magnitudes", arguments: [
        ("two to three hundred", "two hundred to three hundred"),
        ("five to ten thousand", "five thousand to ten thousand"),
        ("Twenty five to thirty thousand", "Twenty five thousand to thirty thousand"),
        ("one to one hundred", "one to one hundred"),
        ("one to two hundred", "one to two hundred"),
        ("five to three hundred", "five to three hundred"),
        ("three to three hundred", "three to three hundred"),
        ("a hundred to one odds", "a hundred to one odds"),
        ("ten to five", "ten to five"),
    ])
    func scaleIsSharedOnlyForLikeMagnitudes(input: String, expected: String) {
        #expect(InverseTextNormalizer.shareScaleInRange(input) == expected)
    }

    @Test("a count that starts at one is not a range of like magnitudes", arguments: [
        ("Count from one to one hundred.", "Count from 1 to 100."),
        ("We need one to two hundred seats.", "We need 1 to 200 seats."),
        ("They gave it a hundred to one odds.", "They gave it a hundred to one odds."),
        ("Expect five to ten thousand visitors.", "Expect 5,000 to 10,000 visitors."),
    ])
    func countFromOne(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("a range in two different currencies is left alone", arguments: [
        "The range is \u{20AC}10 to $20.",
        "The range is \u{00A3}10 or $20.",
    ])
    func twoCurrenciesStay(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("two small numbers stay words", arguments: [
        "It takes three or four weeks.",
        "We need two to three people.",
    ])
    func smallPairStays(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("a scale word that is not in a range stays a word", arguments: [
        "We had a hundred or so people.", "It is a hundred times better.", "A thousand thanks to the team.",
    ])
    func scaleWordAloneStays(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("the pronoun one after a determiner is not a number")
    func pronounOneStays() {
        #expect(InverseTextNormalizer.apply("Pick the one or twelve of them.") == "Pick the one or 12 of them.")
    }
}
