import Foundation
import MurmurCore

/// The subset of JSON Schema that Hushy's `GenerationSchemaSpec`s use (the form Apple's
/// `GenerationSchema` encodes to), parsed into a tree the constrained decoder can walk.
///
/// Supported: `object` (properties emitted in `x-order`, else `required` order, else name
/// order), `string` (optionally with `enum`), `boolean`, `integer`, `array` of any supported node
/// (with optional `maxItems`), and `$ref` into `$defs`/`definitions`. Anything else throws
/// `LanguageModelError.unsupportedSchema`, so the call fails fast and the caller falls back.
indirect enum JSONSchemaNode: Equatable, Sendable {
    case object(properties: [Property])
    case string
    case enumeration([String])
    case boolean
    case integer
    case array(items: JSONSchemaNode, maxItems: Int)
    /// `anyOf` of one node and `{"type": "null"}`: the node or `null` (the meeting-extract answer's owner and due).
    case nullable(JSONSchemaNode)

    struct Property: Equatable, Sendable {
        let name: String
        let node: JSONSchemaNode
    }

    /// Arrays without `maxItems` stop after this many items (a runaway-list guard, not a limit
    /// any current schema relies on: the largest asks for "0 to 3" actions).
    static let defaultMaxItems = 8
    /// The meeting-extract answer lists every record of a ~1,800-word chunk; its schema (fixed by training) has no
    /// `maxItems`, so it gets a looser runaway guard than the default.
    static let meetingRecordsMaxItems = 48
    private static let maxDepth = 8

    static func parse(_ spec: GenerationSchemaSpec) throws -> JSONSchemaNode {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(spec.json.utf8))
        } catch {
            throw LanguageModelError.unsupportedSchema("\(spec.name): not JSON (\(error.localizedDescription))")
        }
        guard let root = object as? [String: Any] else {
            throw LanguageModelError.unsupportedSchema("\(spec.name): root is not an object")
        }
        let definitions = (root["$defs"] as? [String: Any] ?? [:])
            .merging(root["definitions"] as? [String: Any] ?? [:]) { first, _ in first }
        let maxItems = spec.name == MeetingExtractPrompt.schemaName ? meetingRecordsMaxItems : defaultMaxItems
        return try node(root, definitions: definitions, name: spec.name, depth: 0, maxItems: maxItems)
    }

    private static func node(
        _ raw: [String: Any], definitions: [String: Any], name: String, depth: Int, maxItems: Int
    ) throws -> JSONSchemaNode {
        guard depth <= maxDepth else { throw LanguageModelError.unsupportedSchema("\(name): nested too deeply") }
        if let ref = raw["$ref"] as? String {
            let key = ref.split(separator: "/").last.map(String.init) ?? ref
            guard ref.hasPrefix("#/"), let target = definitions[key] as? [String: Any] else {
                throw LanguageModelError.unsupportedSchema("\(name): unresolved $ref \(ref)")
            }
            return try node(target, definitions: definitions, name: name, depth: depth + 1, maxItems: maxItems)
        }
        if let values = raw["enum"] as? [Any] {
            let strings = values.compactMap { $0 as? String }
            guard !strings.isEmpty, strings.count == values.count else {
                throw LanguageModelError.unsupportedSchema("\(name): only non-empty string enums are supported")
            }
            return .enumeration(strings)
        }
        if let options = raw["anyOf"] as? [[String: Any]] {
            let others = options.filter { $0["type"] as? String != "null" }
            guard options.count == 2, others.count == 1 else {
                throw LanguageModelError.unsupportedSchema("\(name): anyOf is supported only as one type or null")
            }
            return .nullable(try node(others[0], definitions: definitions, name: name, depth: depth + 1, maxItems: maxItems))
        }
        switch raw["type"] as? String {
        case "string": return .string
        case "boolean": return .boolean
        case "integer": return .integer
        case "array":
            guard let items = raw["items"] as? [String: Any] else {
                throw LanguageModelError.unsupportedSchema("\(name): array without items")
            }
            let limit = (raw["maxItems"] as? Int).map { max(0, $0) } ?? maxItems
            return .array(items: try node(items, definitions: definitions, name: name, depth: depth + 1, maxItems: maxItems), maxItems: limit)
        case "object":
            let properties = raw["properties"] as? [String: Any] ?? [:]
            let order = orderedNames(raw, properties: properties)
            return .object(properties: try order.map { key in
                guard let child = properties[key] as? [String: Any] else {
                    throw LanguageModelError.unsupportedSchema("\(name): property \(key) has no schema")
                }
                return Property(name: key, node: try node(child, definitions: definitions, name: name, depth: depth + 1, maxItems: maxItems))
            })
        case let other:
            throw LanguageModelError.unsupportedSchema("\(name): unsupported type \(other ?? "nil")")
        }
    }

    /// `x-order` is what Apple's encoder writes and what the model sees; every property is always
    /// emitted (all current schemas mark every property required).
    private static func orderedNames(_ raw: [String: Any], properties: [String: Any]) -> [String] {
        var names = (raw["x-order"] as? [String]) ?? (raw["required"] as? [String]) ?? []
        names = names.filter { properties[$0] != nil }
        for key in properties.keys.sorted() where !names.contains(key) { names.append(key) }
        return names
    }
}

// MARK: - Compact EBNF

extension JSONSchemaNode {
    /// An XGrammar EBNF grammar for exactly this schema's JSON in *compact* form: fixed key order
    /// (`x-order`), no whitespace anywhere. That is why we don't hand XGrammar the raw JSON Schema
    /// (its converter allows optional whitespace between tokens): with no free choices in the
    /// structure, every brace, key, colon and comma is forced, so jump-forward feeds them without
    /// sampling and the model generates only the values — fewer generated tokens per call.
    func compactEBNF() -> String {
        var rules: [String] = []
        let root = rule(for: self, rules: &rules)
        return (["root ::= \(root)"] + rules + Self.stringRules).joined(separator: "\n")
    }

    /// JSON string: any char except `"`, `\` and control characters, or an escape.
    static let stringRules = [
        #"jstr ::= "\"" jchar* "\"""#,
        #"jchar ::= [^"\\\x00-\x1f] | "\\" ["\\/bfnrt] | "\\u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]"#,
    ]

    /// Returns an EBNF expression for `node`, appending named rules for compound nodes.
    private func rule(for node: JSONSchemaNode, rules: inout [String]) -> String {
        switch node {
        case .string: return "jstr"
        case .boolean: return #"("true" | "false")"#
        case .integer: return #"("0" | [1-9] [0-9]{0,8})"#
        case .nullable(let inner):
            return "(" + rule(for: inner, rules: &rules) + " | \"null\")"
        case .enumeration(let options):
            return "(" + options.map { Self.literal(Self.quote($0)) }.joined(separator: " | ") + ")"
        case .array(let items, let maxItems):
            let slot = rules.count
            let name = "r\(slot)"
            rules.append("")  // reserve the slot so nested rules get later numbers
            let item = rule(for: items, rules: &rules)
            let body = maxItems <= 0 ? "" : maxItems == 1 ? "(\(item))?" : "(\(item) (\",\" \(item)){0,\(maxItems - 1)})?"
            rules[slot] = "\(name) ::= \"[\" \(body) \"]\""
            return name
        case .object(let properties):
            let slot = rules.count
            let name = "r\(slot)"
            rules.append("")
            var parts: [String] = []
            for (index, property) in properties.enumerated() {
                let key = (index == 0 ? "{" : ",") + Self.quote(property.name) + ":"
                parts.append(Self.literal(key))
                parts.append(rule(for: property.node, rules: &rules))
            }
            parts.append(Self.literal(properties.isEmpty ? "{}" : "}"))
            rules[slot] = "\(name) ::= " + parts.joined(separator: " ")
            return name
        }
    }

    /// An EBNF string literal for `text`.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `text` as a JSON string literal.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case let control where control.value < 0x20: out += String(format: "\\u%04x", control.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
