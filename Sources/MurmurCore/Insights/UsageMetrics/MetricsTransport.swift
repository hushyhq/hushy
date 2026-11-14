import Foundation

/// What the server said about one upload, reduced to what the uploader decides on.
public enum MetricsTransportOutcome: Sendable, Equatable {
    /// 2xx: the batch is stored; remove it from the queue.
    case accepted
    /// The server will never take this batch (a 4xx other than "try later", or a redirect): drop it.
    case rejected
    /// Timeout, no connection, 408/425/429 or 5xx: keep it and try again on a later day.
    case retryLater
}

/// The network behind a seam, so tests use a fake and the app uses `URLSessionMetricsTransport`.
public protocol MetricsTransport: Sendable {
    /// Sends exactly `body` (the batch's `encodedBody()`) to `endpoint`.
    func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome
}

/// A transport that cannot reach anything. The app uses it whenever no endpoint is configured,
/// so even a bug upstream could not send a byte.
public struct InertMetricsTransport: MetricsTransport {
    public init() {}
    public func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome { .retryLater }
}

/// The real transport. A POST with the batch bytes and one header (`Content-Type`). It sends no
/// cookies, no credentials and no cache validators, keeps nothing between calls, and refuses
/// redirects (a redirect could carry the body to another host). The user agent is whatever the
/// system sends by default.
public struct URLSessionMetricsTransport: MetricsTransport {
    public static let requestTimeout: TimeInterval = 10
    public static let contentType = "application/json"

    private let session: URLSession

    public init() {
        session = URLSession(
            configuration: Self.configuration(), delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// For tests: a session with a stubbed `URLProtocol`. Uses the same configuration otherwise.
    public init(protocolClasses: [AnyClass]) {
        let configuration = Self.configuration()
        configuration.protocolClasses = protocolClasses
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func request(to endpoint: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    public func post(_ body: Data, to endpoint: URL) async -> MetricsTransportOutcome {
        // Never rely on the caller: only a plain https address with a host is ever contacted.
        guard MetricsEndpoint.parse(endpoint.absoluteString) != nil else { return .retryLater }
        do {
            let (_, response) = try await session.data(for: Self.request(to: endpoint, body: body))
            guard let http = response as? HTTPURLResponse else { return .retryLater }
            return Self.outcome(forStatus: http.statusCode)
        } catch {
            return .retryLater
        }
    }

    static func outcome(forStatus status: Int) -> MetricsTransportOutcome {
        switch status {
        case 200...299: .accepted
        case 408, 425, 429, 500...599: .retryLater
        default: .rejected
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
