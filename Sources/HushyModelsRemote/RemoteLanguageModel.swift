import Foundation
import HushyModelsMLX
import MurmurCore
import Synchronization

/// **Eval-only.** `LanguageModel` over an OpenAI-compatible server on the founder's CUDA box
/// (vLLM, `scripts/gpu/serve/serve.sh`), reached over Tailscale, so `murmur-eval` can run the
/// model half of an eval off the Mac (`--backend remote`). The shipping app never links this
/// target (`RemoteBackendIsolationTests`); nothing here is a product feature.
///
/// Parity with `MLXLanguageModel` by construction:
/// - the same system message (`MLXLanguageModel.systemText(instructions:schema:profile:)`, so
///   `compact` swaps in `CompactCleanupPrompt` for cleanup calls exactly as on the Mac);
/// - the same chat template (the server renders the checkpoint's own template with
///   `enable_thinking: false`, as `MLXEngine` does);
/// - the same answer grammar (`GuidedGrammar.ebnf`: the tools-v1 envelope's `strict`/`tool-first`
///   grammar or the schema's compact grammar), sent as xgrammar EBNF (`structured_outputs.grammar`);
/// - greedy at temperature 0 (the server ignores the checkpoint's sampling defaults), 0.7 for
///   `.systemDefault`.
/// What differs: bf16 CUDA kernels instead of MLX 4-bit Metal ones (serve `--quant mlx4` for the
/// Mac's exact 4-bit weights), no jump-forward (forced JSON is decoded token by token under the
/// mask, so it can tokenize differently), and the answer budget is estimated from the prompt's
/// length rather than counted in tokens. `.claude/GPU-TRAINING.md` has the measured agreement.
///
/// Failures map onto the seam like the MLX adapter's: HTTP 429/503 → `.busy`; a 400 about the
/// grammar → `.unsupportedSchema`; a cut-off answer → `.malformedOutput`; anything else →
/// `.unavailable`, and `maxConsecutiveFailures` of those in a row make the model `.unavailable`
/// for the process. Cancellation cancels the HTTP request.
public final class RemoteLanguageModel: LanguageModel {
    public struct Configuration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        /// The server's base URL, e.g. `http://100.101.102.103:8008` (no `/v1`); checked by
        /// `RemoteAddressPolicy` when it comes from the environment.
        public var baseURL: URL
        /// The served model name; nil = the only model the server lists.
        public var model: String?
        /// Bearer key for the server's `/v1` routes (`~/hushy-train/serve/api-key` on the box).
        /// Sent only in the Authorization header; never printed (`description` redacts it).
        public var apiKey: String?
        /// Which system prompt cleanup calls use (same meaning as on the MLX backend).
        public var promptProfile: MLXLanguageModel.PromptProfile = .production
        /// Tools-v1 envelope grammar (`strict`, `aware`, `flat`, `tool-first`), as on the MLX backend.
        public var toolGrammar = "strict"
        public var requestTimeout: TimeInterval = 300
        /// `--remote-debug`: write each error response body to a mode-600 file in this directory
        /// (bodies can echo request text, so they are never put in an error message or a log).
        public var debugDirectory: URL?
        public var maxConsecutiveFailures = 3
        public var languages: Set<String> = ["en", "es", "fr", "de", "it", "pt"]

        /// Where `scripts/gpu/fetch-api-key.sh` stores the server's key on the Mac.
        public static let defaultKeyFile = "~/.config/hushy/gpu-serve-api-key"

        public init(baseURL: URL, model: String? = nil, apiKey: String? = nil) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }

        public var description: String {
            "remote(\(baseURL.absoluteString), model: \(model ?? "auto"), key: \(apiKey == nil ? "none" : "set"))"
        }

        public var debugDescription: String { description }

        /// `HUSHY_REMOTE_URL` (+ `HUSHY_REMOTE_TAILNET`, `HUSHY_REMOTE_MODEL`, `HUSHY_REMOTE_API_KEY` or
        /// the key file `HUSHY_REMOTE_API_KEY_FILE` / `defaultKeyFile`, `HUSHY_MLX_PROMPT_PROFILE`,
        /// `HUSHY_MLX_TOOL_GRAMMAR`).
        public static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment,
            resolve: @escaping RemoteAddressPolicy.Resolver = RemoteAddressPolicy.resolveIPv4
        ) throws -> Configuration? {
            guard let raw = environment["HUSHY_REMOTE_URL"], !raw.isEmpty else { return nil }
            let url = try RemoteAddressPolicy.validatedURL(raw, tailnet: environment["HUSHY_REMOTE_TAILNET"], resolve: resolve)
            var configuration = Configuration(baseURL: url)
            if let model = environment["HUSHY_REMOTE_MODEL"], !model.isEmpty { configuration.model = model }
            configuration.apiKey = try apiKey(environment)
            if let profile = environment["HUSHY_MLX_PROMPT_PROFILE"].flatMap(MLXLanguageModel.PromptProfile.init(rawValue:)) {
                configuration.promptProfile = profile
            }
            if let grammar = environment["HUSHY_MLX_TOOL_GRAMMAR"], !grammar.isEmpty { configuration.toolGrammar = grammar }
            return configuration
        }

        /// The key from `HUSHY_REMOTE_API_KEY`, else from the key file if it exists. A key file
        /// readable by group or others is refused (like ssh does with private keys).
        static func apiKey(_ environment: [String: String]) throws -> String? {
            if let key = environment["HUSHY_REMOTE_API_KEY"], !key.isEmpty { return key }
            let path = NSString(string: environment["HUSHY_REMOTE_API_KEY_FILE"] ?? defaultKeyFile).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode & 0o077 != 0 {
                throw LanguageModelError.unavailable("remote: \(path) is readable by others; chmod 600 it")
            }
            let key = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.range(of: "^[A-Za-z0-9._-]{16,256}$", options: .regularExpression) != nil else {
                throw LanguageModelError.unavailable("remote: \(path) does not hold an API key")
            }
            return key
        }
    }

    public struct Stats: Sendable, Equatable {
        public var calls = 0
        public var successes = 0
        public var failures = 0
        public var cancellations = 0
        public var promptTokens = 0
        public var completionTokens = 0
        public var milliseconds: Double = 0
    }

    /// One call's server-side view (usage) and wall time.
    public struct CallTimings: Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalMilliseconds: Double
    }

    private struct State {
        var stats = Stats()
        var consecutiveFailures = 0
        var disabledReason: String?
        var servedModel: String?
        var contextWindow: Int?
    }

    public let configuration: Configuration
    private let session: URLSession
    private let state = Mutex(State())

    public init(configuration: Configuration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.requestTimeout
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.httpMaximumConnectionsPerHost = 16
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The redirect-refusing delegate keeps every request on the address `RemoteAddressPolicy`
        // approved: a 3xx comes back as the response and fails `check`.
        self.session = URLSession(configuration: sessionConfiguration, delegate: RefuseRedirects(), delegateQueue: nil)
        state.withLock { $0.servedModel = configuration.model }
    }

    public var identifier: String {
        "remote:\(state.withLock { $0.servedModel } ?? configuration.baseURL.host() ?? "?")"
    }

    public var stats: Stats { state.withLock { $0.stats } }

    /// The served model's context window (`max_model_len` from `/v1/models`), known after `connect()`.
    /// A caller sizing long prompts (meeting digests) should use it rather than Apple's 4,096.
    public var contextWindow: Int? { state.withLock { $0.contextWindow } }

    public var availability: LanguageModelAvailability {
        if let reason = state.withLock({ $0.disabledReason }) { return .unavailable(reason: reason) }
        return .available
    }

    public func supportsLanguage(_ languageCode: String) -> Bool {
        configuration.languages.contains(languageCode.lowercased())
    }

    /// Asks the server for its model list and checks the configured name is served (or picks the
    /// only one). murmur-eval calls it once at start so a wrong URL fails before any case runs.
    @discardableResult
    public func connect() async throws -> String {
        var request = URLRequest(url: endpoint("models"))
        authorize(&request)
        let (data, response) = try await send(request)
        try check(response, data: data)
        let cards = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let names = cards.compactMap { $0["id"] as? String }
        let chosen: String
        if let wanted = configuration.model {
            guard names.contains(wanted) else {
                throw LanguageModelError.unavailable("remote: model \(wanted) not served (server has \(names.joined(separator: ", ")))")
            }
            chosen = wanted
        } else {
            guard names.count == 1, let only = names.first else {
                throw LanguageModelError.unavailable("remote: pass --remote-model (server has \(names.joined(separator: ", ")))")
            }
            chosen = only
        }
        let window = cards.first { $0["id"] as? String == chosen }?["max_model_len"] as? Int
        state.withLock {
            $0.servedModel = chosen
            $0.contextWindow = window
        }
        return chosen
    }

    /// The server keeps its own prefix cache; a one-token request with this system text fills it.
    public func prewarm(instructions: String) {
        Task.detached(priority: .utility) { [self] in await prefixCache(instructions: instructions) }
    }

    public func prefixCache(instructions: String) async {
        let system = MLXLanguageModel.systemText(
            instructions: instructions, schema: SmartCleaner.cleanedSchema, profile: configuration.promptProfile)
        _ = try? await complete(system: system, prompt: "A", grammar: nil, temperature: 0, maxTokens: 1)
    }

    public func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        try await respondMeasured(instructions: instructions, prompt: prompt, schema: schema, options: options).json
    }

    public func respondMeasured(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> (json: String, timings: CallTimings) {
        if case .unavailable(let reason) = availability { throw LanguageModelError.unavailable(reason) }
        state.withLock { $0.stats.calls += 1 }
        let start = ContinuousClock.now
        do {
            let grammar: String
            do {
                grammar = try GuidedGrammar.ebnf(for: schema, toolGrammar: configuration.toolGrammar)
            } catch let error as LanguageModelError {
                throw error
            } catch {
                throw LanguageModelError.unsupportedSchema("\(schema.name): \(error)")
            }
            let system = MLXLanguageModel.systemText(instructions: instructions, schema: schema, profile: configuration.promptProfile)
            let answer = try await complete(
                system: system, prompt: prompt, grammar: grammar,
                temperature: options.sampling == .greedy ? 0 : 0.7, maxTokens: Self.maxAnswerTokens(prompt: prompt))
            guard answer.finishReason != "length" else {
                throw LanguageModelError.malformedOutput("remote: answer hit the token budget")
            }
            let elapsed = Self.milliseconds(since: start)
            state.withLock {
                $0.stats.successes += 1
                $0.consecutiveFailures = 0
                $0.stats.promptTokens += answer.promptTokens
                $0.stats.completionTokens += answer.completionTokens
                $0.stats.milliseconds += elapsed
            }
            return (answer.text, CallTimings(
                promptTokens: answer.promptTokens, completionTokens: answer.completionTokens, totalMilliseconds: elapsed))
        } catch is CancellationError {
            state.withLock { $0.stats.cancellations += 1 }
            throw CancellationError()
        } catch let error as LanguageModelError {
            record(error)
            throw error
        } catch {
            let mapped = LanguageModelError.unavailable("remote: \(error.localizedDescription)")
            record(mapped)
            throw mapped
        }
    }

    // MARK: - HTTP

    struct Answer {
        var text: String
        var finishReason: String?
        var promptTokens: Int
        var completionTokens: Int
    }

    private func complete(system: String, prompt: String, grammar: String?, temperature: Double, maxTokens: Int) async throws -> Answer {
        let model = try await servedModel()
        var request = URLRequest(url: endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(
            model: model, system: system, prompt: prompt, grammar: grammar, temperature: temperature, maxTokens: maxTokens))
        let (data, response) = try await send(request)
        try check(response, data: data)
        return try Self.parse(data)
    }

    /// The chat-completions request body (tested for shape in `RemoteLanguageModelTests`).
    static func body(model: String, system: String, prompt: String, grammar: String?, temperature: Double, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "seed": 0,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        if let grammar { body["structured_outputs"] = ["grammar": grammar] }
        return body
    }

    static func parse(_ data: Data) throws -> Answer {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any], let text = message["content"] as? String
        else { throw LanguageModelError.malformedOutput("remote: unexpected response shape") }
        let usage = object["usage"] as? [String: Any]
        return Answer(
            text: text, finishReason: choice["finish_reason"] as? String,
            promptTokens: usage?["prompt_tokens"] as? Int ?? 0, completionTokens: usage?["completion_tokens"] as? Int ?? 0)
    }

    /// Maps a non-2xx response onto the seam. Messages carry only the status and a fixed category,
    /// never body text (a server error can quote the request, i.e. dev-set text); with
    /// `debugDirectory` set the body goes to a local mode-600 file instead.
    private func check(_ response: URLResponse, data: Data) throws {
        do {
            try Self.check(response, data: data)
        } catch {
            if let directory = configuration.debugDirectory, !data.isEmpty { Self.saveDebugBody(data, in: directory) }
            throw error
        }
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LanguageModelError.unavailable("remote: no HTTP response") }
        let status = http.statusCode
        guard !(200..<300).contains(status) else { return }
        switch status {
        case 300..<400: throw LanguageModelError.unavailable("remote: server error \(status): redirect refused")
        case 429, 503: throw LanguageModelError.busy("remote: server error \(status): busy")
        case 401, 403:
            throw LanguageModelError.unavailable("remote: server error \(status): API key missing or wrong (scripts/gpu/fetch-api-key.sh)")
        case 404: throw LanguageModelError.unavailable("remote: server error 404: not found (model name?)")
        case 400 where String(decoding: data.prefix(4_096), as: UTF8.self).lowercased().contains("grammar"):
            throw LanguageModelError.unsupportedSchema("remote: server error 400: grammar rejected")
        case 400..<500: throw LanguageModelError.unavailable("remote: server error \(status): bad request")
        default: throw LanguageModelError.unavailable("remote: server error \(status): server failure")
        }
    }

    static func saveDebugBody(_ data: Data, in directory: URL) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("remote-error-\(UUID().uuidString).txt")
            guard manager.createFile(atPath: file.path, contents: data.prefix(65_536), attributes: [.posixPermissions: 0o600]) else { return }
            FileHandle.standardError.write(Data("remote: error body saved to \(file.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("remote: could not save the error body (\(error.localizedDescription))\n".utf8))
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func authorize(_ request: inout URLRequest) {
        if let key = configuration.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    private func servedModel() async throws -> String {
        if let name = state.withLock({ $0.servedModel }) { return name }
        return try await connect()
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appending(path: "v1").appending(path: path)
    }

    // MARK: - Bookkeeping

    private func record(_ error: LanguageModelError) {
        state.withLock {
            $0.stats.failures += 1
            guard case .unavailable = error else { return }
            $0.consecutiveFailures += 1
            if $0.consecutiveFailures >= configuration.maxConsecutiveFailures {
                $0.disabledReason = "remote disabled after \($0.consecutiveFailures) consecutive failures (\(error))"
            }
        }
    }

    /// The MLX decoder's budget (`MLXLanguageModel.answerTokenBudget`: about 2 × the user prompt's
    /// tokens, clamped, counting *sampled* tokens only) with the prompt's tokens estimated at 3
    /// UTF-8 bytes each, plus 256 for the JSON structure MLX forces without counting it.
    static func maxAnswerTokens(prompt: String) -> Int {
        MLXLanguageModel.answerTokenBudget(promptTokens: (prompt.utf8.count + 2) / 3) + 256
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

/// Refuses every HTTP redirect: the eval server never sends one, and following it would leave the
/// address `RemoteAddressPolicy` approved. The 3xx itself becomes the response (`check` rejects it).
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
