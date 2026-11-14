import Foundation
import Testing
@testable import MurmurCore

/// A list counted aloud and written as prose is not a change of digits, while a number the speaker meant still is.
/// Every text here is invented.
@Suite("Counters folded into prose", .timeLimit(.minutes(1)))
struct FoldedCountersTests {
    @Test("a list written as a sentence or as paragraphs, without its numbers, is accepted", arguments: [
        ("okay two things one update the readme so new people can set it up in five minutes two merge the open prs after you review them",
         "Two things: update the readme so new people can set it up in five minutes, and merge the open PRs after you review them."),
        ("tasks for today one fix the login screen two write the release notes three tell the team",
         "Tasks for today: fix the login screen, write the release notes, and tell the team."),
        ("three jobs one call the bank about the loan two send the invoice to the client three book the train for friday",
         "Three jobs.\n\nCall the bank about the loan.\n\nSend the invoice to the client.\n\nBook the train for Friday."),
        ("my plan is one pack the bag for the trip two lock up the house and the shed three drop the keys with the neighbour",
         "My plan is to pack the bag for the trip, lock up the house and the shed, and drop the keys with the neighbour."),
        ("a few things one email the vendor about the invoice two call the dentist before friday",
         "A few things: email the vendor about the invoice and call the dentist before Friday."),
    ])
    func forgiven(_ spoken: String, _ answer: String) {
        #expect(NumberValueGuard.violation(answer: answer, draft: spoken) == nil, "\(answer)")
        #expect(IntentOutputGuard.check(answer, raw: spoken) == .accepted(answer))
    }

    @Test("a correction in the draft does not stop the counters being forgiven")
    func forgivenWithCorrection() {
        let spoken = "tasks one fix the login screen two write the release notes sorry I mean draft the release notes three tell the team"
        let answer = "Tasks: fix the login screen, draft the release notes, and tell the team."
        #expect(NumberValueGuard.violationWithCorrection(answer: answer, draft: spoken) == nil)
    }

    @Test("a real value that is dropped or changed is still refused", arguments: [
        // "two weeks" is a value inside the list, not a counter.
        ("tasks one fix the login screen two wait two weeks for the vendor three tell the team",
         "Fix the login screen, wait for the vendor, and tell the team."),
        ("tasks one fix the login screen two wait two weeks for the vendor three tell the team",
         "Fix the login screen, wait three weeks for the vendor, and tell the team."),
        // "one hundred" is a number, not the first counter or a value to drop.
        ("tasks one order one hundred chairs for the office two book the room for the offsite three email the team about it",
         "Order chairs for the office, book the room for the offsite, and email the team about it."),
        ("tasks one order one hundred chairs for the office two book the room for the offsite three email the team about it",
         "Order 10 chairs for the office, book the room for the offsite, and email the team about it."),
        // A quantity beside a noun is no list.
        ("i have one cat and two dogs at home", "I have a cat and dogs at home."),
        // A counter that is followed by a unit or another number is a value.
        ("one hour of study two hours of practice", "Study and practice."),
        // Not a run from one.
        ("please do two things first fix the door and then three paint the wall now", "Fix the door and paint the wall."),
        // A count that is missing from the run.
        ("tasks one fix the login screen three tell the team about the fix", "Fix the login screen and tell the team about the fix."),
        // A counter heard as "to" or "for" is not read as a counter in prose: the answer may have joined two steps into one
        // step with a purpose, and nothing in it proves the steps were split.
        ("for the release one bump the version in package dot json to run npm test three merge the release pr",
         "For the release, bump the version in package.json to run npm test, then merge the release PR."),
        ("two things one fix the node js build to update the next js config and then deploy it to vercel",
         "Two things: fix the Node.js build to update the Next.js config, and then deploy it to Vercel."),
        ("tasks one fix the login screen to write the release notes three tell the team",
         "Fix the login screen to write the release notes, then tell the team."),
        // The answer numbers its items and leaves one out: the counters have to match.
        ("tasks one fix the login screen two write the release notes three tell the team",
         "Tasks:\n1. Fix the login screen\n2. Write the release notes"),
        // The answer adds a number nobody said.
        ("tasks one fix the login screen two write the release notes three tell the team",
         "Fix the login screen, write the release notes within 5 days, and tell the team."),
    ])
    func refused(_ spoken: String, _ answer: String) {
        #expect(NumberValueGuard.violation(answer: answer, draft: spoken) == "changed digits", "\(answer)")
    }

    @Test("values the speaker meant stay when the list is also written in prose")
    func keptValuesPass() {
        let spoken = "tasks one fix the login screen two wait two weeks for the vendor three tell the team"
        #expect(NumberValueGuard.violation(
            answer: "Fix the login screen, wait two weeks for the vendor, and tell the team.", draft: spoken) == nil)
        let hundred = "tasks one order one hundred chairs for the office two book the room for the offsite three email the team about it"
        #expect(NumberValueGuard.violation(
            answer: "Order 100 chairs for the office, book the room for the offsite, and email the team about it.", draft: hundred) == nil)
    }

    @Test("the counter run is found from the words as said only")
    func runs() {
        #expect(FoldedCounters.removing(from: "tasks one fix the login screen two write the release notes three tell the team")
            == "tasks fix the login screen write the release notes tell the team")
        #expect(FoldedCounters.removing(from: "tasks one fix the login screen to write the release notes three tell the team") == nil)
        #expect(FoldedCounters.removing(from: "tasks one fix the login screen two write the release notes for call the vendor") != nil)
        #expect(FoldedCounters.removing(from: "i have one cat and two dogs at home") == nil)
        #expect(FoldedCounters.removing(from: "the plan has one step") == nil)
    }
}
