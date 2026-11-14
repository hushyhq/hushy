import Foundation
import Testing
@testable import MurmurCore

/// Plain prose that merely mentions technical words (a README, PRs) is not code whose every character must survive, while
/// real literal code still is, and a list whose counter the recogniser heard as "to" keeps its numbers. Every text here is
/// invented.
@Suite("Prose that mentions technical words, and real code", .timeLimit(.minutes(1)))
struct ProseMentioningCodeGuardTests {
    // MARK: A code editor

    @Test("in a code editor an acronym and its plural are allowed, a command and a path are not")
    func codeEditor() {
        let prose = "update the readme and merge the prs"
        #expect(CodeContextGuard.violation(answer: "Update the README and merge the PRs.", draft: prose) == nil)
        #expect(CodeContextGuard.violation(answer: "Update the README and merge the PRs.", draft: prose, repairsGrammar: true) == nil)
        let command = "git push origin main"
        #expect(CodeContextGuard.violation(answer: "Git push origin main.", draft: command) != nil)
        let path = "open src/app.ts and read the readme"
        #expect(CodeContextGuard.violation(answer: "Open src/App.ts and read the README.", draft: path) != nil)
        let statement = "const x = 5;"
        #expect(CodeContextGuard.violation(answer: "const x = 6;", draft: statement) != nil)
        #expect(CodeContextGuard.violation(answer: "Const x = 5;", draft: statement) != nil)
    }

    // MARK: A list whose second item the recogniser heard as "to"

    @Test("a list laid out from counters, with a counter heard as another word, keeps its numbers", arguments: [
        ("okay two things one update the readme so new people can set it up to merge the open prs after you review them",
         "Two things:\n1. Update the README so new people can set it up.\n2. Merge the open PRs after you review them."),
        ("tasks one fix the login page to write the release notes three tell the team",
         "Tasks:\n1. Fix the login page.\n2. Write the release notes.\n3. Tell the team."),
        ("jobs one call the bank two send the invoice three book the train for the demo",
         "Jobs:\n1. Call the bank.\n2. Send the invoice.\n3. Book the train for the demo."),
        ("list one pack the bag two lock the door three water the plants for call the neighbours",
         "List:\n1. Pack the bag.\n2. Lock the door.\n3. Water the plants.\n4. Call the neighbours."),
    ])
    func misheardCounter(_ spoken: String, _ answer: String) {
        #expect(NumberValueGuard.violation(answer: answer, draft: spoken) == nil)
        #expect(IntentOutputGuard.check(answer, raw: spoken) == .accepted(answer))
    }

    @Test("a number the speaker did not say is still refused in a list")
    func numbersStillHeld() {
        let spoken = "tasks one fix the login page to write the release notes three tell the team"
        #expect(NumberValueGuard.violation(
            answer: "Tasks:\n1. Fix the login page.\n2. Write the release notes.\n3. Tell the team in 5 minutes.", draft: spoken) == "changed digits")
        #expect(NumberValueGuard.violation(
            answer: "Tasks:\n1. Fix the login page.\n2. Write the release notes.\n4. Tell the team.", draft: spoken) == "changed digits")
        // A spoken "two" is the counter before a "to".
        let said = "one send it to bob two call alice"
        #expect(NumberValueGuard.violation(answer: "1. Send it to Bob.\n2. Call Alice.", draft: said) == nil)
        // Without a list the answer cannot gain a number from a "to".
        #expect(NumberValueGuard.violation(answer: "I want 2 of them.", draft: "i want to of them") == "changed digits")
    }
}
