import Foundation
import Network

/// Receives the OAuth redirect on a single-use loopback HTTP listener
/// (`docs/product/CONNECTORS.md` §6.9 / §1.1.2 item 5; AppAuth's loopback pattern is the model).
///
/// - Binds **127.0.0.1 only** (never a wildcard, `::1` or an external interface), on an
///   ephemeral port the OS picks; `acceptLocalOnly` is set as a second fence. Redirect URIs use
///   `127.0.0.1` too, never `localhost`, so a browser never tries a `[::1]` port someone else
///   could be squatting.
/// - At most `maxConcurrentConnections` open at once (closed ones free their slot), at most
///   `maxRequestBytes` per request, and a connection that doesn't finish its request head in
///   `connectionReadTimeout` is dropped.
/// - Completes **only** on `GET /callback?…` with a loopback `Host` header and exactly one
///   `state` equal (constant time) to the one `authorize` was given. Anything else — a favicon
///   fetch, a preconnect, a DNS-rebinding page, a local process guessing the port — gets a
///   400/404 and the listener keeps waiting, so it can't be used to kill the sign-in.
/// - After the matching callback it answers with a minimal neutral page and shuts down: one use.
/// - Shuts down `timeout` (default 2 minutes) after it starts listening, or when the awaiting
///   task is cancelled.
///
/// The code and state are never logged. Full validation of the redirect (state again, `iss`,
/// error params, code present) stays in `OAuthAuthorizationRequest.callback(from:)`.
public final class LoopbackRedirectListener: OAuthAuthorizing, @unchecked Sendable {
    public static let defaultTimeout: Duration = .seconds(120)
    static let maxRequestBytes = 8 * 1024
    static let maxConcurrentConnections = 16
    static let connectionReadTimeout: TimeInterval = 10

    /// Written once inside the listener's `.ready` callback, before `start` returns; the lock
    /// makes the hand-off to other threads well-defined.
    public var redirectPort: Int { port.value }
    private let port = LockedInt()
    private let listener: NWListener
    private let queue: DispatchQueue
    private let timeout: Duration
    private let openURL: @Sendable (URL) async -> Bool

    // All mutable state below is touched only on `queue`.
    private var activeConnections: Set<ObjectIdentifier> = []
    private var finished = false
    private var authorizeCalled = false
    private var expectedState: String?
    private var pendingFailure: (any Error)?
    private var continuation: CheckedContinuation<String, any Error>?

    /// Starts listening and returns once the port is known. `openURL` opens the authorize URL in
    /// the user's browser (the app passes `NSWorkspace.shared.open`) and reports success.
    public static func start(
        timeout: Duration = defaultTimeout, openURL: @escaping @Sendable (URL) async -> Bool
    ) async throws -> LoopbackRedirectListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw OAuthError.listenerFailed }
        let instance = LoopbackRedirectListener(listener: listener, timeout: timeout, openURL: openURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = ResumeOnce()
            listener.newConnectionHandler = { [weak instance] connection in
                guard let instance else { connection.cancel(); return }
                instance.accept(connection)
            }
            listener.stateUpdateHandler = { [weak instance] state in
                // Runs on `instance.queue`.
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    if let port = listener.port?.rawValue, port != 0, let instance {
                        instance.port.value = Int(port)
                        instance.scheduleTimeout()
                        continuation.resume()
                    } else {
                        listener.cancel()
                        continuation.resume(throwing: OAuthError.listenerFailed)
                    }
                case .failed, .cancelled:
                    if resumed.claim() { continuation.resume(throwing: OAuthError.listenerFailed) }
                    instance?.finish(.failure(OAuthError.listenerFailed))
                default:
                    break
                }
            }
            listener.start(queue: instance.queue)
        }
        return instance
    }

    private init(listener: NWListener, timeout: Duration, openURL: @escaping @Sendable (URL) async -> Bool) {
        self.listener = listener
        self.queue = DispatchQueue(label: "app.hushy.oauth-loopback")
        self.timeout = timeout
        self.openURL = openURL
    }

    deinit {
        listener.cancel()
    }

    /// Records the expected `state`, then opens the browser, then waits for the one matching
    /// redirect. Callable once per listener.
    public func authorize(_ request: OAuthAuthorizationRequest) async throws -> URL {
        guard request.redirectURI.port == redirectPort,
              request.redirectURI.path == OAuthClientConfiguration.callbackPath
        else { throw OAuthError.unexpectedRedirect }
        let target: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.install(continuation, request: request) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
        // Rebuild the URL from our own redirect URI (scheme/host/port) plus the received target,
        // so nothing the client sent can change where it claims to have come from.
        guard let url = URL(string: Self.origin(of: request.redirectURI) + target) else { throw OAuthError.unexpectedRedirect }
        return url
    }

    /// How many connections currently hold a slot toward `maxConcurrentConnections`. For tests.
    var activeConnectionCount: Int { queue.sync { activeConnections.count } }

    /// Stops listening without waiting for a redirect (e.g. the user closed the sheet).
    public func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    // MARK: - Queue-confined

    private func install(_ continuation: CheckedContinuation<String, any Error>, request: OAuthAuthorizationRequest) {
        guard !authorizeCalled else {
            continuation.resume(throwing: OAuthError.listenerFailed)
            return
        }
        authorizeCalled = true
        if let pendingFailure {
            continuation.resume(throwing: pendingFailure)
            return
        }
        // The expected state is in place before the browser can possibly hit the listener.
        expectedState = request.state
        self.continuation = continuation
        let url = request.url
        Task { [openURL, queue] in
            if !(await openURL(url)) {
                queue.async { self.finish(.failure(OAuthError.listenerFailed)) }
            }
        }
    }

    /// The listener's whole lifetime is bounded from the moment it is ready, whether or not
    /// `authorize` is ever called.
    private func scheduleTimeout() {
        let nanos = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: nanos))) { [weak self] in
            self?.finish(.failure(OAuthError.timedOut))
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else if case .failure(let error) = result {
            pendingFailure = error
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !finished, activeConnections.count < Self.maxConcurrentConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        activeConnections.insert(id)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.activeConnections.remove(id)  // on `queue`
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionReadTimeout) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes {
                self.respond(on: connection, with: LoopbackHTTP.response(status: 431))
                return
            }
            if let head = LoopbackHTTP.parseRequestHead(buffer) {
                self.handle(head, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: LoopbackHTTP.RequestHead, on connection: NWConnection) {
        guard LoopbackHTTP.isLoopbackHost(head.host, port: redirectPort) else {
            respond(on: connection, with: LoopbackHTTP.response(status: 400))
            return
        }
        guard !finished, head.method == "GET", head.path == OAuthClientConfiguration.callbackPath else {
            respond(on: connection, with: LoopbackHTTP.response(status: 404))
            return
        }
        guard let expectedState, LoopbackHTTP.hasSingleState(head.target, equalTo: expectedState) else {
            // Wrong/missing/duplicated state, or no sign-in in progress yet: refuse and keep
            // listening for the real browser.
            respond(on: connection, with: LoopbackHTTP.response(status: 400))
            return
        }
        respond(on: connection, with: LoopbackHTTP.response(status: 200, html: LoopbackHTTP.donePage))
        finish(.success(head.target))
    }

    private func respond(on connection: NWConnection, with data: Data) {
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func origin(of url: URL) -> String {
        "http://\(url.host ?? "127.0.0.1"):\(url.port ?? 0)"
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Resumes a continuation at most once across callback invocations.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// The tiny slice of HTTP/1.1 the listener speaks. Pure, so it's unit-tested without sockets.
enum LoopbackHTTP {
    struct RequestHead: Equatable {
        let method: String
        /// The request-target as received: `/callback?code=…&state=…`.
        let target: String
        let host: String?

        var path: String {
            String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
    }

    /// Parses the request line and headers once the blank line has arrived; nil if incomplete
    /// or malformed. The target must be origin-form (`/…`) and visible ASCII.
    static func parseRequestHead(_ data: Data) -> RequestHead? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .ascii)
        else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(requestLine[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), OAuthText.isTokenSafe(target) else { return nil }
        var host: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                guard host == nil else { return nil }  // duplicate Host header
                host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return RequestHead(method: String(requestLine[0]), target: target, host: host)
    }

    /// Only a browser that navigated to our own loopback address gets through (a web page that
    /// rebinds its DNS name to 127.0.0.1 would send its own name here).
    static func isLoopbackHost(_ host: String?, port: Int) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// Neutral on purpose: it is sent before the code is exchanged, so it must not claim success.
    static let donePage = """
        <!doctype html><html><head><meta charset="utf-8"><title>Hushy</title></head>\
        <body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:4em">\
        <p>Return to Hushy to finish signing in. You can close this tab.</p></body></html>
        """

    /// Exactly one `state` query item, equal to `expected` in constant time.
    static func hasSingleState(_ target: String, equalTo expected: String) -> Bool {
        guard let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems else { return false }
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, let value = states[0].value else { return false }
        return OAuthAuthorizationRequest.constantTimeEquals(value, expected)
    }

    static func response(status: Int, html: String = "") -> Data {
        let reason = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
        let body = Data(html.utf8)
        let head = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        return Data(head.utf8) + body
    }
}
