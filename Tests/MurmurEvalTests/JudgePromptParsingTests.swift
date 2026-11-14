import Foundation
import Testing

@testable import murmur_eval

/// Tests for `JudgePrompt.parse`: extracting a `JudgeVerdict` from raw CLI judge model text,
/// including the messy cases a real model can produce despite being told "JSON only" (markdown
/// fences, leading prose, braces inside string values).
@Suite("JudgePrompt verdict parsing")
struct JudgePromptParsingTests {
    @Test func parsesCleanJSONObject() throws {
        let text = #"{"passed": true, "meaning_score": 3.5, "reasoning": "Everything preserved."}"#
        let verdict = try JudgePrompt.parse(text)
        #expect(verdict.passed == true)
        #expect(verdict.meaningScore == 3.5)
        #expect(verdict.reasoning == "Everything preserved.")
    }

    @Test func parsesJSONWrappedInMarkdownCodeFence() throws {
        let text = """
            ```json
            {"passed": false, "meaning_score": 1.0, "reasoning": "Dropped the date."}
            ```
            """
        let verdict = try JudgePrompt.parse(text)
        #expect(verdict.passed == false)
        #expect(verdict.meaningScore == 1.0)
    }

    @Test func parsesJSONWithLeadingAndTrailingProse() throws {
        let text = """
            Sure, here is my verdict:
            {"passed": true, "meaning_score": 4, "reasoning": "Perfect match."}
            Let me know if you need anything else.
            """
        let verdict = try JudgePrompt.parse(text)
        #expect(verdict.passed == true)
        #expect(verdict.meaningScore == 4)
    }

    @Test func toleratesBracesInsideStringValues() throws {
        let text = #"{"passed": true, "meaning_score": 3, "reasoning": "Uses a { brace } in prose."}"#
        let verdict = try JudgePrompt.parse(text)
        #expect(verdict.reasoning == "Uses a { brace } in prose.")
    }

    @Test func throwsNoJSONFoundWhenThereIsNoBrace() {
        #expect(throws: JudgePrompt.ParseError.self) {
            _ = try JudgePrompt.parse("I refuse to answer in JSON.")
        }
    }

    @Test func throwsMalformedForJSONMissingRequiredFields() {
        #expect(throws: JudgePrompt.ParseError.self) {
            _ = try JudgePrompt.parse(#"{"passed": true}"#)
        }
    }

    @Test func throwsMalformedForTruncatedJSON() {
        #expect(throws: JudgePrompt.ParseError.self) {
            _ = try JudgePrompt.parse(#"{"passed": true, "meaning_score": 3"#)
        }
    }

    @Test func promptNeverEmbedsTheRealHomeDirectoryOrSecrets() {
        // Defense in depth: the rendered prompt is exactly input/output/reference/rubric text,
        // nothing about the local machine.
        let prompt = JudgePrompt.prompt(input: "call mom", output: "Call mom.", reference: "Call Mom.")
        #expect(!prompt.contains("/Users/"))
        #expect(!prompt.contains("TYPESAFE_API_KEY"))
    }
}
