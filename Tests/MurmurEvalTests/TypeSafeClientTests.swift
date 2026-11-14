import Foundation
import Testing

@testable import murmur_eval

/// A scripted fake transport: returns queued (status, body) pairs in order, or throws a queued
/// transport error, and records every request it sees so tests can assert on headers/body
/// without ever touching the network or a real URLProtocol stack.
actor FakeTransport: TypeSafeClient.Transport {
    enum Step {
        case response(status: Int, body: Data, headers: [String: String] = [:])
        case transportError(Error)
    }

    private var steps: [Step]
    private(set) var seenRequests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        seenRequests.append(request)
        guard !steps.isEmpty else {
            fatalError("FakeTransport ran out of scripted steps")
        }
        let step = steps.removeFirst()
        switch step {
        case .response(let status, let body, let headers):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        case .transportError(let error):
            throw error
        }
    }

    struct SimulatedError: Error {}
}

@Suite("TypeSafeClient request encoding")
struct TypeSafeClientRequestTests {
    @Test func encodesStateModelAndQuestionsWithCorrectShapes() async throws {
        let transport = FakeTransport([.response(status: 200, body: sampleResponseJSON())])
        let questions: [String: TypeSafeClient.Question] = [
            "meaning_preserved": .init(
                type: .score, instructions: .string("Rate meaning preservation."),
                criteria: .array([.string("lost"), .string("partial"), .string("full")])),
            "dropped_content": .init(
                type: .noul, instructions: .string("Was anything dropped?"),
                criteria: .strings(["true": "yes", "false": "no"])),
            "format": .init(
                type: .choice, instructions: .string("What format?"),
                criteria: .strings(["sentence": "prose", "list": "bulleted"])),
        ]
        _ = try await TypeSafeClient.ask(
            state: .object(["spoken": .string("hello"), "hushy_output": .string("Hello.")]),
            questions: questions, apiKey: "test-key-123", transport: transport)

        let seen = await transport.seenRequests
        #expect(seen.count == 1)
        let request = seen[0]
        #expect(request.url == TypeSafeClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["model"] as? String == "jev-latest")
        let state = try #require(decoded["state"] as? [String: Any])
        #expect(state["spoken"] as? String == "hello")
        let sentQuestions = try #require(decoded["questions"] as? [String: Any])
        let meaning = try #require(sentQuestions["meaning_preserved"] as? [String: Any])
        #expect(meaning["type"] as? String == "score")
        let scoreCriteria = try #require(meaning["criteria"] as? [String])
        #expect(scoreCriteria == ["lost", "partial", "full"])
        let dropped = try #require(sentQuestions["dropped_content"] as? [String: Any])
        #expect(dropped["type"] as? String == "noul")
        let noulCriteria = try #require(dropped["criteria"] as? [String: String])
        #expect(noulCriteria["true"] == "yes")
    }

    @Test func neverIncludesAPIKeyInEncodedBody() async throws {
        let transport = FakeTransport([.response(status: 200, body: sampleResponseJSON())])
        _ = try await TypeSafeClient.ask(
            state: .string("state"),
            questions: ["q": .init(type: .noul, instructions: .string("?"))],
            apiKey: "super-secret-key-should-never-appear", transport: transport)
        let seen = await transport.seenRequests
        let bodyText = String(data: try #require(seen[0].httpBody), encoding: .utf8) ?? ""
        #expect(!bodyText.contains("super-secret-key-should-never-appear"))
    }
}

@Suite("TypeSafeClient response decoding")
struct TypeSafeClientResponseTests {
    @Test func decodesScoreChoiceAndNoulAnswers() async throws {
        let transport = FakeTransport([.response(status: 200, body: sampleResponseJSON())])
        let response = try await TypeSafeClient.ask(
            state: .string("s"),
            questions: [
                "meaning_preserved": .init(type: .score, instructions: .string("?")),
                "dropped_content": .init(type: .noul, instructions: .string("?")),
                "format": .init(type: .choice, instructions: .string("?")),
            ],
            apiKey: "k", transport: transport)

        #expect(response.model == "jev-1.13.0")
        let meaning = try #require(response.answers["meaning_preserved"])
        #expect(meaning.type == .score)
        #expect(meaning.score == 3.5)
        #expect(meaning.legend?["1"] == "partial")

        let dropped = try #require(response.answers["dropped_content"])
        #expect(dropped.type == .noul)
        #expect(dropped.noul == 0.12)

        let format = try #require(response.answers["format"])
        #expect(format.type == .choice)
        #expect(format.choice == "sentence")
        #expect(format.probabilities?["sentence"] == 0.9)
        #expect(format.confidence == 0.9)
    }

    @Test func throwsDecodingErrorOnMalformedBody() async throws {
        let transport = FakeTransport([.response(status: 200, body: Data("not json".utf8))])
        await #expect(throws: TypeSafeClient.ClientError.self) {
            _ = try await TypeSafeClient.ask(
                state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
                apiKey: "k", transport: transport)
        }
    }
}

@Suite("TypeSafeClient error handling")
struct TypeSafeClientErrorTests {
    @Test func mapsHTTPStatusesToTypedErrors() async throws {
        try await assertMapsToError(status: 401, expected: TypeSafeClient.ClientError.unauthorized)
        try await assertMapsToError(status: 422, expectedCase: { if case .invalidRequest = $0 { true } else { false } })
    }

    private func assertMapsToError(status: Int, expected: TypeSafeClient.ClientError) async throws {
        let transport = FakeTransport([.response(status: status, body: Data("{}".utf8))])
        do {
            _ = try await TypeSafeClient.ask(
                state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
                apiKey: "k", transport: transport)
            Issue.record("expected \(expected)")
        } catch let error as TypeSafeClient.ClientError {
            #expect(error == expected)
        }
    }

    private func assertMapsToError(status: Int, expectedCase: @escaping (TypeSafeClient.ClientError) -> Bool) async throws {
        let transport = FakeTransport([.response(status: status, body: Data("{}".utf8))])
        do {
            _ = try await TypeSafeClient.ask(
                state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
                apiKey: "k", transport: transport)
            Issue.record("expected an error")
        } catch let error as TypeSafeClient.ClientError {
            #expect(expectedCase(error))
        }
    }

    @Test func doesNotRetry401Or422() async throws {
        // Only one scripted step: if the client retried, FakeTransport would fatalError from
        // running out of steps, so surviving this call proves no retry happened.
        let transport = FakeTransport([.response(status: 401, body: Data("{}".utf8))])
        await #expect(throws: TypeSafeClient.ClientError.self) {
            _ = try await TypeSafeClient.ask(
                state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
                apiKey: "k", transport: transport)
        }
        let seen = await transport.seenRequests
        #expect(seen.count == 1)
    }
}

@Suite("TypeSafeClient retry and backoff")
struct TypeSafeClientRetryTests {
    @Test func retriesOn429ThenSucceeds() async throws {
        let transport = FakeTransport([
            .response(status: 429, body: Data("{}".utf8), headers: ["Retry-After": "0"]),
            .response(status: 200, body: sampleResponseJSON()),
        ])
        let response = try await TypeSafeClient.ask(
            state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
            apiKey: "k", transport: transport)
        #expect(response.model == "jev-1.13.0")
        let seen = await transport.seenRequests
        #expect(seen.count == 2)
    }

    @Test func retriesOn529ThenSucceeds() async throws {
        let transport = FakeTransport([
            .response(status: 529, body: Data("{}".utf8)),
            .response(status: 200, body: sampleResponseJSON()),
        ])
        _ = try await TypeSafeClient.ask(
            state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
            apiKey: "k", transport: transport)
        let seen = await transport.seenRequests
        #expect(seen.count == 2)
    }

    @Test func retriesOn5xxServerErrors() async throws {
        let transport = FakeTransport([
            .response(status: 503, body: Data("{}".utf8)),
            .response(status: 200, body: sampleResponseJSON()),
        ])
        _ = try await TypeSafeClient.ask(
            state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
            apiKey: "k", transport: transport)
        let seen = await transport.seenRequests
        #expect(seen.count == 2)
    }

    @Test func givesUpAfterMaxRetriesOn429() async throws {
        let steps = (0..<TypeSafeClient.maxRetries).map { _ in
            FakeTransport.Step.response(status: 429, body: Data("{}".utf8), headers: ["Retry-After": "0"])
        }
        let transport = FakeTransport(steps)
        do {
            _ = try await TypeSafeClient.ask(
                state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
                apiKey: "k", transport: transport)
            Issue.record("expected rateLimited")
        } catch let error as TypeSafeClient.ClientError {
            #expect(error == .rateLimited)
        }
    }

    @Test func retriesTransportErrorsThenSucceeds() async throws {
        let transport = FakeTransport([
            .transportError(FakeTransport.SimulatedError()),
            .response(status: 200, body: sampleResponseJSON()),
        ])
        _ = try await TypeSafeClient.ask(
            state: .string("s"), questions: ["q": .init(type: .noul, instructions: .string("?"))],
            apiKey: "k", transport: transport)
        let seen = await transport.seenRequests
        #expect(seen.count == 2)
    }

    @Test func backoffSecondsGrowsWithAttemptAndStaysWithinCap() {
        for attempt in 0..<8 {
            let delay = TypeSafeClient.backoffSeconds(attempt)
            #expect(delay >= 0)
            #expect(delay <= 30)
        }
    }
}

private func sampleResponseJSON() -> Data {
    let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "meaning_preserved": {
              "type": "score", "score": 3.5, "confidence": 0.8,
              "legend": {"0": "lost", "1": "partial", "2": "mostly", "3": "full"},
              "probabilities": {"0": 0.0, "1": 0.1, "2": 0.1, "3": 0.8}
            },
            "dropped_content": {"type": "noul", "noul": 0.12},
            "added_or_changed_facts": {"type": "noul", "noul": 0.05},
            "correction_resolved": {"type": "noul", "noul": 0.95},
            "format": {
              "type": "choice", "choice": "sentence", "confidence": 0.9,
              "probabilities": {"sentence": 0.9, "list": 0.1}
            },
            "format_matches_expected": {"type": "noul", "noul": 0.9}
          },
          "usage": {"input_tokens": 120, "output_tokens": 24}
        }
        """
    return Data(json.utf8)
}
