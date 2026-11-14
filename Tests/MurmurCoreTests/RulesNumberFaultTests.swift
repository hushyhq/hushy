import Testing
@testable import MurmurCore

/// The rules pass must never hand the model a number the speaker did not say. Two things did: the
/// one-word repair (`FragmentRepair`) swapped a single word of a spoken number ("five hundred dollars no wait
/// five thousand dollars" became "five hundred five thousand dollars", then "$505,000"), and the number
/// pass split a compound ordinal ("the twenty eighth" became "the 20 eighth").
@Suite("Rules pass keeps spoken numbers whole")
struct RulesNumberFaultTests {
    let cleaner = TextCleaner()

    // MARK: A one-word repair does not cut a number phrase

    @Test("a repair that would swap one word of a multi-word number is left for the model", arguments: [
        "send two hundred and fifty units no i mean two hundred and sixty units to the warehouse by friday",
        "the call is at three forty five no sorry four forty five pacific",
        "the deposit is five hundred dollars no wait five thousand dollars",
        "the budget for the event is eighteen thousand sorry eighty thousand which includes the venue",
        "the label should say batch twenty three oops batch twenty four before it goes to print",
        "set the address to ten dot zero dot one dot forty two no sorry forty four then restart the router",
        "the dashboard listens on port eight thousand eighty no sorry port eight thousand ninety",
        "the batch has twenty one items no wait twenty two items still waiting for review",
        "churn dropped by twelve percent no wait twenty percent after the pricing change",
        "the invoice is for eight hundred and twelve dollars i mean eight hundred and twenty dollars and it is due friday",
        "the flight lands at eleven oh five no wait eleven fifty five so the shuttle should be booked later",
    ])
    func numberPhraseIsLeftAlone(text: String) {
        #expect(FragmentRepair.apply(text) == text)
    }

    @Test("a single number word swapped for a single number word, and a plain word swapped for a word, still resolve")
    func singleWordRepairsStillResolve() {
        #expect(FragmentRepair.apply("set the timer to six sorry seven minutes") == "set the timer to seven minutes")
        #expect(FragmentRepair.apply("we meet on the third oops fourth") == "we meet on the fourth")
        #expect(FragmentRepair.apply("the reviewer is dana no sorry elif for this change") == "the reviewer is elif for this change")
    }

    @Test("a number swapped for a word, or a word for a number, is not a one-word repair")
    func mixedKindsAreLeftAlone() {
        #expect(FragmentRepair.apply("we shipped it in six months sorry seven") == "we shipped it in six months sorry seven")
        #expect(FragmentRepair.apply("the fee is ten dollars sorry fifty") == "the fee is ten dollars sorry fifty")
    }

    @Test("the whole rules pass keeps both numbers and the cue, and builds no third number from them")
    func rulesDraftHasNoUnsaidNumber() {
        let cases: [(String, [String], [String])] = [
            ("send two hundred and fifty units no i mean two hundred and sixty units to the warehouse by friday", ["250", "260"], ["25,260", "25,0260"]),
            ("the deposit is five hundred dollars no wait five thousand dollars", ["$500", "$5,000"], ["505,000"]),
            ("reimburse me two hundred and forty dollars no i mean two hundred and fourteen dollars for the train tickets", ["$240", "$214"], ["24,214"]),
            ("the venue holds two hundred and fifty people no wait three hundred and fifty people so it works", ["250", "350"], ["25,350"]),
            ("the label should say batch twenty three oops batch twenty four before it goes to print", ["23", "24"], ["batch 20 batch"]),
        ]
        for (spoken, kept, absent) in cases {
            let output = cleaner.clean(spoken).text
            for piece in kept { #expect(output.contains(piece), "\(piece) missing: \(output)") }
            for piece in absent { #expect(!output.contains(piece), "\(piece) present: \(output)") }
        }
    }

    // MARK: A compound ordinal is one number

    @Test("a compound ordinal after the, after a month or before of is one number", arguments: [
        ("payroll closes on the twenty sixth so submit your hours", "the 26th"),
        ("we ship on the thirty first of october", "October 31"),
        ("the review is on march twenty eighth at noon", "March 28 at noon"),
        ("the review is on march the twenty eighth at noon", "March 28 at noon"),
        ("the move is on the twenty second of next month", "the 22nd of next month"),
        ("the party is on the twenty first of march", "March 21"),
        ("she finished twenty sixth in the race", "26th in the race"),
        ("the twenty fifth anniversary dinner is booked", "25th anniversary"),
        ("the board meets on the twenty-third at ten", "the 23rd"),
    ])
    func compoundOrdinalIsOneNumber(spoken: String, expected: String) {
        let output = cleaner.clean(spoken).text
        #expect(output.contains(expected), "\(output)")
        for split in ["20 first", "20 second", "20 third", "20 fifth", "20 sixth", "20 eighth", "30 first", "20-third"] {
            #expect(!output.contains(split), "\(output)")
        }
    }

    @Test("second after a tens word is a time unit unless a month or of makes it a date")
    func secondIsATimeUnitWithoutADate() {
        #expect(cleaner.clean("set a twenty second timeout on the request").text.contains("20 second timeout"))
        #expect(cleaner.clean("the twenty second clip is the one we want").text.contains("20 second clip"))
        #expect(cleaner.clean("the review is on march twenty second at noon").text.contains("March 22 at noon"))
    }

    @Test("a fraction is not an ordinal: a number word before the compound and of after it leaves the phrase as the rules had it", arguments: [
        "we spent one twenty fifth of the budget on travel",
        "a twenty fifth of the budget went on travel",
        "she took three twenty fifth of the total",
    ])
    func fractionIsNotJoined(spoken: String) {
        let output = cleaner.clean(spoken).text
        #expect(!output.contains("25th"), "\(output)")
        #expect(output.contains("fifth of the"), "\(output)")
    }

    @Test("a count of ordinal-named things is a count, a rank, a possessive or a singular noun is an ordinal", arguments: [
        ("we need twenty first graders for the demo", "21st graders", false),
        ("hire thirty third years for the summer", "33rd years", false),
        ("we celebrated my twenty first birthday in june", "my 21st birthday", true),
        ("we watched the twenty first episode late", "the 21st episode", true),
        ("we booked the twenty sixth floor", "the 26th floor", true),
        ("the party is on twenty first street", "21st street", true),
        ("she came twenty sixth in the race", "26th in the race", true),
        ("they finished twenty fifth", "25th", true),
    ])
    func countIsNotJoined(spoken: String, joined: String, expected: Bool) {
        let output = cleaner.clean(spoken).text
        #expect(output.contains(joined) == expected, "\(output)")
    }

    @Test("one hundred and a compound ordinal is one ordinal, and a plain cardinal is unchanged", arguments: [
        ("the one hundred and twenty third floor is closed", "123rd floor"),
        ("she finished one hundred and twenty sixth", "126th"),
        ("it is the one hundred twenty fifth anniversary", "125th anniversary"),
    ])
    func hundredsAreOneOrdinal(spoken: String, expected: String) {
        let output = cleaner.clean(spoken).text
        #expect(output.contains(expected), "\(output)")
        #expect(!output.contains("100 and"), "\(output)")
    }

    @Test("hundreds before a count, a time unit or a cardinal are not made an ordinal")
    func hundredsNeighbours() {
        let count = cleaner.clean("we need one hundred and twenty first graders").text
        #expect(!count.contains("121st"), "\(count)")
        let unit = cleaner.clean("set a one hundred and twenty second timeout").text
        #expect(!unit.contains("122nd"), "\(unit)")
        #expect(cleaner.clean("it costs one hundred and twenty five dollars").text.contains("$125"))
    }

    @Test("cardinals, single ordinals and other dates read as before")
    func neighboursAreUnchanged() {
        #expect(cleaner.clean("it takes twenty five minutes").text.contains("25 minutes"))
        #expect(cleaner.clean("we ship on the twentieth").text.contains("twentieth"))
        #expect(cleaner.clean("the call is on the third of march").text.contains("March 3"))
        #expect(cleaner.clean("the meeting is on the twenty third of march").text.contains("March 23"))
        #expect(cleaner.clean("we need twelve first graders").text.contains("12 first graders"))
    }
}
