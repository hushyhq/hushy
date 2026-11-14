import Foundation
import Testing
@testable import MurmurCore

/// The shape of what the app sends for feedback, and how the site's answers are read. No network:
/// a fake transport records the request.
@Suite("Feedback client", .timeLimit(.minutes(1)))
struct FeedbackClientTests {
    private final class Recorder: FeedbackTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { seen } }
        let status: Int
        let body: String
        let failure: Error?
        init(status: Int = 200, body: String = "{\"ok\":true}", failure: Error? = nil) {
            self.status = status; self.body = body; self.failure = failure
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { seen.append(request) }
            if let failure { throw failure }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private let endpoint = URL(string: "https://example.test/api/feedback")!
    private func client(_ transport: Recorder) -> FeedbackClient { FeedbackClient(endpoint: endpoint, transport: transport) }
    private let info = FeedbackAppInfo(version: "1.4.2", build: "2622", macOS: "15.1.0", model: "Mac14,5 (Apple M2 Pro)")

    private func json(_ data: Data?) throws -> [String: Any] {
        let bytes = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test("the production endpoint is the site Worker's feedback route over https")
    func productionEndpoint() {
        #expect(FeedbackClient.endpoint.absoluteString == "https://tryhushy.com/api/feedback")
    }

    @Test("the request is a JSON POST with the account token and nothing else identifying")
    func requestShape() async throws {
        let transport = Recorder()
        let outcome = await client(transport).send(message: "  The pill is slow in Slack.  \n", appInfo: info, accessToken: "aaa.bbb.ccc")
        #expect(outcome == .sent)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer aaa.bbb.ccc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
        let body = try json(request.httpBody)
        #expect(Set(body.keys) == ["message", "app"])
        #expect(body["message"] as? String == "The pill is slow in Slack.")
        let app = try #require(body["app"] as? [String: String])
        #expect(app == ["version": "1.4.2", "build": "2622", "macos": "15.1.0", "model": "Mac14,5 (Apple M2 Pro)"])
    }

    @Test("with the box unticked there is no app object at all, only the message")
    func versionOptOut() throws {
        let body = try json(client(Recorder()).body(message: "Hello", appInfo: nil))
        #expect(Set(body.keys) == ["message"])
        let empty = try json(client(Recorder()).body(message: "Hello", appInfo: FeedbackAppInfo()))
        #expect(Set(empty.keys) == ["message"])
    }

    @Test("app facts are cleaned to what the site accepts: printable ASCII, cut to length, empty ones dropped")
    func appFactsAreCleaned() throws {
        let messy = FeedbackAppInfo(version: String(repeating: "9", count: 40), build: "—", macOS: "15.1\n.0", model: "Mac14,5 é")
        let app = try #require(messy.cleaned)
        #expect(app["version"]?.count == 32)
        #expect(app["build"] == nil)
        #expect(app["macos"] == "15.1.0")
        #expect(app["model"] == "Mac14,5")
    }

    @Test("a body holds no keys beyond message and app, so no dictation, history, app name or address can ride along")
    func noOtherKeys() throws {
        let body = try json(client(Recorder()).body(message: "Hi", appInfo: info))
        let app = try #require(body["app"] as? [String: Any])
        #expect(Set(app.keys).isSubset(of: ["version", "build", "macos", "model"]))
    }

    @Test("an empty message, or one over 5,000 characters, sends nothing")
    func lengthLimits() async {
        let transport = Recorder()
        let client = client(transport)
        #expect(await client.send(message: "  \n ", appInfo: nil, accessToken: "a.b.c") == .failed)
        #expect(await client.send(message: String(repeating: "a", count: 5001), appInfo: nil, accessToken: "a.b.c") == .tooLong)
        #expect(await client.send(message: String(repeating: "a", count: 5000), appInfo: nil, accessToken: "a.b.c") == .sent)
        #expect(transport.requests.count == 1)
        #expect(FeedbackLimits.characterCount(String(repeating: "😀", count: 5000)) == 5000)
    }

    @Test("no token, or an endpoint that is not https, sends nothing")
    func refusesUnsafeSetup() async {
        let transport = Recorder()
        #expect(await client(transport).send(message: "Hi", appInfo: nil, accessToken: "") == .failed)
        let insecure = FeedbackClient(endpoint: URL(string: "http://example.test/api/feedback")!, transport: transport)
        #expect(await insecure.send(message: "Hi", appInfo: nil, accessToken: "a.b.c") == .failed)
        #expect(transport.requests.isEmpty)
    }

    @Test("the site's answers become the sheet's outcomes")
    func outcomes() async {
        func result(_ status: Int, _ body: String = "{}") async -> FeedbackOutcome {
            await client(Recorder(status: status, body: body)).send(message: "Hi", appInfo: nil, accessToken: "a.b.c")
        }
        #expect(await result(200) == .sent)
        #expect(await result(401, "{\"error\":\"Sign in required\"}") == .signInNeeded)
        #expect(await result(429, "{\"error\":\"Daily limit\",\"code\":\"daily_limit\"}") == .dailyLimit)
        #expect(await result(429, "{\"error\":\"Daily limit\",\"code\":\"busy_today\"}") == .busyToday)
        #expect(await result(429, "{\"error\":\"Please try again in a minute.\"}") == .slowDown)
        #expect(await result(413) == .tooLong)
        #expect(await result(503) == .failed)
        #expect(await result(400) == .failed)
        #expect(await result(500, "not json") == .failed)
    }

    @Test("a dropped connection is a failure worth retrying")
    func transportFailure() async {
        let outcome = await client(Recorder(failure: URLError(.notConnectedToInternet))).send(message: "Hi", appInfo: nil, accessToken: "a.b.c")
        #expect(outcome == .failed)
    }
}
