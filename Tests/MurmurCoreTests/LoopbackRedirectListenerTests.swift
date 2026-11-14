import Foundation
import Network
import Testing
@testable import MurmurCore

@Suite("Loopback HTTP parsing")
struct LoopbackHTTPTests {
    private func head(_ text: String) -> LoopbackHTTP.RequestHead? {
        LoopbackHTTP.parseRequestHead(Data(text.utf8))
    }

    @Test("parses a browser's callback request")
    func parsesCallback() throws {
        let parsed = try #require(head("GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:5123\r\nUser-Agent: x\r\n\r\n"))
        #expect(parsed.method == "GET" && parsed.path == "/callback" && parsed.target == "/callback?code=abc&state=xyz")
        #expect(parsed.host == "127.0.0.1:5123")
    }

    @Test("incomplete, malformed or hostile heads are rejected", arguments: [
        "GET /callback HTTP/1.1\r\nHost: 127.0.0.1:1\r\n",          // no blank line yet
        "GET /callback\r\n\r\n",                                   // no version
        "GET http://evil/callback HTTP/1.1\r\nHost: a\r\n\r\n",    // absolute-form
        "GET //evil/callback HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET /call back HTTP/1.1\r\n\r\n",
        "GET /callback HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",    // duplicate Host
        "GET /callback SPDY/3\r\n\r\n",
    ])
    func rejects(text: String) {
        #expect(head(text) == nil)
    }

    @Test("only loopback Host headers for our port are accepted")
    func hostCheck() {
        #expect(LoopbackHTTP.isLoopbackHost("127.0.0.1:5123", port: 5123))
        #expect(LoopbackHTTP.isLoopbackHost("LOCALHOST:5123", port: 5123))
        #expect(!LoopbackHTTP.isLoopbackHost("127.0.0.1:5124", port: 5123))
        #expect(!LoopbackHTTP.isLoopbackHost("rebind.evil.example:5123", port: 5123))
        #expect(!LoopbackHTTP.isLoopbackHost(nil, port: 5123))
    }

    @Test("response is a minimal, non-cacheable, script-free page")
    func response() throws {
        let text = try #require(String(data: LoopbackHTTP.response(status: 200, html: LoopbackHTTP.donePage), encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Cache-Control: no-store") && text.contains("Referrer-Policy: no-referrer") && text.contains("Connection: close"))
        #expect(text.contains("default-src 'none'") && text.contains("frame-ancestors 'none'") && !text.lowercased().contains("<script"))
        // Sent before the code exchange, so it must not claim the sign-in succeeded.
        #expect(text.contains("Return to Hushy to finish") && !text.contains("signed in."))
    }

    @Test("state matching: exactly one state, equal in constant time")
    func stateMatching() {
        #expect(LoopbackHTTP.hasSingleState("/callback?code=c&state=abc", equalTo: "abc"))
        #expect(!LoopbackHTTP.hasSingleState("/callback?code=c&state=abd", equalTo: "abc"))
        #expect(!LoopbackHTTP.hasSingleState("/callback?code=c", equalTo: "abc"))
        #expect(!LoopbackHTTP.hasSingleState("/callback?state=abc&state=abc", equalTo: "abc"))
        #expect(!LoopbackHTTP.hasSingleState("/callback?state=ab", equalTo: "abc"))
    }
}

/// Talks to a real listener over 127.0.0.1 only (no external network). The "browser" is a
/// URLSession GET fired from the injected `openURL`.
@Suite("Loopback redirect listener", .serialized)
struct LoopbackRedirectListenerTests {
    /// Holds a TCP connection open without sending HTTP so the listener counts it toward the cap.
    /// A BSD socket for the same reason `rawStatus` uses one: an `NWConnection` can sit in
    /// `.waiting` (source-port bind failure under load) and never reach the listener at all.
    private func openIdle(port: Int) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                while true {
                    if let fd = connectLoopback(port: port, host: "127.0.0.1") {
                        continuation.resume(returning: fd)
                        return
                    }
                }
            }
        }
    }

    /// Waits for the listener's own slot count, the thing under test, instead of guessing how
    /// long the accept path takes: a client-side connect completes in the kernel before the
    /// listener has seen the connection, and closing is likewise only noticed asynchronously.
    private func waitForActiveConnections(
        _ expected: Int, on listener: LoopbackRedirectListener
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)  // backstop: a stuck count fails, not hangs
        while listener.activeConnectionCount != expected {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func get(_ url: URL) async throws -> (Int, String) {
        let request = URLRequest(url: url)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test("binds 127.0.0.1 on an ephemeral port, serves one callback, then closes")
    func fullFlow() async throws {
        let pages = PageBox()
        let listener = try await LoopbackRedirectListener.start { authorizeURL in
            let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            let state = items.first { $0.name == "state" }!.value!
            Task {
                let base = URL(string: redirect)!
                let origin = "http://127.0.0.1:\(base.port!)"
                // A stray favicon request first must not complete (or break) the flow.
                let favicon = try? await get(URL(string: origin + "/favicon.ico")!)
                let callback = try? await get(URL(string: origin + "/callback?code=the-code&state=\(state)")!)
                await pages.set(favicon?.0, callback)
            }
            return true
        }
        #expect(listener.redirectPort > 1023)
        let config = ConnectorFixtures.google
        let request = OAuthAuthorizationRequest(configuration: config, redirectURI: config.redirectURI(port: listener.redirectPort))
        let redirect = try await listener.authorize(request)
        #expect(redirect.host == "127.0.0.1" && redirect.port == listener.redirectPort)
        #expect(try request.callback(from: redirect).code == "the-code")

        // Wait for the browser side to record what it saw.
        for _ in 0..<100 where await pages.callback == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await pages.faviconStatus == 404)
        #expect(await pages.callback?.0 == 200)
        #expect(await pages.callback?.1.contains("You can close this tab") == true)

        // Single use: the port no longer accepts connections, and authorize can't be reused.
        let after = try? await get(URL(string: "http://127.0.0.1:\(listener.redirectPort)/callback?code=x&state=y")!)
        #expect(after == nil)
        await #expect(throws: OAuthError.listenerFailed) { try await listener.authorize(request) }
    }

    @Test("a callback with the wrong state gets 400 and the listener keeps waiting for the real one")
    func wrongStateDoesNotKillFlow() async throws {
        let seen = PageBox()
        let listener = try await LoopbackRedirectListener.start { authorizeURL in
            let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }!.value!
            let port = URL(string: items.first { $0.name == "redirect_uri" }!.value!)!.port!
            Task {
                let origin = "http://127.0.0.1:\(port)"
                let forged = try? await get(URL(string: origin + "/callback?code=evil&state=guess")!)
                let noState = try? await get(URL(string: origin + "/callback?code=evil")!)
                let doubled = try? await get(URL(string: origin + "/callback?code=evil&state=\(state)&state=\(state)")!)
                let real = try? await get(URL(string: origin + "/callback?code=good&state=\(state)")!)
                await seen.set(forged?.0, real)
                await seen.setExtra([noState?.0, doubled?.0])
            }
            return true
        }
        let config = ConnectorFixtures.google
        let request = OAuthAuthorizationRequest(configuration: config, redirectURI: config.redirectURI(port: listener.redirectPort))
        let redirect = try await listener.authorize(request)
        #expect(try request.callback(from: redirect).code == "good")
        for _ in 0..<100 where await seen.callback == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await seen.faviconStatus == 400)
        #expect(await seen.extra == [400, 400])
        #expect(await seen.callback?.0 == 200)
    }

    @Test("a callback before authorize (no expected state yet) is refused, not consumed")
    func callbackBeforeAuthorize() async throws {
        let listener = try await LoopbackRedirectListener.start { _ in true }
        let head = "GET /callback?code=c&state=s HTTP/1.1\r\nHost: 127.0.0.1:\(listener.redirectPort)\r\n\r\n"
        #expect(await rawStatus(head, port: listener.redirectPort) == 400)
        #expect(await rawStatus(head, port: listener.redirectPort) == 400)  // still listening
        listener.cancel()
    }

    @Test("connection cap is concurrent, not lifetime: closed connections free their slot")
    func concurrentCap() async throws {
        let listener = try await LoopbackRedirectListener.start { _ in true }
        let port = listener.redirectPort
        let favicon = "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        for _ in 0..<(LoopbackRedirectListener.maxConcurrentConnections + 8) {
            #expect(await rawStatus(favicon, port: port) == 404)
        }
        #expect(try await waitForActiveConnections(0, on: listener))  // the 24 above all freed their slot
        var idle: [Int32] = []
        for _ in 0..<LoopbackRedirectListener.maxConcurrentConnections { idle.append(await openIdle(port: port)) }
        #expect(try await waitForActiveConnections(LoopbackRedirectListener.maxConcurrentConnections, on: listener))
        #expect(await rawStatus(favicon, port: port) == nil)  // over the concurrent cap
        idle.forEach { close($0) }
        #expect(try await waitForActiveConnections(0, on: listener))
        #expect(await rawStatus(favicon, port: port) == 404)
        listener.cancel()
    }

    @Test("a request with a foreign Host header is refused and doesn't complete the flow")
    func dnsRebindingRefused() async throws {
        let foreign = PageBox()
        // The long timeout is only a backstop so a broken listener fails instead of hanging; the
        // test finishes as soon as the real callback has been taken.
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(30)) { authorizeURL in
            let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }!.value!
            let port = URL(string: items.first { $0.name == "redirect_uri" }!.value!)!.port!
            Task {
                // The foreign Host carries the *right* state, so only the Host check can stop it.
                let status = await rawStatus(
                    "GET /callback?code=evil&state=\(state) HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n", port: port)
                await foreign.set(status, nil)
                _ = await rawStatus(
                    "GET /callback?code=good&state=\(state) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port)
            }
            return true
        }
        let config = ConnectorFixtures.google
        let request = OAuthAuthorizationRequest(configuration: config, redirectURI: config.redirectURI(port: listener.redirectPort))
        let redirect = try await listener.authorize(request)
        // The foreign request was answered before the real one was even sent, so this is settled.
        #expect(await foreign.faviconStatus == 400)
        // The flow ended on the genuine callback: the foreign request did not complete it.
        #expect(try request.callback(from: redirect).code == "good")
    }

    @Test("not reachable over IPv6 loopback (bound to 127.0.0.1 only, not a wildcard)")
    func ipv4LoopbackOnly() async throws {
        let listener = try await LoopbackRedirectListener.start { _ in true }
        let head = "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1:\(listener.redirectPort)\r\n\r\n"
        #expect(await rawStatus(head, port: listener.redirectPort) == 404)
        #expect(await rawStatus(head, port: listener.redirectPort, host: "::1") == nil)
        listener.cancel()
    }

    @Test("times out when no redirect arrives")
    func timeout() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .milliseconds(200)) { _ in true }
        let config = ConnectorFixtures.microsoft
        let request = OAuthAuthorizationRequest(configuration: config, redirectURI: config.redirectURI(port: listener.redirectPort))
        await #expect(throws: OAuthError.timedOut) { try await listener.authorize(request) }
    }

    @Test("failing to open the browser ends the flow")
    func browserFailed() async throws {
        let listener = try await LoopbackRedirectListener.start { _ in false }
        let config = ConnectorFixtures.google
        let request = OAuthAuthorizationRequest(configuration: config, redirectURI: config.redirectURI(port: listener.redirectPort))
        await #expect(throws: OAuthError.listenerFailed) { try await listener.authorize(request) }
    }

    @Test("a request built for another port is refused before opening the browser")
    func wrongPort() async throws {
        let opened = PageBox()
        let listener = try await LoopbackRedirectListener.start { _ in await opened.set(1, nil); return true }
        let config = ConnectorFixtures.google
        let request = OAuthAuthorizationRequest(configuration: config, redirectURI: config.redirectURI(port: listener.redirectPort + 1))
        await #expect(throws: OAuthError.unexpectedRedirect) { try await listener.authorize(request) }
        #expect(await opened.faviconStatus == nil)
        listener.cancel()
    }

    @Test("cancelling the waiting task ends the flow")
    func cancellation() async throws {
        let listener = try await LoopbackRedirectListener.start { _ in true }
        let config = ConnectorFixtures.google
        let request = OAuthAuthorizationRequest(configuration: config, redirectURI: config.redirectURI(port: listener.redirectPort))
        let task = Task { try await listener.authorize(request) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Sends raw bytes (URLSession won't let us forge a Host header) over a plain blocking TCP
/// socket and returns the HTTP status code. Nil means no status came back: the connection was
/// refused or failed, or the server closed it without answering.
///
/// This is deliberately a BSD socket, not `NWConnection`. A `NWConnection` picks its own source
/// port, and when the machine has many recently closed loopback connections (TIME_WAIT, e.g. from
/// the other ~2,800 tests, or another run still draining) that bind fails with `EADDRINUSE`; the
/// connection sits in `.waiting` and never reaches the listener, which looked exactly like "the
/// listener did not answer". `connect(2)` lets the kernel choose a source port that is free for
/// this destination.
func rawStatus(_ text: String, port: Int, host: String = "127.0.0.1") async -> Int? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: blockingRawStatus(text, port: port, host: host))
        }
    }
}

/// The wait for a reply is bounded only so a broken listener fails the test instead of hanging it.
private let rawReplyTimeoutSeconds = 15

private func blockingRawStatus(_ text: String, port: Int, host: String) -> Int? {
    guard let fd = connectLoopback(port: port, host: host) else { return nil }  // refused, unreachable, …
    defer { close(fd) }
    let bytes = Array(text.utf8)
    guard send(fd, bytes, bytes.count, 0) == bytes.count else { return nil }
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while reply.count < 12 {
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { return nil }  // closed without a status line, reset, or timed out
        reply.append(contentsOf: chunk[0..<n])
    }
    return Int(String(decoding: reply, as: UTF8.self).split(separator: " ").dropFirst().first ?? "")
}

/// A connected blocking TCP socket to `host:port`, or nil if the connection could not be made.
/// The caller closes it.
private func connectLoopback(port: Int, host: String) -> Int32? {
    var v4 = sockaddr_in()
    var v6 = sockaddr_in6()
    let isV6 = host.contains(":")
    let family = isV6 ? AF_INET6 : AF_INET
    if isV6 {
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 else { return nil }
    } else {
        v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        v4.sin_family = sa_family_t(AF_INET)
        v4.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &v4.sin_addr) == 1 else { return nil }
    }
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: rawReplyTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected: Int32 = isV6
        ? withUnsafePointer(to: &v6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        : withUnsafePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard connected == 0 else { close(fd); return nil }
    return fd
}

private actor PageBox {
    var faviconStatus: Int?
    var callback: (Int, String)?
    var extra: [Int?] = []

    func setExtra(_ values: [Int?]) { extra = values }

    func set(_ status: Int?, _ callback: (Int, String)?) {
        faviconStatus = status
        self.callback = callback
    }
}
