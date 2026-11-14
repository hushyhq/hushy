import Foundation
import Testing
@testable import MurmurCore

/// Code formatting is for what the person dictated as code. The prompt register asks the model for backticks around
/// "identifiers, paths and commands"; ordinary English words ("agent", "son") are never wrapped, and Professional and
/// Casual never add a backtick. Every sentence is invented.
@Suite("Backticks only around code the person dictated")
struct BackticksInPromptsTests {
    private func check(_ answer: String, raw: String, _ register: IntentRegister?) -> SmartCleaner.Refinement {
        IntentOutputGuard.check(answer, raw: raw, register: register)
    }

    private let heard = "Please start a son at agent to work on this"

    @Test("ordinary words wrapped by the model in the prompt register are put back to plain words")
    func ordinaryWordsUnwrapped() {
        #expect(check("Please start a `son` at `agent` to work on this.", raw: heard, .prompt)
                == .accepted("Please start a son at agent to work on this."))
        #expect(check("Please start a `Sonnet` agent to work on this.", raw: "Please start a Sonnet agent to work on this", .prompt)
                == .accepted("Please start a Sonnet agent to work on this."))
        #expect(check("Tell the `agent` to check the `logs` and the `config`.", raw: "tell the agent to check the logs and the config", .prompt)
                == .accepted("Tell the agent to check the logs and the config."))
        #expect(check("Please start `a son at agent` to work on this.", raw: heard, .prompt)
                == .accepted("Please start a son at agent to work on this."))
    }

    @Test("code the person dictated keeps its backticks beside plain words")
    func spokenCodeStays() {
        let cases: [(raw: String, answer: String)] = [
            ("tell the agent to fix auth client dot py", "Tell the agent to fix `auth_client.py`."),
            ("ask the agent to run it with dash dash verbose", "Ask the agent to run it with `--verbose`."),
            ("have the agent call get user by id first", "Have the agent call `getUserById` first."),
            ("tell the agent to run npm run dev and check the log", "Tell the agent to run `npm run dev` and check the log."),
            ("tell the agent to open source slash app dot ts", "Tell the agent to open `source/app.ts`."),
        ]
        for item in cases { #expect(check(item.answer, raw: item.raw, .prompt) == .accepted(item.answer), "\(item.answer)") }
    }

    @Test("a span the speaker already had is kept whole even when it holds an ordinary word")
    func spokenSpansStay() {
        let raw = "use `agent` mode and then `retry` it now"
        #expect(check("Use `agent` mode and then `retry` it now.", raw: raw, .prompt) == .accepted("Use `agent` mode and then `retry` it now."))
        // A new span beside them is unwrapped.
        #expect(check("Use `agent` mode and then `retry` it `now`.", raw: raw, .prompt)
                == .accepted("Use `agent` mode and then `retry` it now."))
    }

    @Test("Professional, Casual and Refined never add a backtick")
    func otherRegistersNeverAddOne() {
        for register in [nil, IntentRegister.casual, .professional] {
            #expect(check("Please start a `son` at `agent` to work on this.", raw: heard, register) == .rejected("changed backtick literal"))
            #expect(check("Please start a `Sonnet` agent to work on this.", raw: "Please start a Sonnet agent to work on this", register)
                    == .rejected("changed backtick literal"))
            #expect(check("Fix `auth_client.py`.", raw: "fix auth client dot py", register) == .rejected("changed backtick literal"))
        }
    }

    @Test("what counts as ordinary prose")
    func ordinaryProse() {
        for word in ["agent", "son", "son at agent", "Sonnet", "Opus", "config", "logs", "the", "don't"] {
            #expect(LiteralSyntaxProtection.isOrdinaryProse(word), "\(word)")
        }
        for code in ["rf", "getUserById", "auth_client.py", "--verbose", "npm run dev", "src/app.ts", "v2", "UserID", "pm2", "kubectl", ""] {
            #expect(!LiteralSyntaxProtection.isOrdinaryProse(code), "\(code)")
        }
    }
}
