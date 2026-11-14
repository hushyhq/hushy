import Foundation
import Testing
@testable import MurmurCore

/// In the prompt register the model puts identifiers, paths and commands in backticks. The guard accepts a span around
/// what the speaker said and keeps refusing every other change to a literal; no other check is touched.
@Suite("Intent guard: backticks in the prompt register")
struct IntentBacktickGuardTests {
    private func check(_ answer: String, raw: String, _ register: IntentRegister?) -> SmartCleaner.Refinement {
        IntentOutputGuard.check(answer, raw: raw, register: register)
    }

    @Test("a spoken file name, flag, path, command and name in camel case may be put in backticks")
    func spokenIdentifiers() {
        let cases: [(raw: String, answer: String)] = [
            ("fix auth client dot py", "Fix `auth_client.py`."),
            ("run it with dash dash verbose", "Run it with `--verbose`."),
            ("open source slash app dot ts", "Open `source/app.ts`."),
            ("call get user by id first", "Call `getUserById` first."),
            ("run npm run dev and check the log", "Run `npm run dev` and check the log."),
            ("pass r f to the remove command", "Pass `rf` to the remove command."),
        ]
        for item in cases {
            #expect(check(item.answer, raw: item.raw, .prompt) == .accepted(item.answer), "\(item.answer)")
        }
    }

    @Test("outside the prompt register the same answers are refused as before")
    func otherRegistersUnchanged() {
        for register in [nil, IntentRegister.casual, .professional] {
            #expect(check("Fix `auth_client.py`.", raw: "fix auth client dot py", register) == .rejected("changed backtick literal"))
            #expect(check("Run it with `--verbose`.", raw: "run it with dash dash verbose", register) == .rejected("changed backtick literal"))
        }
        // Without backticks the same dictation is judged as it always was.
        #expect(check("Fix auth_client.py.", raw: "fix auth client dot py", nil) == IntentOutputGuard.check("Fix auth_client.py.", raw: "fix auth client dot py"))
    }

    @Test("backticks around something that was not said are refused")
    func inventedLiterals() {
        #expect(check("Fix the `login_handler` bug.", raw: "fix the login bug", .prompt) == .rejected("changed backtick literal"))
        #expect(check("Run `make deploy` now.", raw: "run the build now", .prompt) == .rejected("changed backtick literal"))
        #expect(check("Fix `auth_client.py` and `db.py`.", raw: "fix auth client dot py", .prompt) == .rejected("changed backtick literal"))
        #expect(check("Fix `42`.", raw: "fix the thing", .prompt) == .rejected("changed backtick literal"))
    }

    @Test("a backtick literal the speaker already had still has to come back whole and in order")
    func existingLiterals() {
        let raw = "use `foo` and then `bar` here"
        #expect(check("Use `foo` and then `bar` here.", raw: raw, .prompt) == .accepted("Use `foo` and then `bar` here."))
        #expect(check("Use `foo` and then `baz` here.", raw: raw, .prompt) == .rejected("changed backtick literal"))
        #expect(check("Use foo and then `bar` here.", raw: raw, .prompt) == .rejected("changed backtick literal"))
        #expect(check("Use `bar` and then `foo` here.", raw: raw, .prompt) == .rejected("changed backtick literal"))
        // A new span around a spoken word that is code may sit beside the ones that were there; around an ordinary
        // word it is put back to plain text (`BackticksInPromptsTests`).
        #expect(check("Use `foo` and then `bar` here, then `getUser`.", raw: raw + " get user", .prompt)
                == .accepted("Use `foo` and then `bar` here, then `getUser`."))
        #expect(check("Use `foo` and then `bar` here, then `here`.", raw: raw, .prompt) == .accepted("Use `foo` and then `bar` here, then here."))
    }

    @Test("names, digits and negation are still judged in the prompt register")
    func otherChecksUnchanged() {
        #expect(check("Fix `auth_client.py` in 3 files.", raw: "fix auth client dot py in two files", .prompt) == .rejected("changed digits"))
        #expect(check("Don't fix `auth_client.py`.", raw: "fix auth client dot py", .prompt) == .rejected("added negation"))
        #expect(check("", raw: "fix auth client dot py", .prompt) == .rejected("empty"))
        #expect(check("Ask Veylora to fix `auth_client.py`.", raw: "ask the team to fix auth client dot py", .prompt) == .rejected("changed name"))
    }
}
