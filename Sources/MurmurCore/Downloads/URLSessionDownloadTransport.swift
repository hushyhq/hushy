import Foundation
import Synchronization

/// `DownloadTransport` over `URLSession`: one GET per attempt, `Range`/`If-Range` on resume, the
/// body delivered as the chunks URLSession receives (never the whole 2 GB file in memory).
/// Redirects (Hugging Face → its CDN) are followed by URLSession; the validator is the final
/// response's strong ETag, or its Last-Modified date. A bearer token (the model host,
/// `AuthorizedDownloadTransport`) is sent only to the host it was meant for: a redirect to any other
/// host drops it.
public struct URLSessionDownloadTransport: BearerDownloadTransport {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        let copy = configuration.copy() as? URLSessionConfiguration ?? .default
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.urlCache = nil
        self.configuration = copy
    }

    /// The request for one attempt (public for tests).
    public static func request(for url: URL, from offset: Int64, ifRange validator: String?, bearer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.httpShouldHandleCookies = false
        }
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let validator, !validator.isEmpty { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        return request
    }

    /// A strong ETag, else Last-Modified; nil when the server gave neither (weak ETags can't
    /// guard a byte range).
    public static func validator(from response: HTTPURLResponse) -> String? {
        if let tag = response.value(forHTTPHeaderField: "ETag"), !tag.isEmpty, !tag.hasPrefix("W/") { return tag }
        if let modified = response.value(forHTTPHeaderField: "Last-Modified"), !modified.isEmpty { return modified }
        return nil
    }

    /// `Retry-After` as seconds; an HTTP date or anything else is ignored (nil).
    public static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(raw), seconds >= 0, seconds.isFinite else { return nil }
        return seconds
    }

    /// The request a redirect may follow: the same, minus the bearer token when the host changes.
    public static func redirect(_ next: URLRequest, from original: URLRequest?) -> URLRequest {
        guard original?.value(forHTTPHeaderField: "Authorization") != nil,
              next.url?.host?.lowercased() != original?.url?.host?.lowercased() || next.url?.scheme != "https" else { return next }
        var stripped = next
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }

    public func open(_ url: URL, from offset: Int64, ifRange validator: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>)
    {
        try await open(url, from: offset, ifRange: validator, bearer: nil)
    }

    public func open(_ url: URL, from offset: Int64, ifRange validator: String?, bearer: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>)
    {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let relay = StreamingRelay(body: continuation)
        let session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        let task = session.dataTask(with: Self.request(for: url, from: offset, ifRange: validator, bearer: bearer))
        continuation.onTermination = { _ in
            task.cancel()
            session.finishTasksAndInvalidate()
        }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (head: CheckedContinuation<HTTPURLResponse, Error>) in
                relay.setHead(head)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (TransportResponse(statusCode: response.statusCode, validator: Self.validator(from: response),
                                  retryAfter: Self.retryAfter(from: response)), stream)
    }
}

/// Bridges one data task's delegate callbacks to the head continuation and the body stream.
private final class StreamingRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let body: AsyncThrowingStream<Data, Error>.Continuation
    private let head = Mutex<CheckedContinuation<HTTPURLResponse, Error>?>(nil)

    init(body: AsyncThrowingStream<Data, Error>.Continuation) {
        self.body = body
    }

    func setHead(_ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        head.withLock { $0 = continuation }
    }

    private func resumeHead(_ result: Result<HTTPURLResponse, Error>) {
        let pending = head.withLock { value -> CheckedContinuation<HTTPURLResponse, Error>? in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            resumeHead(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        resumeHead(.success(http))
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(URLSessionDownloadTransport.redirect(request, from: task.originalRequest))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resumeHead(.failure(error))
            body.finish(throwing: error)
        } else {
            resumeHead(.failure(URLError(.badServerResponse)))
            body.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
