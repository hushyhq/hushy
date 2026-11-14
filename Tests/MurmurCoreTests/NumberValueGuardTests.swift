import Testing
@testable import MurmurCore

@Suite("Spoken number values")
struct NumberValueGuardTests {
    @Test("typed forms preserve spoken values", arguments: [
        ("Meet at seven in the morning.", "Meet at 7 AM."),
        ("The train arrives at half past ten.", "The train arrives at 10:30."),
        ("Leave at quarter to eight.", "Leave at 7:45."),
        ("Revenue grew in q three twenty twenty six.", "Revenue grew in Q3 2026."),
        ("We need two point five million.", "We need 2.5 million."),
        ("It costs twenty four dollars and ninety nine cents.", "It costs $24.99."),
        ("The rate is fifteen percent.", "The rate is 15%."),
        ("Call four one five five five five zero one nine eight.", "Call 415-555-0198."),
    ])
    func equivalent(_ spoken: String, _ typed: String) {
        #expect(NumberValueGuard.violation(answer: typed, draft: spoken) == nil)
        #expect(CriticalTokenGuard.violation(answer: typed, draft: spoken) == nil)
    }

    @Test("changed, added, merged and dropped values are refused", arguments: [
        ("Call four one five five five five zero one nine eight.", "Call 415-550-198."),
        ("Pick me up at seven? Seven fifteen might be easier.", "Pick me up at 7:15? 7:15 might be easier."),
        ("Meet at nine.", "Meet at nine and ten."),
        ("Meet at nine and leave at ten.", "Meet at 9:10."),
        ("The total is twenty four dollars.", "The total is $24.99."),
        ("We grew by two point five million.", "We grew by 2.6 million."),
        ("The rate is fifteen percent.", "The rate is 50%."),
        ("Call five five five one two three four five six seven.", "Call 555-123-4568."),
    ])
    func mismatch(_ spoken: String, _ typed: String) {
        #expect(NumberValueGuard.violation(answer: typed, draft: spoken) == "changed digits")
    }

    @Test("group cleanup compares the digits the rules draft already typed", arguments: [
        ("Call me back on 415-555-0198.", "Call me back on 415-550-198.", "changed digits"),
        ("The total is $24.", "The total is $24.99.", "changed digits"),
        ("The total is $24.", "The total is $24.", nil),
        ("Do first, do not restart it.", "Do not restart it.", nil),
        ("Um, take the green one.", "Take the green one.", nil),
    ])
    func groupDigits(_ draft: String, _ answer: String, _ expected: String?) {
        #expect(CriticalTokenGuard.violation(answer: answer, draft: draft) == expected)
    }

    @Test("the intent guard accepts a correct rewrite and refuses a lost spoken value")
    func intent() {
        let source = "Pick me up at seven? Seven fifteen might be easier."
        if case .rejected(let reason) = IntentOutputGuard.check(
            "Pick me up at 7? 7:15 might be easier.", raw: source) {
            Issue.record("correct typed times rejected: \(reason)")
        }
        #expect(IntentOutputGuard.check(
            "Pick me up at 7:15? 7:15 might be easier.", raw: source) == .rejected("changed digits"))
    }

    @Test("a correction does not excuse dropping another number")
    func correctedAndUncorrected() {
        let spoken = "Meet at nine no ten and leave at eleven."
        #expect(NumberValueGuard.violationWithCorrection(
            answer: "Meet at 10 and leave at 11.", draft: spoken) == nil)
        #expect(NumberValueGuard.violationWithCorrection(
            answer: "Meet at 10.", draft: spoken) == "changed digits")
    }

    @Test("the whole-transcript guard accepts typed forms of spoken values", arguments: [
        ("we raised one point five million in q two twenty twenty five", "We raised 1.5 million in Q2 2025."),
        ("the bus leaves at eight in the morning and gets in at half past eleven",
         "The bus leaves at 8 in the morning and gets in at 11:30."),
        ("the shop opens at quarter past nine and closes at ten to six", "The shop opens at 9:15 and closes at 5:50."),
        ("the call starts at twenty past four", "The call starts at 4:20."),
        ("pick me up at five to one", "Pick me up at 12:55."),
        ("the plan for friday one clean the garage two wash the car three cook dinner",
         "The plan for Friday:\n1. Clean the garage\n2. Wash the car\n3. Cook dinner"),
    ])
    func intentAccepts(_ spoken: String, _ typed: String) {
        if case .rejected(let reason) = IntentOutputGuard.check(typed, raw: spoken) {
            Issue.record("correct answer rejected: \(reason)")
        }
        #expect(NumberValueGuard.violation(answer: typed, draft: spoken) == nil)
    }

    @Test("the whole-transcript guard refuses a changed, dropped or merged value", arguments: [
        ("call me back on four one five five five five zero one nine eight", "Call me back on 415-550-198."),
        ("book the table for the twelfth of june at quarter to nine", "Book the table for the 12th of June at 9:00."),
        ("let's say nine or maybe nine thirty on monday", "Let's say 9:30 on Monday."),
        ("the bus leaves at quarter past seven and arrives at ten to ten", "The bus leaves at 7:45 and arrives at 7:59."),
        ("the shop closes at ten to six", "The shop closes at 6:10."),
        ("the plan for friday one clean the garage two wash the car three cook dinner",
         "The plan for Friday:\n1. Clean the garage\n2. Wash the car"),
        ("buy two apples three pears and four plums", "Buy:\n1. Apples\n2. Pears\n3. Plums"),
    ])
    func intentRefuses(_ spoken: String, _ typed: String) {
        #expect(IntentOutputGuard.check(typed, raw: spoken) == .rejected("changed digits"))
    }

    @Test("minutes to and past an hour read as a clock time only beside a time")
    func minutesToAndPast() {
        #expect(NumberValueGuard.violation(answer: "We went from 10 to 9 people.", draft: "we went from ten to nine people") == nil)
        #expect(NumberValueGuard.violation(answer: "It costs $10 to $12 a month.", draft: "it costs ten to twelve dollars a month") == nil)
        #expect(NumberValueGuard.violation(answer: "Arrive at 8:50.", draft: "arrive at ten to nine") == nil)
        #expect(NumberValueGuard.violation(answer: "Arrive at 9:10.", draft: "arrive at ten to nine") == "changed digits")
    }

    @Test("\"one\" standing for a noun is not a number")
    func pronounOne() {
        let spoken = "Let's take the red car, actually no, the silver one."
        #expect(NumberValueGuard.violationWithCorrection(answer: "Let's take the silver car.", draft: spoken) == nil)
        if case .rejected(let reason) = IntentOutputGuard.check("Let's take the silver car.", raw: spoken) {
            Issue.record("correct correction rejected: \(reason)")
        }
        #expect(NumberValueGuard.violation(answer: "I like the blue one best.", draft: "I like the blue one best.") == nil)
        #expect(NumberValueGuard.violation(answer: "Which is better?", draft: "which one is better") == nil)
        #expect(NumberValueGuard.violation(answer: "I need some.", draft: "I need one.") == "changed digits")
        #expect(NumberValueGuard.violation(answer: "Buy apples.", draft: "buy one apple") == "changed digits")
        #expect(NumberValueGuard.violation(answer: "Take the bags.", draft: "take the one bag") == "changed digits")
    }

    @Test("a value the speaker took back may be left out", arguments: [
        ("the course runs for two weeks um no a month so plan ahead", "The course runs for a month so plan ahead."),
        ("it costs three hundred dollars make it two hundred euros by friday", "It costs 200 euros by Friday."),
        ("oops sorry not four we need six plates", "We need 6 plates."),
        ("we need twelve boxes actually no a whole pallet", "We need a whole pallet."),
        ("we need eight tickets for the trip to the coast in spring i mean we need ten tickets",
         "We need 10 tickets for the trip to the coast in spring."),
        ("book room three for the review on second thought the big hall", "Book the big hall for the review."),
    ])
    func retracted(_ spoken: String, _ typed: String) {
        #expect(IntentOutputGuard.check(typed, raw: spoken) == .accepted(typed))
    }

    @Test("a correction does not excuse dropping a value with no correction after it", arguments: [
        ("the course runs for two weeks um no a month and costs forty dollars", "The course runs for a month."),
        ("oops sorry not four we need six plates", "We need plates."),
    ])
    func retractedStillGuarded(_ spoken: String, _ typed: String) {
        #expect(IntentOutputGuard.check(typed, raw: spoken) == .rejected("changed digits"))
    }
}
