import Foundation
import Network

/// The founder-facing capture window for `murmur-eval head-to-head play`: a local HTML page
/// (no build step, no framework) served over a loopback-only HTTP listener, the same pattern as
/// `LoopbackRedirectListener` in `MurmurCore` (127.0.0.1 only, ephemeral port, single process).
/// A browser tab is the simplest robust "capture window" available from a Swift CLI — no
/// Accessibility permission prompt, no Swift/AppKit window plumbing, and the founder already
/// has a paste target open in it, so whichever app they dictate into (Wispr Flow, or Hushy via
/// this same flow) pastes straight into the page's `<textarea>`.
///
/// Protocol: the tool starts the server, opens `http://127.0.0.1:<port>/`, then for each case
/// calls `nextEvent()`, which blocks until the page POSTs `/event` with either the captured
/// text (paste + settle delay elapsed client-side) or a `skip` signal (hotkey). The runner is
/// what actually plays the WAV; the page only shows "Case p-003 · playing…" / "Case p-003 ·
/// listening — paste now" state so the founder knows when to trigger their app's dictation.
final class HeadToHeadCaptureServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case listenerFailed

        var errorDescription: String? {
            switch self {
            case .listenerFailed: "Could not start the local capture server (loopback port)."
            }
        }
    }

    private static let maxRequestBytes = 64 * 1024
    private static let readTimeout: TimeInterval = 300

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.hushy.head-to-head-capture")
    private(set) var port: Int = 0

    /// The one pending "waiting for the next event" continuation, if any.
    private var pendingContinuation: CheckedContinuation<HeadToHeadPlaybackSession.Event, Never>?
    /// What the page should render right now.
    private var statusHTML = "Starting…"
    private var totalCases = 0
    private var doneCases = 0

    static func start() async throws -> HeadToHeadCaptureServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw ServerError.listenerFailed }
        let server = HeadToHeadCaptureServer(listener: listener)
        let resumed = StartResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, port != 0, resumed.claim() else { return }
                    server.port = Int(port)
                    continuation.resume()
                case .failed, .cancelled:
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: ServerError.listenerFailed)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
            listener.start(queue: server.queue)
        }
        return server
    }

    private init(listener: NWListener) {
        self.listener = listener
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    func stop() {
        queue.async { self.listener.cancel() }
    }

    /// Updates what the page shows. Call before playback starts and again once the clip has
    /// finished (so the founder knows exactly when to trigger their app's dictation).
    func setStatus(caseID: String, index: Int, total: Int, phase: String) {
        queue.async {
            self.totalCases = total
            self.doneCases = index
            self.statusHTML = "Case \(caseID) · \(index + 1) of \(total) · \(phase)"
        }
    }

    /// Blocks (suspends) until the page reports this case's outcome: captured text, a manual
    /// skip, or — driven by the runner, not the page — a silence timeout.
    func nextEvent() async -> HeadToHeadPlaybackSession.Event {
        await withCheckedContinuation { continuation in
            queue.async {
                self.pendingContinuation = continuation
            }
        }
    }

    /// Called by the runner when it decides to give up waiting (the page has its own client-side
    /// idle timer too, as a backstop, but the runner's clock is authoritative).
    func forceTimeout() {
        queue.async {
            guard let continuation = self.pendingContinuation else { return }
            self.pendingContinuation = nil
            continuation.resume(returning: .silenceTimeout)
        }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readTimeout) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes {
                self.respond(connection, status: 413, body: "")
                return
            }
            if let request = CaptureHTTP.parse(buffer) {
                self.handle(request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: CaptureHTTP.Request, on connection: NWConnection) {
        guard CaptureHTTP.isLoopback(request.host, port: port) else {
            respond(connection, status: 400, body: ""); return
        }
        switch (request.method, request.path) {
        case ("GET", "/"):
            respond(connection, status: 200, contentType: "text/html; charset=utf-8", body: CaptureHTTP.page)
        case ("GET", "/status"):
            let json = "{\"html\":\(CaptureHTTP.jsonString(statusHTML)),\"done\":\(doneCases),\"total\":\(totalCases)}"
            respond(connection, status: 200, contentType: "application/json", body: json)
        case ("POST", "/event"):
            let body = String(data: request.body, encoding: .utf8) ?? ""
            let event: HeadToHeadPlaybackSession.Event = body == "\u{0}skip" ? .skip : .textCaptured(body)
            if let continuation = pendingContinuation {
                pendingContinuation = nil
                continuation.resume(returning: event)
            }
            respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
        default:
            respond(connection, status: 404, body: "")
        }
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String = "text/plain", body: String) {
        let data = CaptureHTTP.response(status: status, contentType: contentType, body: body)
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// The tiny slice of HTTP/1.1 the capture server speaks. Pure, so parsing is unit-tested
/// without sockets — mirrors `LoopbackHTTP` in `MurmurCore` but adds a request body (POST
/// `/event` carries the pasted text) since that one only ever handled a GET redirect.
enum CaptureHTTP {
    struct Request: Equatable {
        let method: String
        let path: String
        let host: String?
        let body: Data
    }

    static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let headText = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { return nil }
        let target = String(requestLine[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var host: String?
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "host" { host = value }
            if key == "content-length" { contentLength = Int(value) ?? 0 }
        }
        let bodyStart = headEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }  // wait for the rest of the body
        let body = contentLength > 0 ? data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)] : Data()
        return Request(method: String(requestLine[0]), path: path, host: host, body: Data(body))
    }

    static func isLoopback(_ host: String?, port: Int) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    static func jsonString(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    static func response(status: Int, contentType: String, body: String) -> Data {
        let reason = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        default: "Error"
        }
        let bodyData = Data(body.utf8)
        let head = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        return Data(head.utf8) + bodyData
    }

    /// The capture page: a big textarea that grabs focus so a paste lands in it, a status line
    /// polled every 400 ms, a "Skip / next" button and hotkey (⌘⏎) for the founder to force an
    /// advance if their app never pastes, and a client-side settle timer (1.2 s of no keystroke
    /// after non-empty content) that auto-submits — matching the fn/hotkey-then-paste rhythm of
    /// hands-free dictation so the founder doesn't have to click anything mid-flow.
    static let page = """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <title>Hushy head-to-head capture</title>
        <style>
          body{font-family:-apple-system,sans-serif;background:#111;color:#eee;margin:0;padding:2rem;display:flex;flex-direction:column;height:100vh;box-sizing:border-box}
          #status{font-size:1.1rem;margin-bottom:1rem;color:#8ecbff}
          textarea{flex:1;font-size:1.4rem;line-height:1.5;background:#1b1b1b;color:#fff;border:2px solid #333;border-radius:8px;padding:1rem;resize:none}
          textarea:focus{border-color:#8ecbff;outline:none}
          #bar{margin-top:1rem;display:flex;gap:1rem;align-items:center;color:#888}
          button{font-size:1rem;padding:.5rem 1rem;border-radius:6px;border:1px solid #555;background:#222;color:#eee;cursor:pointer}
          button:hover{background:#333}
        </style></head><body>
        <div id="status">Loading…</div>
        <textarea id="capture" autofocus placeholder="Focus stays here. Paste your app's output; it advances automatically a moment after you stop typing/pasting."></textarea>
        <div id="bar">
          <button id="skip">Skip this case (⌘⏎)</button>
          <span>Nothing pasting? Click into the box first, then trigger your app's dictation.</span>
        </div>
        <script>
        const ta = document.getElementById('capture');
        const status = document.getElementById('status');
        let settleTimer = null;
        const SETTLE_MS = 1200;

        function poll() {
          fetch('/status').then(r => r.json()).then(s => {
            status.textContent = s.html;
          }).catch(() => {});
        }
        setInterval(poll, 400);
        poll();

        function submit(skip) {
          clearTimeout(settleTimer);
          const body = skip ? '\\u0000skip' : ta.value;
          fetch('/event', { method: 'POST', body }).then(() => { ta.value = ''; ta.focus(); });
        }

        ta.addEventListener('input', () => {
          clearTimeout(settleTimer);
          if (ta.value.trim().length === 0) return;
          settleTimer = setTimeout(() => submit(false), SETTLE_MS);
        });
        ta.addEventListener('keydown', e => {
          if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); submit(false); }
        });
        document.getElementById('skip').addEventListener('click', () => submit(true));
        ta.focus();
        </script>
        </body></html>
        """
}

/// Resumes the start-up continuation at most once across `NWListener.stateUpdateHandler`
/// invocations, which can fire on different threads — a lock-backed flag instead of a captured
/// `var` so the compiler can verify the closure is actually safe to run concurrently.
private final class StartResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
