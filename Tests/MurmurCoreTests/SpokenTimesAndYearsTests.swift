import Testing
@testable import MurmurCore

@Suite("Spoken times and years")
struct SpokenTimesAndYearsTests {
    @Test("a cue needs a temporal continuation, except for oh minutes", arguments: [
        ("Meet at ten thirty today.", "Meet at 10:30 today."),
        ("Send it by two thirty tomorrow.", "Send it by 2:30 tomorrow."),
        ("Wait until three forty five on Monday.", "Wait until 3:45 on Monday."),
        ("Arrive till four oh five.", "Arrive till 4:05."),
        ("Call around eleven fifteen this evening.", "Call around 11:15 this evening."),
        ("Finish before twelve fifty sharp.", "Finish before 12:50 sharp."),
        ("Meet after one ten on the 14th.", "Meet after 1:10 on the 14th."),
        ("Meet at ten thirty on March 3rd.", "Meet at 10:30 on March 3rd."),
        ("Meet at ten thirty on Cedar Street.", "Meet at ten thirty on Cedar Street."),
        ("Leave about seven twenty.", "Leave about seven twenty."),
        ("Open from six thirty.", "Open from six thirty."),
        ("Move it to eight forty.", "Move it to eight forty."),
    ])
    func timeCue(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("meridiems convert directly; dayparts still need a cue", arguments: [
        ("Start at three forty pm.", "Start at 3:40pm."),
        ("Three forty pm works.", "3:40pm works."),
        ("Come at nine oh five a.m.", "Come at 9:05am."),
        ("Leave at four twenty p.m.", "Leave at 4:20pm."),
        ("Come at nine oh five a.m. tomorrow.", "Come at 9:05am tomorrow."),
        ("Come at ten thirty in the morning.", "Come at 10:30 in the morning."),
        ("Come by eleven fifteen in the evening.", "Come by 11:15 in the evening."),
        ("Come around two fifteen tonight.", "Come around 2:15 tonight."),
        ("Come six forty five o'clock.", "Come six forty five o'clock."),
        ("Try three five pm.", "Try 3:05pm."),
        ("Try three five this afternoon.", "Try three five this afternoon."),
        ("Leave at four p.m.", "Leave at 4:00pm."),
    ])
    func timeMarker(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("ambiguous or invalid time shapes stay words", arguments: [
        "Ten thirty.",
        "Ten thirty chairs arrived.",
        "Room ten thirty is upstairs.",
        "The model is ten thirty.",
        "Half past two is fine.",
        "Quarter to five works.",
        "Meet at half past two.",
        "Meet at twenty four thirty.",
        "Meet at ten sixty five.",
        "I have ten thirty-somethings.",
        "We counted ten thirty-second notes.",
    ])
    func nonTimes(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("idiomatic clock times convert with time evidence", arguments: [
        ("Meet at half past three tomorrow.", "Meet at 3:30 tomorrow."),
        ("Come quarter to five tonight.", "Come 4:45 tonight."),
        ("Start at quarter past nine this morning.", "Start at 9:15 this morning."),
        ("Leave before half past eleven sharp.", "Leave before 11:30 sharp."),
        ("Arrive at half past ten pm.", "Arrive at 10:30pm."),
        ("Call around quarter to seven in the evening.", "Call around 6:45 in the evening."),
        ("Meet at three o'clock.", "Meet at 3:00."),
        ("Dinner at seven o'clock tonight.", "Dinner at 7:00 tonight."),
        ("Open at nine o'clock am.", "Open at 9:00am."),
        ("Meet me at noon tomorrow.", "Meet me at noon tomorrow."),
        ("Leave by midnight tonight.", "Leave by midnight tonight."),
    ])
    func idiomaticTimes(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("to and for count as a cue only before a day part", arguments: [
        ("The standup moved to nine fifteen in the morning.", "The standup moved to 9:15 in the morning."),
        ("Push the call to four thirty this afternoon.", "Push the call to 4:30 this afternoon."),
        ("Dinner is booked for seven fifteen tonight.", "Dinner is booked for 7:15 tonight."),
        ("Raise the price to ten fifty tomorrow.", "Raise the price to ten fifty tomorrow."),
        ("Send it to ten twenty people this morning.", "Send it to ten twenty people this morning."),
        ("We went up to nine fifteen on Monday.", "We went up to nine fifteen on Monday."),
        ("Move it to eight forty.", "Move it to eight forty."),
    ])
    func toAndForBeforeDayPart(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("a cue and a quantity or label are not a clock", arguments: [
        "We heard from ten thirty neighbors.",
        "Send to five fifteen clubs.",
        "About two fifty ballots remain.",
        "Increase by four twenty seats.",
        "Gather at nine eleven plaza.",
        "Finish before seven thirty crates arrive.",
        "Wait after six forty packages.",
        "We passed five twenty blocks.",
        "Count since three thirty tickets.",
        "Work until eight fifteen shifts.",
        "Continue till seven thirty points.",
        "Sell at six fifty a share.",
        "Charge about two fifty a month.",
        "The score stands at ten thirty points.",
        "The parcel goes to five fifteen Cedar Street.",
        "Pack at six forty pound cases.",
    ])
    func cueWithNonTime(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("from-to ranges need a temporal word and two time-shaped ends", arguments: [
        ("Meet from one thirty to two thirty tomorrow.", "Meet from 1:30 to 2:30 tomorrow."),
        ("Meet from one thirty to two thirty.", "Meet from one thirty to two thirty."),
        ("Meet at ten thirty or eleven tomorrow.", "Meet at ten thirty or eleven tomorrow."),
        ("One thirty to two thirty tomorrow.", "One thirty to two thirty tomorrow."),
    ])
    func timeRange(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("cues and ambiguous continuations keep their words", arguments: [
        "The display count stands at four twenty, and more arrive.",
        "The parcel was priced at six fifty, with tax extra.",
        "The hourly rate settled at eight thirty with a bonus.",
        "The score ended at nine eleven, and fans cheered.",
        "The crate measured at three forty, with the lid attached.",
        "Deliver to five fifteen on Cedar Street.",
        "The model number starts at ten thirty, and rises from there.",
        "Her age was recorded at eleven fifteen.",
        "The page reference starts at seven twenty, with notes following.",
        "We counted by four twenty, and kept counting.",
        "The bid stayed until six forty, with no takers.",
        "The gauge read around two fifty.",
        "The tariff changed before eight thirty, and stayed there.",
        "The queue grew after five ten, with late arrivals.",
        "The quota was set till nine forty.",
        "The count came from ten thirty, and rose.",
        "The label reads at three fifteen.",
    ])
    func ambiguousCue(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("a correction without a new time word stays spoken")
    func correction() {
        let result = TextCleaner().clean("Meet at three twenty no wait three forty.").text
        #expect(!result.contains("3:20") && !result.contains("3:40"))
    }

    @Test("year readings convert with year context", arguments: [
        ("March twenty twenty six was wet.", "March 2026 was wet."),
        ("The 14th of May twenty twenty five was warm.", "The 14th of May 2025 was warm."),
        ("We met in nineteen ninety eight.", "We met in 1998."),
        ("It has run since twenty twenty one.", "It has run since 2021."),
        ("Finish by twenty twenty seven.", "Finish by twenty twenty seven."),
        ("The class of twenty twenty four graduated.", "The class of twenty twenty four graduated."),
        ("Stay until twenty thirty one.", "Stay until twenty thirty one."),
        ("Archive from nineteen eighty four.", "Archive from nineteen eighty four."),
        ("Move to twenty twenty nine.", "Move to twenty twenty nine."),
        ("Q3 twenty twenty six is the target.", "Q3 2026 is the target."),
        ("Spring nineteen ninety nine was cold.", "Spring 1999 was cold."),
    ])
    func years(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("a year after a normalized full date converts", arguments: [
        ("We met on the twenty third of April twenty twenty six, then left.", "We met on April 23, 2026, then left."),
        ("The fourth of October, nineteen ninety eight was rainy.", "October 4, 1998 was rainy."),
    ])
    func yearAfterFullDate(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("since a year can lead into a main clause", arguments: [
        ("Since twenty twenty six we have met monthly.", "Since 2026 we have met monthly."),
        ("Since nineteen ninety eight she has kept records.", "Since 1998 she has kept records."),
    ])
    func sinceYearClause(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("date and since look-alikes followed by counts stay spoken", arguments: [
        ("We ordered the twenty third of April twenty twenty six inch panels.", "We ordered April 23 twenty twenty six inch panels."),
        ("Since twenty twenty six inch panels arrived, demand rose.", "Since twenty twenty six inch panels arrived, demand rose."),
        ("Since nineteen ninety eight pound bags shipped, sales grew.", "Since nineteen ninety eight pound bags shipped, sales grew."),
    ])
    func yearClauseLookalikes(input: String, expected: String) {
        #expect(InverseTextNormalizer.apply(input) == expected)
    }

    @Test("count-like year readings stay words", arguments: [
        "Twenty twenty six inch monitors arrived.",
        "Order twenty twenty six inch monitors.",
        "In twenty twenty six inch frames fit.",
        "Nineteen ninety eight inch panels are listed.",
    ])
    func nonYears(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("year-like quantities keep their words", arguments: [
        "By twenty twenty widgets were ready.",
        "Of nineteen ninety nine votes, few counted.",
        "To twenty twenty parcels were sent.",
        "From nineteen eighty four houses came reports.",
        "In twenty twenty six-inch displays fit.",
        "In twenty twenty six square inch tiles fit.",
        "Since nineteen ninety eight pound bags arrived.",
        "March twenty twenty six tickets remain.",
    ])
    func yearLikeQuantity(input: String) {
        #expect(InverseTextNormalizer.apply(input) == input)
    }

    @Test("As Spoken keeps the spoken words")
    func asSpoken() {
        let cleaner = TextCleaner(options: CleanupOptions(level: .verbatim))
        #expect(cleaner.clean("meet at ten thirty in twenty twenty six").text == "meet at ten thirty in twenty twenty six")
    }

    @Test("default cleanup applies both readings in prose")
    func proseIntegration() {
        #expect(TextCleaner().clean("Meet at half past three tomorrow in March twenty twenty six.").text
            == "Meet at 3:30 tomorrow in March 2026.")
    }

    @Test("English number rules stay off for a detected non-English language")
    func otherLanguage() {
        let cleaner = TextCleaner(options: CleanupOptions(detectedLanguage: "es"))
        #expect(cleaner.clean("meet at ten thirty in twenty twenty six").text
            == "Meet at ten thirty in twenty twenty six.")
    }

    @Test("code context also leaves an ambiguous time spoken")
    func codeContext() {
        let cleaner = TextCleaner(options: CleanupOptions(isCodeContext: true))
        #expect(cleaner.clean("at ten thirty").text.contains("ten thirty"))
    }
}
