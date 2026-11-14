import Foundation
import Testing
@testable import HushyModelsMLX
@testable import HushyModelsRemote
@testable import MurmurCore

@Suite("Remote LanguageModel (eval-only)")
struct RemoteLanguageModelTests {
    static let tailnet = "tail1234.ts.net"
    static let resolver: RemoteAddressPolicy.Resolver = { host in
        switch host {
        case "studio-pc.tail1234.ts.net": ["100.101.102.103"]
        case "evil.tail1234.ts.net": ["100.101.102.103", "93.184.216.34"]
        case "public.tail1234.ts.net": ["93.184.216.34"]
        default: []
        }
    }

    static func validate(_ raw: String) throws -> URL {
        try RemoteAddressPolicy.validatedURL(raw, tailnet: tailnet, resolve: resolver)
    }

    @Test(arguments: [
        ("http://100.101.102.103:8008", "http://100.101.102.103:8008"), ("http://127.0.0.1:8008/", "http://127.0.0.1:8008"),
        ("http://localhost:8008", "http://localhost:8008"), ("http://[::1]:8008", "http://[::1]:8008"),
        // A tailnet name is pinned to the address it resolved to.
        ("http://studio-pc.tail1234.ts.net:8008", "http://100.101.102.103:8008"),
    ])
    func acceptsLoopbackAndTailscale(_ raw: String, _ expected: String) throws {
        #expect(try Self.validate(raw).absoluteString == expected)
    }

    @Test(arguments: [
        "http://10.0.0.204:8008", "http://192.168.1.5:8008", "http://api.example.com", "http://100.128.0.1:8008",
        "http://100.63.255.1:8008", "ftp://100.101.102.103", "not a url", "http://studio-pc:8008",
        "http://studio-pc.other.ts.net:8008", "http://a.b.tail1234.ts.net:8008", "http://evil.tail1234.ts.net:8008",
        "http://public.tail1234.ts.net:8008", "http://missing.tail1234.ts.net:8008", "http://user:pw@100.101.102.103:8008",
        "http://100.101.102.103:8008/v1", "http://100.101.102.103:8008/?x=1", "http://0x64.99.66.34:8008", "http://100.099.66.34.nip.io",
        // Tailnet hosts are plain http (WireGuard encrypts; the URL is pinned to an IP).
        "https://100.101.102.103:8008", "https://studio-pc.tail1234.ts.net",
    ])
    func refusesEverythingElse(_ raw: String) {
        #expect(throws: LanguageModelError.self) { try Self.validate(raw) }
    }

    @Test func tailnetNamesNeedAConfiguredTailnet() {
        #expect(throws: LanguageModelError.self) {
            try RemoteAddressPolicy.validatedURL("http://studio-pc.tail1234.ts.net:8008", tailnet: nil, resolve: Self.resolver)
        }
    }

    @Test func environment() throws {
        let configuration = try RemoteLanguageModel.Configuration.fromEnvironment([
            "HUSHY_REMOTE_URL": "http://100.101.102.103:8008", "HUSHY_REMOTE_MODEL": "v4-qwen3.5-2b",
            "HUSHY_MLX_PROMPT_PROFILE": "compact", "HUSHY_MLX_TOOL_GRAMMAR": "tool-first",
            "HUSHY_REMOTE_API_KEY": "k0123456789abcdef", "HUSHY_REMOTE_API_KEY_FILE": "/nonexistent",
        ])
        #expect(configuration?.model == "v4-qwen3.5-2b")
        #expect(configuration?.promptProfile == .compact)
        #expect(configuration?.toolGrammar == "tool-first")
        #expect(configuration?.apiKey == "k0123456789abcdef")
        #expect(try RemoteLanguageModel.Configuration.fromEnvironment([:]) == nil)
    }

    @Test func apiKeyFileMustBePrivateAndIsNeverPrinted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try "0123456789abcdef0123456789abcdef\n".write(to: file, atomically: true, encoding: .utf8)
        let environment = ["HUSHY_REMOTE_URL": "http://127.0.0.1:8008", "HUSHY_REMOTE_API_KEY_FILE": file.path]
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: LanguageModelError.self) { try RemoteLanguageModel.Configuration.fromEnvironment(environment) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let configuration = try #require(try RemoteLanguageModel.Configuration.fromEnvironment(environment))
        #expect(configuration.apiKey == "0123456789abcdef0123456789abcdef")
        #expect(!String(describing: configuration).contains("0123456789abcdef"))
        #expect(!String(reflecting: configuration).contains("0123456789abcdef"))
        let model = RemoteLanguageModel(configuration: configuration)
        #expect(!model.identifier.contains("0123456789abcdef"))
    }

    @Test func errorMessagesNeverCarryBodyText() throws {
        let body = Data(#"{"error":{"message":"Invalid value near my secret dictation text","type":"BadRequestError"}}"#.utf8)
        for status in [400, 404, 422, 500, 502] {
            let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            do {
                try RemoteLanguageModel.check(response, data: body)
                Issue.record("HTTP \(status) must throw")
            } catch {
                #expect(!"\(error)".contains("secret") && !"\(error)".contains("Invalid"))
                #expect("\(error)".contains("server error \(status)"))
            }
        }
    }

    @Test func debugBodiesGoToAPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-remote-debug-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        RemoteLanguageModel.saveDebugBody(Data("body text".utf8), in: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        let path = directory.appendingPathComponent(files[0]).path
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "body text")
    }

    /// The request carries exactly what the MLX backend would use: the same system text, the chat
    /// template without thinking, greedy, and the grammar the MLX decoder compiles.
    @Test func requestMatchesTheMLXBackend() throws {
        let instructions = SmartCleaner.instructions
        let schema = SmartCleaner.cleanedSchema
        let system = MLXLanguageModel.systemText(instructions: instructions, schema: schema, profile: .compact)
        #expect(system == CompactCleanupPrompt.systemText(forInstructions: instructions))
        let grammar = try GuidedGrammar.ebnf(for: schema, toolGrammar: "strict")
        #expect(grammar == (try JSONSchemaNode.parse(schema).compactEBNF()))
        let body = RemoteLanguageModel.body(
            model: "m", system: system, prompt: "Transcript: hi\nOutput:", grammar: grammar, temperature: 0, maxTokens: 128)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": system], ["role": "user", "content": "Transcript: hi\nOutput:"]])
        #expect((body["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect((body["structured_outputs"] as? [String: String]) == ["grammar": grammar])
        #expect(body["temperature"] as? Double == 0)
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func toolEnvelopeUsesTheToolAwareGrammar() throws {
        let strict = try GuidedGrammar.ebnf(for: VoiceToolCatalog.envelopeSchema, toolGrammar: "strict")
        let flat = try GuidedGrammar.ebnf(for: VoiceToolCatalog.envelopeSchema, toolGrammar: "flat")
        #expect(strict == (try ToolEnvelopeGrammar.compactEBNF(for: VoiceToolCatalog.envelopeSchema, mode: .strict)))
        #expect(flat == (try JSONSchemaNode.parse(VoiceToolCatalog.envelopeSchema).compactEBNF()))
        #expect(strict != flat)
    }

    @Test func parsesAnswerAndUsage() throws {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"text\":\"Hi.\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":312,"completion_tokens":7}}"#.utf8)
        let answer = try RemoteLanguageModel.parse(data)
        #expect(answer.text == #"{"text":"Hi."}"#)
        #expect(answer.finishReason == "stop")
        #expect(answer.promptTokens == 312 && answer.completionTokens == 7)
        #expect(throws: LanguageModelError.self) { try RemoteLanguageModel.parse(Data("{}".utf8)) }
    }

    @Test func statusCodesMapOntoTheSeam() throws {
        func response(_ code: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        #expect(throws: Never.self) { try RemoteLanguageModel.check(response(200), data: Data()) }
        #expect(throws: LanguageModelError.busy("remote: server error 503: busy")) { try RemoteLanguageModel.check(response(503), data: Data()) }
        #expect(throws: LanguageModelError.self) { try RemoteLanguageModel.check(response(400), data: Data("bad grammar".utf8)) }
        do {
            try RemoteLanguageModel.check(response(401), data: Data())
            Issue.record("401 must throw")
        } catch {
            #expect("\(error)".contains("API key"))
        }
    }

    @Test func answerBudgetCoversTheMLXBudget() {
        // Mirrors the MLX answer budget (floor 96, ceiling 2,048 since the meeting digests) + 256 slack.
        #expect(RemoteLanguageModel.maxAnswerTokens(prompt: "") == 96 + 256)
        let long = String(repeating: "word ", count: 2_000)
        #expect(RemoteLanguageModel.maxAnswerTokens(prompt: long)
            == MLXLanguageModel.answerTokenBudget(promptTokens: (long.utf8.count + 2) / 3) + 256)
        #expect(RemoteLanguageModel.maxAnswerTokens(prompt: long) == 2_048 + 256)
    }

    @Test func unreachableServerFailsAndDisables() async throws {
        var configuration = RemoteLanguageModel.Configuration(baseURL: URL(string: "http://127.0.0.1:9")!, model: "m")
        configuration.requestTimeout = 2
        let model = RemoteLanguageModel(configuration: configuration)
        for _ in 0..<3 {
            await #expect(throws: LanguageModelError.self) {
                try await model.respond(instructions: "x", prompt: "y", schema: SmartCleaner.cleanedSchema, options: .greedy)
            }
        }
        #expect(!model.isAvailable)
        #expect(model.stats.failures == 3)
    }
}
