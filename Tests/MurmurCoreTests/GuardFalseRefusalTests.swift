import Foundation
import Testing
@testable import MurmurCore

/// Answers the whole-transcript guard (`IntentOutputGuard`) used to refuse although they mean what was said, and the
/// neighbouring answers it must still refuse because a value, a name or a negation changed. Every text here is invented.
@Suite("Guard false refusals", .timeLimit(.minutes(1)))
struct GuardFalseRefusalTests {
    private func accepted(_ answer: String, _ spoken: String) -> Bool {
        if case .accepted = IntentOutputGuard.check(answer, raw: spoken) { return true }
        return false
    }

    private func reason(_ answer: String, _ spoken: String) -> String? {
        if case .rejected(let reason) = IntentOutputGuard.check(answer, raw: spoken) { return reason }
        return nil
    }

    // MARK: Clock times the British way

    @Test("half seven is 7:30, and the other half-hours, in a time", arguments: [
        ("can we do half seven instead and meet at the cafe first", "Can we do 7:30 instead and meet at the cafe first?"),
        ("the doors open at half nine for the early group", "The doors open at 9:30 for the early group."),
        ("sorry the half four slot is the one i can cover", "Sorry, the 4:30 slot is the one I can cover."),
        ("it starts at half twelve on wednesdays", "It starts at 12:30 on Wednesdays."),
    ])
    func halfHours(_ spoken: String, _ answer: String) {
        #expect(accepted(answer, spoken), "\(answer)")
    }

    @Test("a different time, or a half that is an amount, is still refused", arguments: [
        ("can we do half seven instead and meet at the cafe first", "Can we do 7:15 instead and meet at the cafe first?"),
        ("can we do half seven instead and meet at the cafe first", "Can we do 8:30 instead and meet at the cafe first?"),
        ("the doors open at half nine for the early group", "The doors open at 9 for the early group."),
        ("add half two thirds of a cup of flour", "Add 2:30 thirds of a cup of flour."),
        ("it took half four hours", "It took 4:30 hours."),
    ])
    func halfHoursRefused(_ spoken: String, _ answer: String) {
        #expect(reason(answer, spoken) == "changed digits", "\(answer)")
    }

    // MARK: Years said in two halves

    @Test("a year said as twenty eighteen is 2018", arguments: [
        ("the recordings from before twenty eighteen are not in the backup", "The recordings from before 2018 are not in the backup."),
        ("we opened in nineteen ninety five and moved in twenty twenty two", "We opened in 1995 and moved in 2022."),
        ("the lease ends in twenty oh five", "The lease ends in 2005."),
    ])
    func years(_ spoken: String, _ answer: String) {
        #expect(accepted(answer, spoken), "\(answer)")
    }

    @Test("a year of another value, and numbers that only look like a year, are held")
    func yearsHeld() {
        #expect(reason("The recordings from before 2019 are not in the backup.", "the recordings from before twenty eighteen are not in the backup") == "changed digits")
        #expect(reason("We opened in 1996.", "we opened in nineteen ninety five") == "changed digits")
        // "twenty five" is 25 and stays 25.
        #expect(accepted("There are 25 of them.", "there are twenty five of them"))
        #expect(reason("There are 2005 of them.", "there are twenty five of them") == "changed digits")
    }

    // MARK: Hyphenated compounds

    @Test("a number in a hyphenated compound is read as the number it is")
    func hyphenatedCompounds() {
        let spoken = "it is a ten minute walk from the third floor and we have one to one chats with the new starter"
        #expect(accepted("It is a ten-minute walk from the third-floor, and we have one-to-one chats with the new starter.", spoken))
        #expect(reason("It is a twelve-minute walk from the third-floor, and we have one-to-one chats with the new starter.", spoken) == "changed digits")
        #expect(reason("It is a ten-minute walk from the fourth-floor, and we have one-to-one chats with the new starter.", spoken) == "changed digits")
        // Words that stand for one number keep their own reading.
        #expect(accepted("It is twenty-one steps up.", "it is twenty one steps up"))
        #expect(reason("It is twenty-two steps up.", "it is twenty one steps up") == "changed digits")
    }

    // MARK: first, second, third

    @Test("ordinals that counted a list are not values when the items are written as bullets or prose", arguments: [
        ("first update the readme so it is current second merge the open prs third tell the team about it",
         "- Update the readme so it is current\n- Merge the open PRs\n- Tell the team about it"),
        ("first update the readme so it is current second merge the open prs third tell the team about it",
         "Update the readme so it is current, merge the open PRs, and tell the team about it."),
    ])
    func ordinalCounters(_ spoken: String, _ answer: String) {
        #expect(accepted(answer, spoken), "\(answer)")
    }

    @Test("an ordinal that is a value still counts", arguments: [
        ("first update the readme second week merge the open prs and tell the team about it", "Update the readme and merge the open PRs, and tell the team about it."),
        ("the party is on the first of may and the deadline is the second of june", "The party and the deadline are in the summer."),
        ("it is the third time and i am not sure about it", "I am not sure about it."),
    ])
    func ordinalValues(_ spoken: String, _ answer: String) {
        #expect(reason(answer, spoken) == "changed digits", "\(answer)")
    }

    // MARK: Words that take a number back

    @Test("strike that and correct that take the number before them back")
    func retractionPhrases() {
        #expect(accepted("It takes three weeks.", "it takes two weeks strike that it takes three weeks"))
        #expect(accepted("It takes three weeks, unless something changes.", "it takes three days let me correct that three weeks unless something changes"))
        #expect(accepted("The deadline is the fifth.", "the deadline is the tenth i like mean to say fifth"))
        #expect(reason("It takes four weeks.", "it takes two weeks strike that it takes three weeks") == "changed digits")
    }

    // MARK: "one" that is not a number

    @Test("a pronoun one, and one per line, are not counts", arguments: [
        ("i cannot remember which one arrived late", "I cannot remember which arrived late."),
        ("the flat one has me down for saturday", "The flat has me down for Saturday."),
        ("list the rooms one per line kitchen hall and study", "List the rooms:\nKitchen\nHall\nStudy"),
        ("no one will tell me where it is", "Nobody will tell me where it is."),
    ])
    func pronounOne(_ spoken: String, _ answer: String) {
        #expect(accepted(answer, spoken), "\(answer)")
    }

    @Test("a one that counts is still a value", arguments: [
        ("i need one more chair for the table", "I need more chairs for the table."),
        ("order one pack of the heavy bars today", "Order a pack of the heavy bars today."),
        ("we have one per room", "We have it in every room."),
    ])
    func countingOne(_ spoken: String, _ answer: String) {
        #expect(reason(answer, spoken) == "changed digits", "\(answer)")
    }

    // MARK: Negation

    @Test("yes or know is yes or no, and dunno is don't know")
    func heardNegations() {
        #expect(accepted("Just text me yes or no.", "just text me yes or know"))
        #expect(accepted("I don't know what to do.", "i dunno what to do"))
        #expect(accepted("I don't know if it will work.", "i dunno if it will work"))
    }

    @Test("a negation the speaker did not say is still refused", arguments: [
        ("just text me yes or know", "Just text me yes or no, no."),
        ("i dunno what to do", "I don't know and I can't do it."),
        ("we should call her today", "We should not call her today."),
        ("i know what to do", "I don't know what to do."),
    ])
    func addedNegation(_ spoken: String, _ answer: String) {
        #expect(reason(answer, spoken) == "added negation", "\(answer)")
    }

    // MARK: Names

    @Test("a title, a unit, initials of spoken words and a sentence-opening word are not new names", arguments: [
        ("hello mister jones your order is ready", "Hello Mr. Jones, your order is ready."),
        ("hello missus jones your order is ready", "Hello Mrs. Jones, your order is ready."),
        ("the revised width is okay but i need your approval", "The revised width is OK, but I need your approval."),
        ("memory stayed under six gigs at the bigger size", "Memory stayed under 6 GB at the bigger size."),
        ("the compound annual growth rate was ten percent", "The CAGR was 10%."),
        ("mergers and acquisitions slowed this year", "M&A slowed this year."),
        ("you can pick the d v d player or the t v", "You can pick the DVD player or the TV."),
        ("the plan is late and we are short of money", "The plan is late. However, we are short of money."),
    ])
    func abbreviations(_ spoken: String, _ answer: String) {
        #expect(CorrectionBound.unsaidNames(answer: answer, draft: spoken).isEmpty, "\(answer)")
    }

    @Test("a name the speaker did not say is still refused", arguments: [
        ("hello jones your order is ready", "Hello Mr. Jones, your order is ready.", "Mr"),
        ("hello mister jones your order is ready", "Hello Mr. Smith, your order is ready.", "Smith"),
        ("memory stayed under six gigs", "Memory stayed under 6 TB.", "TB"),
        ("the annual growth rate was ten percent", "The CAGR was 10%.", "CAGR"),
        ("the space agency said no", "NASA said no.", "NASA"),
        ("ask the new hire to review it", "Ask Marguerite to review it.", "Marguerite"),
        ("the new vendor ships today", "Zorbulax ships today.", "Zorbulax"),
    ])
    func unsaidNames(_ spoken: String, _ answer: String, _ name: String) {
        #expect(CorrectionBound.unsaidNames(answer: answer, draft: spoken).contains(name), "\(answer)")
        #expect(reason(answer, spoken) == "changed name", "\(answer)")
    }
    // MARK: A takeback phrase must not ride along with the value the speaker kept

    @Test("the old value is dropped, and so is the phrase that retracted it", arguments: [
        ("the door code is five five five five no that is the old one it is two nine zero three", "The door code is 2903; that is the old one."),
        ("the pin is one two three four no that was the old one it is eight eight two six", "The PIN is 8826; that was the old one."),
        ("we ship version three point one no that is the old one it is three point four", "We ship version 3.4; that is the old one."),
        ("the alarm code is one two three four no that is the old one it is four seven one one also my neighbor linda has a spare key", "The alarm code is 4711; that is the old one. Also, my neighbor Linda has a spare key."),
        ("the room is twelve no not that it is fourteen", "The room is 14, not that."),
    ])
    func takebackWordingKept(_ spoken: String, _ answer: String) {
        #expect(!accepted(answer, spoken), "\(answer)")
    }

    @Test("the corrected value alone is accepted", arguments: [
        ("the door code is five five five five no that is the old one it is two nine zero three", "The door code is 2903."),
        ("the pin is one two three four no that was the old one it is eight eight two six", "The PIN is 8826."),
        ("we ship version three point one no that is the old one it is three point four", "We ship version 3.4."),
        ("the alarm code is one two three four no that is the old one it is four seven one one also my neighbor linda has a spare key", "The alarm code is 4711. Also, my neighbor Linda has a spare key."),
        ("the room is twelve no not that it is fourteen", "The room is 14."),
    ])
    func takebackDropped(_ spoken: String, _ answer: String) {
        #expect(accepted(answer, spoken), "\(answer) \(reason(answer, spoken) ?? "")")
    }

    @Test("a phrase that is only about an old one, with no value taken back, stays accepted", arguments: [
        ("i kept the old one and sent the new one back", "I kept the old one and sent the new one back."),
        ("that is the old one over there on the left shelf", "That is the old one over there on the left shelf."),
    ])
    func oldOneWithoutCorrection(_ spoken: String, _ answer: String) {
        #expect(accepted(answer, spoken), "\(answer)")
    }
}
