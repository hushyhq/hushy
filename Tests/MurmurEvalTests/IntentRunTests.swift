import Foundation
import Testing

@testable import murmur_eval

/// The pure parts of `murmur-eval intent-run`: they must lay the prompt out and read the answer
/// exactly as the Python reference runner does, or a difference in answers says nothing about the model.
@Suite("intent-run prompt layout and answer parsing")
struct IntentRunTests {
    @Test func systemTurnIsTheTrimmedSectionBetweenTheMarkers() {
        let file = "DRAFT. Version: x.\n\n--- system turn ---\nWrite what the speaker meant.\n- Keep facts.\n\n--- user turn ---\nTranscript: <t>\nOutput:\n"
        #expect(IntentRun.systemTurn(inPromptFile: file) == "Write what the speaker meant.\n- Keep facts.")
    }

    @Test func systemTurnRunsToTheEndWhenThereIsNoUserSection() {
        #expect(IntentRun.systemTurn(inPromptFile: "--- system turn ---\n  Rewrite it. \n") == "Rewrite it.")
    }

    @Test func aFileWithoutASystemSectionHasNoSystemTurn() {
        #expect(IntentRun.systemTurn(inPromptFile: "Rewrite it.") == nil)
        #expect(IntentRun.systemTurn(inPromptFile: "--- system turn ---\n\n--- user turn ---\nx") == nil)
    }

    @Test func userTurnIsTranscriptThenOutput() {
        #expect(IntentRun.userTurn(spoken: "move it to four") == "Transcript: move it to four\nOutput:")
    }

    @Test func bareJSONAnswerGivesItsTextField() {
        #expect(IntentRun.answerText(raw: #"{"text":"Move it to 4."}"#) == "Move it to 4.")
        #expect(IntentRun.answerText(raw: "{\"text\": \"One.\\n\\nTwo \\\"quoted\\\".\"}") == "One.\n\nTwo \"quoted\".")
    }

    @Test func fencedAnswerAndEndOfTurnTokenAreStripped() {
        let raw = "```json\n{\"text\": \"Move it to 4.\"}\n```<turn|>\nmore"
        #expect(IntentRun.answerText(raw: raw) == "Move it to 4.")
        #expect(IntentRun.answerText(raw: "```\n{\"text\":\"A\"}\n```") == "A")
        #expect(IntentRun.answerText(raw: #"{"text":"A"}<end_of_turn>{"text":"B"}"#) == "A")
    }

    @Test func thinkingBlockIsDropped() {
        let raw = "<|channel>thought\nThe speaker corrected the time.<channel|>{\"text\":\"Move it to 4.\"}"
        #expect(IntentRun.answerText(raw: raw) == "Move it to 4.")
        #expect(IntentRun.answerText(raw: "<think>hm\nhm</think>\n{\"text\":\"A\"}") == "A")
    }

    @Test func answerWhoseJSONDoesNotParseIsSearchedForItsTextField() {
        // Cut off before the closing quote and brace: nothing is repaired, the raw answer comes back.
        #expect(IntentRun.answerText(raw: #"{"text":"Move it"#) == #"{"text":"Move it"#)
        // Unescaped quotes inside the string break the parse; the field is found and kept as written.
        #expect(IntentRun.answerText(raw: #"{"text": "He said "hi" twice"}"#) == #"He said "hi" twice"#)
        // Prose around the object: the text field is found and unescaped.
        #expect(IntentRun.answerText(raw: "Here: {\"text\": \"Line\\none\" } done") == "Line\none")
    }

    @Test func plainOrEmptyAnswerNeverComesBackEmpty() {
        #expect(IntentRun.answerText(raw: "Move it to 4.") == "Move it to 4.")
        #expect(IntentRun.answerText(raw: "  <turn|>") == "(empty)")
        #expect(IntentRun.answerText(raw: #"{"text":""}"#) == "(empty)")
    }

    @Test func normalisedCollapsesWhitespaceOnly() {
        #expect(IntentRun.normalised("  One.\n\nTwo  three.\t") == "One. Two three.")
        #expect(IntentRun.normalised("One, two") != IntentRun.normalised("One two"))
    }

    @Test func upperMedianMatchesTheReferenceRunner() {
        #expect(IntentRun.upperMedian([]) == 0)
        #expect(IntentRun.upperMedian([3, 1, 2]) == 2)
        #expect(IntentRun.upperMedian([4, 1, 3, 2]) == 3)
    }

    @Test func subcommandIsListedInUsage() {
        #expect(Eval.usage.contains("intent-run"))
    }
}
