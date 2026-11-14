import Foundation
import Network
import Synchronization
import Testing
@testable import HushyModelsRemote
@testable import MurmurCore

final class HitCounter: Sendable {
    private let count = Mutex(0)
    func add() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// A one-response-per-connection HTTP stub on 127.0.0.1 (Network framework), counting requests.
final class StubHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let hitCount = HitCounter()
    private let queue = DispatchQueue(label: "stub-http")

    init(response: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [hitCount, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                hitCount.add()
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    var hits: Int { hitCount.value }

    func start() async throws -> Int {
        let ready = AsyncStream<Int?> { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.yield(listener.port.map { Int($0.rawValue) }); continuation.finish()
                case .failed, .cancelled: continuation.yield(nil); continuation.finish()
                default: break
                }
            }
        }
        listener.start(queue: queue)
        for await port in ready { if let port { return port } }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { listener.cancel() }
}

@Suite("Remote backend refuses redirects")
struct RedirectRefusalTests {
    @Test func aRedirectIsNeverFollowed() async throws {
        let body = #"{"object":"list","data":[{"id":"m","max_model_len":1024}]}"#
        let target = try StubHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        let targetPort = try await target.start()
        defer { target.stop() }
        let redirector = try StubHTTPServer(
            response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(targetPort)/v1/models\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let port = try await redirector.start()
        defer { redirector.stop() }

        var configuration = RemoteLanguageModel.Configuration(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        configuration.requestTimeout = 5
        let model = RemoteLanguageModel(configuration: configuration)
        do {
            try await model.connect()
            Issue.record("a redirect must not succeed")
        } catch {
            #expect("\(error)".contains("redirect refused"))
        }
        #expect(redirector.hits == 1)
        #expect(target.hits == 0, "the redirect target was contacted")
    }

    @Test func theStubServesDirectly() async throws {
        // Control: without a redirect the same stub answers, so the test above isn't vacuous.
        let body = #"{"object":"list","data":[{"id":"m","max_model_len":1024}]}"#
        let server = try StubHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        let port = try await server.start()
        defer { server.stop() }
        let model = RemoteLanguageModel(configuration: .init(baseURL: URL(string: "http://127.0.0.1:\(port)")!))
        #expect(try await model.connect() == "m")
        #expect(model.contextWindow == 1024)
    }
}
