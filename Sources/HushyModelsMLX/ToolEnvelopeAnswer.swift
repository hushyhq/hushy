import Foundation
import MLXGuidedGeneration
import MurmurCore

/// The exact answer bytes `ToolEnvelopeGrammar` lets the model write for a call, and a check that
/// a string is accepted by that grammar. The tool-calling fine-tune export
/// (`murmur-eval finetune tools-check`, `scripts/finetune/tools`) renders every training answer
/// here and runs it through the real XGrammar matcher, so the model is only ever trained on
/// answers the runtime's constrained decoder could emit.
public enum ToolEnvelopeAnswer {
    /// Grammar modes a fine-tuned model can be trained for (`flat` has no single answer order).
    public static let trainableModes = ["strict", "tool-first"]

    /// `call` as the envelope under `mode` (`strict` or `tool-first`): `tool` first, then every
    /// catalogue argument in the grammar's order — the chosen tool's own arguments with their
    /// values (empty when not given), every other argument forced empty. Nil for an unknown
    /// tool or mode, or a value the envelope can't hold (a string where it wants whole minutes).
    public static func render(_ call: ToolCall, mode: String) -> String? {
        guard let grammarMode = ToolEnvelopeGrammar.Mode(rawValue: mode), grammarMode != .flat,
              let tool = VoiceToolCatalog.tool(named: call.tool),
              case .object(let properties)? = try? JSONSchemaNode.parse(VoiceToolCatalog.envelopeSchema),
              properties.first?.name == "tool"
        else { return nil }
        let arguments = Array(properties.dropFirst())
        let ordered = grammarMode == .toolFirst
            ? arguments.filter { tool.parameter(named: $0.name) != nil } + arguments.filter { tool.parameter(named: $0.name) == nil }
            : arguments
        var out = "{\"tool\":" + JSONSchemaNode.quote(call.tool)
        for property in ordered {
            let value = tool.parameter(named: property.name) != nil ? call.arguments[property.name] : nil
            guard let rendered = render(value, node: property.node) else { return nil }
            out += "," + JSONSchemaNode.quote(property.name) + ":" + rendered
        }
        return out + "}"
    }

    private static func render(_ value: ToolArgumentValue?, node: JSONSchemaNode) -> String? {
        switch (node, value) {
        case (.integer, nil): return "0"
        case (.integer, .integer(let number)?): return number >= 0 ? String(number) : nil
        case (.array, nil): return "[]"
        case (.array, .strings(let items)?): return "[" + items.map(JSONSchemaNode.quote).joined(separator: ",") + "]"
        case (.string, nil), (.enumeration, nil): return "\"\""
        case (.string, .string(let text)?), (.enumeration, .string(let text)?): return JSONSchemaNode.quote(text)
        default: return nil
        }
    }
}

/// Runs strings through the compiled tool-aware grammar with a character-level vocabulary (every
/// ASCII character, plus any other characters the caller will check), so "accepted" means the
/// same XGrammar rules that constrain the model accept every character and then allow the end.
public final class ToolEnvelopeChecker {
    private let constraint: GrammarConstraint
    private let ids: [Unicode.Scalar: Int32]
    private let eos: Int

    /// `extraScalars`: non-ASCII characters that may occur in checked answers (a string with any
    /// other non-ASCII character is reported as not accepted).
    public init(mode: String, extraScalars: Set<Unicode.Scalar> = []) throws {
        guard let grammarMode = ToolEnvelopeGrammar.Mode(rawValue: mode), grammarMode != .flat,
              let grammar = try ToolEnvelopeGrammar.compactEBNF(for: VoiceToolCatalog.envelopeSchema, mode: grammarMode)
        else { throw LanguageModelError.unsupportedSchema("tool envelope grammar mode \(mode)") }
        let extras = extraScalars.filter { !$0.isASCII }.sorted { $0.value < $1.value }
        let vocab = (0..<128).map { String(UnicodeScalar(UInt8($0))) } + extras.map { String($0) } + ["<eos>"]
        var ids: [Unicode.Scalar: Int32] = [:]
        for (index, piece) in vocab.dropLast().enumerated() { ids[piece.unicodeScalars.first!] = Int32(index) }
        self.ids = ids
        self.eos = vocab.count - 1
        let tokenizer = try GrammarTokenizer(vocab: vocab, vocabType: .raw, eosTokenId: Int32(eos))
        constraint = try GrammarConstraint(tokenizer: tokenizer, grammar: grammar, fastForward: false, hostTokenizer: nil)
    }

    /// Whether the grammar accepts `answer` as a complete answer. The matcher is reset afterwards.
    public func accepts(_ answer: String) -> Bool {
        var committed: Int32 = 0
        defer { if committed > 0 { try? constraint.rollback(committed) } }
        for scalar in answer.unicodeScalars {
            guard let id = ids[scalar] else { return false }
            do {
                let result = try constraint.commitToken(id)
                committed += 1
                if result.isTerminated { return false }
            } catch {
                return false
            }
        }
        guard let mask = try? constraint.computeMask() else { return false }
        guard mask.needsApply else { return true }
        let word = eos / 32, bit = eos % 32
        return word < mask.mask.count && (UInt32(bitPattern: mask.mask[word]) >> UInt32(bit)) & 1 == 1
    }
}
