import Foundation

/// The one HTTP call shape the calendar connectors need (`docs/product/CONNECTORS.md` §6.1).
/// Kept deliberately tiny so the Google and Microsoft readers and the OAuth token client run
/// against `RecordingTransport` in tests with fixtures and never open a socket.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let method: Method
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// RFC 3986 unreserved characters, ASCII only. (`CharacterSet.alphanumerics` would let
    /// non-ASCII letters through unencoded.)
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Form-encoded POST (the OAuth token endpoints). Keys are sorted so the body is stable.
    public static func form(url: URL, fields: [String: String], headers: [String: String] = [:]) -> HTTPRequest {
        let body = fields.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(fields[key] ?? ""))"
        }.joined(separator: "&")
        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded"
        return HTTPRequest(method: .post, url: url, headers: merged, body: Data(body.utf8))
    }

    /// The form fields of a `form(...)` request, decoded — for tests asserting on what was sent.
    public var formFields: [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            fields[key] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
        }
        return fields
    }
}

/// Requests carry bearer tokens, codes, verifiers and refresh tokens. Never let one print them
/// through string interpolation or a debugger `po`.
extension HTTPRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "HTTPRequest(\(method.rawValue) \(url.scheme ?? "")://\(url.host ?? "")\(url.path), <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

extension HTTPResponse: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "HTTPResponse(\(statusCode), \(body.count) bytes, <redacted>)" }
    public var debugDescription: String { description }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPTransportError: Error, Sendable, Equatable {
    case notHTTP
    /// Connectors only ever talk to provider APIs over TLS.
    case insecureURL
    /// The body exceeded `URLSessionTransport.maxResponseBytes`.
    case responseTooLarge
}

/// The real transport — the only implementation that opens sockets, never used in tests.
/// Ephemeral session (no cookies, cache or credential storage on disk), HTTPS only, redirects
/// refused (so a bearer token or form body is never replayed to another URL), and bodies capped.
public struct URLSessionTransport: HTTPTransport {
    /// Calendar pages at `maxResults=250` / token responses are far below this.
    public static let maxResponseBytes = 4 * 1024 * 1024

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw HTTPTransportError.insecureURL }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        let (bytes, response) = try await session.bytes(for: urlRequest, delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.notHTTP }
        if http.expectedContentLength > Int64(Self.maxResponseBytes) { throw HTTPTransportError.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > Self.maxResponseBytes { throw HTTPTransportError.responseTooLarge }
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }
}

/// Answers every redirect with "don't follow"; the 3xx then surfaces as a non-2xx response.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Test transport: answers from a handler and records every request so tests can assert on the
/// exact URL, headers and form fields that would have gone over the wire.
public actor RecordingTransport: HTTPTransport {
    public typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let handler: Handler
    public private(set) var requests: [HTTPRequest] = []

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}
