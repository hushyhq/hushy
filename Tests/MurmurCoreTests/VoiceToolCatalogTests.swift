import Foundation
import Testing
@testable import MurmurCore

/// Tool schema v1 (`VoiceToolCatalog`): the closed catalogue the local model, the Apple path and
/// `murmur-eval tools` share.
@Suite("Voice tool catalogue (tools-v1)")
struct VoiceToolCatalogTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("names the v1 tools, unique, including every connected propose_* tool and no_action")
    func names() {
        let names = VoiceToolCatalog.names
        #expect(Set(names).count == names.count)
        for required in ["create_reminder", "create_event", "add_to_list", "save_note", "open_app", "run_shortcut", "set_timer", "no_action"] {
            #expect(names.contains(required), "missing \(required)")
        }
        #expect(Set(ConnectedProposalTools.names).isSubset(of: Set(names)), "connected tools must keep their MCP names")
    }

    @Test("a parameter name means the same kind in every tool (the flat envelope depends on it)")
    func parameterKindsAreConsistent() {
        var kinds: [String: VoiceToolParameter.Kind] = [:]
        for parameter in VoiceToolCatalog.tools.flatMap(\.parameters) {
            if let seen = kinds[parameter.name] {
                #expect(seen == parameter.kind, "\(parameter.name) has two kinds")
            }
            kinds[parameter.name] = parameter.kind
        }
    }

    @Test("every tool has a description and at least one required parameter")
    func toolsAreComplete() {
        for tool in VoiceToolCatalog.tools {
            #expect(!tool.description.isEmpty)
            #expect(!tool.requiredParameters.isEmpty, "\(tool.name) has no required parameter")
        }
    }

    @Test("the published catalogue is valid JSON and matches Evals/tools-v1.schema.json")
    func catalogueSnapshot() throws {
        let json = VoiceToolCatalog.catalogJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["version"] as? String == VoiceToolCatalog.version)
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.count == VoiceToolCatalog.tools.count)
        let snapshot = try String(contentsOf: Self.packageRoot.appendingPathComponent("Evals/tools-v1.schema.json"), encoding: .utf8)
        #expect(snapshot == json, "regenerate with: murmur-eval tools --print-catalog > Evals/tools-v1.schema.json")
    }

    @Test("the envelope schema lists tool first, then every parameter once, all required")
    func envelopeSchema() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(VoiceToolCatalog.envelopeSchema.json.utf8)) as? [String: Any])
        let order = try #require(object["x-order"] as? [String])
        #expect(order.first == "tool")
        #expect(order.count == VoiceToolCatalog.allParameters.count + 1)
        #expect(Set(object["required"] as? [String] ?? []) == Set(order))
        let properties = try #require(object["properties"] as? [String: Any])
        let tool = try #require(properties["tool"] as? [String: Any])
        #expect(tool["enum"] as? [String] == VoiceToolCatalog.names)
    }

    @Test("decoding the envelope keeps only the chosen tool's non-empty arguments")
    func decodeEnvelope() throws {
        let json = """
            {"tool":"create_reminder","title":"call the plumber","when":"tomorrow at 9","list":"","items":[],
             "duration_minutes":0,"target":"slack","reason":""}
            """
        let call = try #require(ToolCall(envelopeJSON: json))
        #expect(call == ToolCall(tool: "create_reminder", arguments: ["title": .string("call the plumber"), "when": .string("tomorrow at 9")]))
        #expect(call.validationIssues().isEmpty)
        #expect(ToolCall(envelopeJSON: #"{"tool":"send_money","amount":"5"}"#) == nil)
        #expect(ToolCall(envelopeJSON: "not json") == nil)
    }

    @Test("validation flags unknown tools and arguments, missing required ones, bad enums and types")
    func validation() {
        #expect(ToolCall(tool: "wire_transfer").validationIssues() == ["unknown tool wire_transfer"])
        #expect(ToolCall(tool: "open_app").validationIssues() == ["open_app: missing target"])
        #expect(!ToolCall(tool: "open_app", arguments: ["target": .string("x"), "when": .string("now")]).validationIssues().isEmpty)
        #expect(!ToolCall(tool: "propose_message", arguments: [
            "channel": .string("fax"), "recipient": .string("dana"), "text": .string("hi"),
        ]).validationIssues().isEmpty)
        #expect(!ToolCall(tool: "add_to_list", arguments: ["items": .string("eggs"), "list": .string("groceries")]).validationIssues().isEmpty)
        #expect(!ToolCall(tool: "create_event", arguments: [
            "title": .string("x"), "when": .string("now"), "duration_minutes": .integer(2),
        ]).validationIssues().isEmpty)
        #expect(ToolCall.noAction(.multiIntent).validationIssues().isEmpty)
        #expect(ToolCall.noAction(.sensitiveContent).noActionReason == .sensitiveContent)
    }

    @Test("ToolCall round-trips as compact {tool, args} JSON")
    func codable() throws {
        let call = ToolCall(tool: "add_to_list", arguments: ["items": .strings(["eggs", "milk"]), "list": .string("groceries")])
        let data = try JSONEncoder().encode(call)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"args\""))
        #expect(try JSONDecoder().decode(ToolCall.self, from: data) == call)
        let timer = try JSONDecoder().decode(ToolCall.self, from: Data(#"{"tool":"set_timer","args":{"duration":600}}"#.utf8))
        #expect(timer.arguments["duration"] == .integer(600))
    }

    @Test("the shipping extractor's actions map onto catalogue calls")
    func proposedActionMapping() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let reminder = ProposedAction(kind: .createReminder, title: "pay rent", start: now, listName: "Home",
                                      dateSourcePhrase: "tomorrow", sourceText: "x")
        #expect(ToolCall(proposedAction: reminder, timeZone: zone) == ToolCall(tool: "create_reminder", arguments: [
            "title": .string("pay rent"), "when": .string("tomorrow"), "list": .string("Home"),
        ]))
        let event = ProposedAction(kind: .createEvent, title: "sync", start: now, end: now.addingTimeInterval(3600),
                                   location: "Room 4", sourceText: "x")
        let mapped = ToolCall(proposedAction: event, timeZone: zone)
        #expect(mapped.tool == "create_event")
        #expect(mapped.arguments["duration_minutes"] == .integer(60))
        #expect(mapped.arguments["when"] == .string("2026-09-21T19:43:20+05:30"))
        let shortcut = ProposedAction(kind: .runShortcut, title: "Log Water", shortcutName: "Log Water", shortcutInput: "500", sourceText: "x")
        #expect(ToolCall(proposedAction: shortcut) == ToolCall(tool: "run_shortcut", arguments: [
            "name": .string("Log Water"), "input": .string("500"),
        ]))
    }
}
