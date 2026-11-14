import Foundation
import MurmurCore

/// The grammar an answer is constrained to, as XGrammar EBNF text: the tools-v1 envelope's
/// tool-aware grammar (`ToolEnvelopeGrammar`, per `toolGrammar` mode) or the schema's compact
/// grammar (`JSONSchemaNode.compactEBNF`). The MLX decoder compiles this text (`GrammarCache`),
/// and `HushyModelsRemote` sends the same text to an OpenAI-compatible server's xgrammar backend,
/// so the two backends accept exactly the same answers.
package enum GuidedGrammar {
    package static func ebnf(for schema: GenerationSchemaSpec, toolGrammar: String) throws -> String {
        try ebnf(for: schema, mode: ToolEnvelopeGrammar.Mode(rawValue: toolGrammar) ?? .strict)
    }

    static func ebnf(for schema: GenerationSchemaSpec, mode: ToolEnvelopeGrammar.Mode) throws -> String {
        try ToolEnvelopeGrammar.compactEBNF(for: schema, mode: mode) ?? JSONSchemaNode.parse(schema).compactEBNF()
    }
}
