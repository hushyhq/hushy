import Foundation

/// Backend-agnostic judge verdict: any CLI judge (Claude, Codex) parses its model's raw text
/// into exactly this shape, so callers (both-mode agreement, golden reports) never need to know
/// which backend produced a verdict.
struct JudgeVerdict: Equatable, Codable {
    /// Whether the cleanup output preserves the speaker's meaning well enough to pass.
    let passed: Bool
    /// 0...4, mirroring the TypeSafe judge's meaning_preserved score levels, for rough
    /// comparability across backends in reports.
    let meaningScore: Double
    /// Short justification the model gave for its verdict; kept for the disagreement report in
    /// `both` mode and for human review, never parsed further.
    let reasoning: String

    enum CodingKeys: String, CodingKey {
        case passed, meaningScore = "meaning_score", reasoning
    }
}

/// Builds the judge prompt and parses the model's raw text response into a `JudgeVerdict`. The
/// prompt demands strict, schema-only JSON (no prose, no code fences) because both CLIs are
/// driven non-interactively and the response has to be machine-parsed with no human in the loop
/// to recover from a chatty answer.
enum JudgePrompt {
    /// The rubric shared by every CLI backend: same meaning/fluency criteria the TypeSafe judge
    /// applies (see `JudgeRunner.judgeOne`'s `meaning_preserved` question), collapsed into a
    /// single pass/fail plus a 0-4 score so it fits one-shot in a stateless CLI call.
    static func prompt(input: String, output: String, reference: String, rubric: String? = nil) -> String {
        let rubricText = rubric ?? defaultRubric
        return """
            You are grading a dictation cleanup system. Compare the actual output against the \
            reference for the given spoken input, using this rubric:

            \(rubricText)

            Respond with ONLY a single JSON object and nothing else — no prose, no markdown code \
            fences, no explanation outside the JSON. The object must have exactly these fields:
            {"passed": <true|false>, "meaning_score": <number 0-4>, "reasoning": "<one sentence>"}

            spoken (original input, may include self-corrections the speaker made out loud):
            \(input)

            actual output (what the dictation system produced):
            \(output)

            reference (an acceptable expected output):
            \(reference)

            Respond with only the JSON object described above.
            """
    }

    static let defaultRubric = """
        - meaning_score 4: every fact and request the speaker still meant (after their own \
        self-corrections) is preserved; nothing missing, nothing invented.
        - meaning_score 3: nearly everything preserved, at most one minor gap.
        - meaning_score 2: some but not all of the intended meaning survived.
        - meaning_score 1: only a small part of the intended meaning survived.
        - meaning_score 0: meaning is lost, missing, or contradicted.
        - passed should be true only when meaning_score >= 3 AND no fact was invented or \
        contradicted AND the output reads as fluent, usable text.
        """

    enum ParseError: LocalizedError, Equatable {
        case noJSONFound
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .noJSONFound: "No JSON object found in judge model output"
            case .malformed(let detail): "Judge model output was not a valid verdict: \(detail)"
            }
        }
    }

    /// Extracts the first top-level `{...}` JSON object from `text` (tolerating leading/trailing
    /// prose or a markdown code fence the model added despite instructions) and decodes it as a
    /// `JudgeVerdict`. Throws rather than guesses on anything ambiguous, since callers use the
    /// failure to trigger the one allowed retry.
    static func parse(_ text: String) throws -> JudgeVerdict {
        guard let jsonSubstring = extractJSONObject(from: text) else {
            throw ParseError.noJSONFound
        }
        let data = Data(jsonSubstring.utf8)
        do {
            return try JSONDecoder().decode(JudgeVerdict.self, from: data)
        } catch {
            throw ParseError.malformed(String(describing: error))
        }
    }

    /// Finds the first balanced `{...}` span in `text`, respecting string quoting so braces
    /// inside a JSON string value don't throw off the brace count.
    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
