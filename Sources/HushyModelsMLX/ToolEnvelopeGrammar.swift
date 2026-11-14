import Foundation
import MurmurCore

/// A tool-aware grammar for the tools-v1 flat envelope (`VoiceToolCatalog.envelopeSchema`).
///
/// The envelope lists every argument of every tool (24 today) as a required field, left empty
/// when the chosen tool doesn't use it. With the generic compact grammar each of those empties is
/// the model's choice, so a call spends ~2 sampled tokens (a forward pass each) per unused
/// argument — 40–60 passes of pure structure — and a weak model can fill them with junk. Here the
/// grammar branches on the tool name, which comes first: after it, every argument that tool
/// doesn't take is a literal (`"when":""`, `"duration_minutes":0`, `"items":[]`), so XGrammar
/// jump-forwards the whole run between used arguments and the model writes only real values.
///
/// It accepts a subset of what the flat grammar accepts, and exactly the answers
/// `ToolCall(envelopeJSON:)` would read the same way (it keeps only the chosen tool's arguments),
/// so nothing a caller uses changes. The chosen tool's enumerated arguments (`channel`,
/// `tracker`, `no_action`'s `reason`) are limited to their values. In `strict` mode (the default)
/// its required arguments must also be non-empty. Any schema this doesn't recognise returns nil
/// (the caller uses the generic grammar).
enum ToolEnvelopeGrammar {
    enum Mode: String, Sendable, CaseIterable {
        /// The generic compact grammar: every argument is the model's choice.
        case flat
        /// Unused arguments forced empty; enumerated arguments limited to their values.
        case aware
        /// `aware`, and the chosen tool's required arguments non-empty.
        case strict
        /// `strict` with the chosen tool's arguments first and the empties after them: once the
        /// last real argument closes, the rest is forced and never fed to the model. A different
        /// key order than `x-order` (JSON readers don't care; a fine-tuned model must be trained
        /// on it — see INFERENCE-OPTIMIZATION.md).
        case toolFirst = "tool-first"
    }

    static func compactEBNF(for spec: GenerationSchemaSpec, mode: Mode = .aware) throws -> String? {
        guard mode != .flat, spec.name == VoiceToolCatalog.envelopeSchema.name, spec.json == VoiceToolCatalog.envelopeSchema.json,
              case .object(let properties) = try JSONSchemaNode.parse(spec),
              let first = properties.first, first.name == "tool", case .enumeration(let tools) = first.node
        else { return nil }

        var rules: [String] = []
        var alternatives: [String] = []
        for (index, name) in tools.enumerated() {
            guard let tool = VoiceToolCatalog.tool(named: name) else { return nil }
            var parts: [Part] = [.literal("{\"tool\":" + JSONSchemaNode.quote(name))]
            let arguments = Array(properties.dropFirst())
            let ordered = mode == .toolFirst
                ? arguments.filter { tool.parameter(named: $0.name) != nil } + arguments.filter { tool.parameter(named: $0.name) == nil }
                : arguments
            for property in ordered {
                let key = "," + JSONSchemaNode.quote(property.name) + ":"
                if let parameter = tool.parameter(named: property.name) {
                    guard let value = valueRule(property.node, parameter: parameter, strict: mode != .aware) else { return nil }
                    parts += [.literal(key), .rule(value)]
                } else {
                    guard let empty = emptyValue(property.node) else { return nil }
                    parts.append(.literal(key + empty))
                }
            }
            parts.append(.literal("}"))
            rules.append("t\(index) ::= " + merged(parts))
            alternatives.append("t\(index)")
        }
        let more = JSONSchemaNode.defaultMaxItems - 1
        let helpers = [
            "sarr ::= \"[\" (jstr (\",\" jstr){0,\(more)})? \"]\"",
            "sarrne ::= \"[\" jstrne (\",\" jstrne){0,\(more)} \"]\"",
            "jstrne ::= \"\\\"\" jchar+ \"\\\"\"",
        ]
        return (["root ::= " + alternatives.joined(separator: " | ")] + rules + helpers + JSONSchemaNode.stringRules)
            .joined(separator: "\n")
    }

    private enum Part {
        case literal(String)
        case rule(String)
    }

    /// Adjacent literals joined into one, then rendered as an EBNF sequence.
    private static func merged(_ parts: [Part]) -> String {
        var out: [String] = []
        var pending = ""
        for part in parts {
            switch part {
            case .literal(let text): pending += text
            case .rule(let rule):
                if !pending.isEmpty { out.append(JSONSchemaNode.literal(pending)) }
                pending = ""
                out.append(rule)
            }
        }
        if !pending.isEmpty { out.append(JSONSchemaNode.literal(pending)) }
        return out.joined(separator: " ")
    }

    private static func valueRule(_ node: JSONSchemaNode, parameter: VoiceToolParameter, strict: Bool) -> String? {
        let nonEmpty = strict && parameter.isRequired
        if case .enumeration(let values) = parameter.kind {
            guard node == .string || node == .enumeration(values) else { return nil }
            let options = values.map { JSONSchemaNode.literal(JSONSchemaNode.quote($0)) }
                + (parameter.isRequired ? [] : [JSONSchemaNode.literal("\"\"")])
            return "(" + options.joined(separator: " | ") + ")"
        }
        switch node {
        case .string: return nonEmpty ? "jstrne" : "jstr"
        case .integer: return "(\"0\" | [1-9] [0-9]{0,8})"
        case .array(.string, _): return nonEmpty ? "sarrne" : "sarr"
        default: return nil
        }
    }

    private static func emptyValue(_ node: JSONSchemaNode) -> String? {
        switch node {
        case .string: "\"\""
        case .integer: "0"
        case .array: "[]"
        default: nil
        }
    }
}
