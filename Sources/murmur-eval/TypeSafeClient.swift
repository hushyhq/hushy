import Foundation

/// Minimal client for TypeSafe's System One API (Jev decision model): POSTs a `state` plus a
/// batch of typed questions (score/choice/noul) and gets back probabilities. See
/// https://docs.typesafe.ai/api.md and the primitives pages under /primitives/.
///
/// This client never logs, prints, or includes the API key anywhere except the single
/// `Authorization` request header, and redacts that header in any debug description.
enum TypeSafeClient {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    // MARK: Request/response types

    enum QuestionType: String, Codable {
        case noul, choice, score
    }

    /// A single question sent to Jev. `instructions` and `criteria` are free-form JSON per the
    /// docs (string, object, or array), so both are carried as `AnyJSON` to allow structured
    /// criteria (e.g. `{true: "...", false: "..."}` for noul, or an ordered array for score).
    struct Question: Encodable {
        let type: QuestionType
        let instructions: AnyJSON
        let criteria: AnyJSON?

        init(type: QuestionType, instructions: AnyJSON, criteria: AnyJSON? = nil) {
            self.type = type
            self.instructions = instructions
            self.criteria = criteria
        }
    }

    struct Request: Encodable {
        let state: AnyJSON
        let model: String
        let questions: [String: Question]

        init(state: AnyJSON, model: String = "jev-latest", questions: [String: Question]) {
            self.state = state
            self.model = model
            self.questions = questions
        }
    }

    struct Answer: Codable {
        let type: QuestionType
        /// Noul: 0...1 probability of "yes".
        let noul: Double?
        /// Choice: the selected option name.
        let choice: String?
        /// Score: probability-weighted mean across levels (0...maxLevel).
        let score: Double?
        /// Choice/score: confidence derived from the shape of `probabilities` (1.0 = fully
        /// concentrated on one option/level). Noul carries no separate confidence field.
        let confidence: Double?
        /// Choice: option -> probability. Score: level index (as string) -> probability.
        let probabilities: [String: Double]?
        /// Score only: level index (as string) -> level description.
        let legend: [String: String]?
    }

    struct Response: Codable {
        let model: String
        let answers: [String: Answer]
        let usage: Usage?

        struct Usage: Codable {
            let inputTokens: Int?
            let outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    /// A small untyped-JSON box so `state`/`instructions`/`criteria` can hold strings, objects,
    /// or arrays without hand-rolling a second parallel type hierarchy for each shape.
    enum AnyJSON: Encodable {
        case string(String)
        case object([String: AnyJSON])
        case array([AnyJSON])
        case bool(Bool)
        case number(Double)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            }
        }

        static func strings(_ pairs: [String: String]) -> AnyJSON { .object(pairs.mapValues { .string($0) }) }
    }

    // MARK: Error handling

    enum ClientError: LocalizedError, Equatable {
        case unauthorized
        case invalidRequest(String)
        case rateLimited
        case overloaded
        case http(Int, String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "TypeSafe API rejected the API key (401)"
            case .invalidRequest(let body): "TypeSafe API request was invalid (422): \(body)"
            case .rateLimited: "TypeSafe API rate limit exceeded (429)"
            case .overloaded: "TypeSafe API is temporarily overloaded (529)"
            case .http(let status, let body): "TypeSafe API returned HTTP \(status): \(body)"
            case .decoding(let message): "Could not decode TypeSafe API response: \(message)"
            }
        }
    }

    // MARK: Transport abstraction (for testing without the network)

    /// Abstracts the one HTTP call this client makes so tests can substitute a fake transport
    /// instead of hitting the real API or standing up a URLProtocol stack.
    protocol Transport: Sendable {
        func send(_ request: URLRequest) async throws -> (Data, URLResponse)
    }

    struct URLSessionTransport: Transport {
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            try await URLSession.shared.data(for: request)
        }
    }

    // MARK: Retry policy

    static let maxRetries = 6

    /// Sends one batch of questions against the same `state`, retrying 429/529/5xx with
    /// exponential backoff + jitter (mirrors `Datasets.sendWithBackoff`). 401 and 422 are not
    /// retried — they indicate a bad key or a malformed request, not a transient condition.
    static func ask(
        state: AnyJSON, questions: [String: Question], apiKey: String, model: String = "jev-latest",
        transport: Transport = URLSessionTransport()
    ) async throws -> Response {
        // Sorted keys: the same state + questions always produce the same request bytes (Swift
        // dictionaries iterate in per-process random order), so repeats and caches are comparable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Request(state: state, model: model, questions: questions))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await transport.send(request)
                guard let http = response as? HTTPURLResponse else {
                    throw ClientError.http(0, "no HTTP response")
                }
                switch http.statusCode {
                case 200:
                    do {
                        return try JSONDecoder().decode(Response.self, from: data)
                    } catch {
                        throw ClientError.decoding(String(describing: error))
                    }
                case 401:
                    throw ClientError.unauthorized
                case 422:
                    throw ClientError.invalidRequest(String(data: data, encoding: .utf8)?.prefix(500).description ?? "")
                case 429, 529, 500...599:
                    if attempt == maxRetries - 1 {
                        throw http.statusCode == 429 ? ClientError.rateLimited
                            : http.statusCode == 529 ? ClientError.overloaded
                            : ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                    }
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    try await Task.sleep(nanoseconds: UInt64((retryAfter ?? backoffSeconds(attempt)) * 1_000_000_000))
                    continue
                default:
                    throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                }
            } catch let error as ClientError {
                throw error
            } catch {
                lastError = error
                if attempt == maxRetries - 1 { throw error }
                try await Task.sleep(nanoseconds: UInt64(backoffSeconds(attempt) * 1_000_000_000))
            }
        }
        throw lastError ?? ClientError.http(0, "retries exhausted")
    }

    /// Exponential backoff with full jitter: `random(0, base * 2^attempt)`, capped at 30s.
    static func backoffSeconds(_ attempt: Int) -> Double {
        let base = 0.5
        let cap = 30.0
        let maxDelay = min(cap, base * pow(2, Double(attempt)))
        return Double.random(in: 0...maxDelay)
    }
}
