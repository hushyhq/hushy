import Foundation

/// The way of writing a dictation is asked for, sent to a model that was trained on it as one line of the intent
/// system prompt (`IntentCleanupPrompt.system(register:)`). Refined has no register: it sends nothing and the
/// prompt stays as it always was.
///
/// Only a model whose registry entry has `understandsRegisterLines` is sent the line. For any other model the
/// register is ignored here and the word-level tone pass (`ToneRegister`) does the tone, as it always has.
public enum IntentRegister: String, Sendable, Equatable, CaseIterable {
    case casual, professional, prompt

    /// The register for a tone. `nil` for Refined.
    public init?(tone: DictationTone) {
        switch tone {
        case .refined: return nil
        case .casual: self = .casual
        case .professional: self = .professional
        }
    }

    /// The exact line sent to the model. It carries an em dash. Casual is the line round 8 was trained on, and Prompt was.
    /// Prompt is reworded from its trained line ("…identifiers, paths and commands as code in backticks…"): the 4B wrapped
    /// every identifier in backticks and left it as heard (`TRY95` where the plain path writes TRY-95), and glued ordinary
    /// words into one (`useOfKaraoglu`); backticks are now for the code the speaker dictated. Its "the request first" turned
    /// questions into commands and dropped a leading subject with a name in it ("J Hai and Quan are out…"); the line now
    /// keeps the speaker's words and order (founder: agent apps are for prompting; accuracy eval, 2026-11-11). Asked for a
    /// prompt, the 4B handed back a mis-heard name as heard where the plain ask repairs it (its first answer was the heard
    /// text for Halliburton, Holgren, Shengun; logged with `GroupTrace.Measured.modelAnswer`), so the line asks for the
    /// repair the system prompt already asks for.
    /// Professional is reworded from its trained line ("…precise wording, complete sentences, a courteous tone, and real
    /// rewording…"): "complete sentences" made the 4B invent a sentence around a clipped fragment and turn questions into
    /// statements. The new wording halves those refusals with no training (docs/research/professional-instructions-2026-10-28.md);
    /// later rounds train on this line.
    public var line: String {
        switch self {
        case .casual:
            "Register: casual — Write the same message as a relaxed note to a friend or close colleague: conversational wording and contractions, a friendly tone, and real rewording; keep every fact, hedge, negation and intent exactly as spoken."
        case .professional:
            "Register: professional — Write the same message in composed, diplomatic workplace wording, as a careful professional would type it, at the length it was said: a fragment or short reply stays short, and a question stays a question with the same yes/no sense; add nothing that was not said, and keep every name, number, fact, hedge, negation and intent exactly as spoken."
        case .prompt:
            "Register: prompt — Write it as a clear prompt for an AI assistant or agent, in the speaker's own words and order, with mis-heard words and names repaired: keep the speaker's structure (role, steps, requirements, examples) as short paragraphs or lists; a short ask stays one sentence; commands, paths and code the speaker dictated as code in backticks; add nothing that was not said."
        }
    }

    /// The register whose line is one of the lines of `instructions`, if any. This is how the line travels from the
    /// cleaner to the prompt builder, which sees only the instructions string.
    public static func detecting(in instructions: String) -> IntentRegister? {
        let lines = instructions.split(separator: "\n", omittingEmptySubsequences: true)
        return allCases.first { register in lines.contains { $0 == register.line[...] } }
    }
}
