import Foundation

/// What "Include my app version and Mac model" adds. Four short facts about the app and the Mac, never
/// dictation text, history or app names. Each is cut to what the site accepts (`site/worker/feedback.js`):
/// printable ASCII only, at most the length below, and left out when nothing is left.
public struct FeedbackAppInfo: Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var macOS: String?
    public var model: String?

    public init(version: String? = nil, build: String? = nil, macOS: String? = nil, model: String? = nil) {
        self.version = version; self.build = build; self.macOS = macOS; self.model = model
    }

    /// The request's `app` object: only the facts that survive cleaning, each cut to the length the site
    /// accepts (version 32, build 16, macos 32, model 64). Nil when none do.
    var cleaned: [String: String]? {
        var result: [String: String] = [:]
        for (key, limit, raw) in [("version", 32, version), ("build", 16, build), ("macos", 32, macOS), ("model", 64, model)] {
            guard let raw else { continue }
            let text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }))
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result[key] = String(text.prefix(limit)) }
        }
        return result.isEmpty ? nil : result
    }

    /// This app on this Mac: "1.4.2", "2622", "15.1.0", "Mac14,5 (Apple M2 Pro)".
    public static func current(bundle: Bundle = .main) -> FeedbackAppInfo {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let identifier = MachineProfile.sysctlString("hw.model")
        let chip = MachineProfile.sysctlString("machdep.cpu.brand_string")
        let model = [identifier, chip.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return FeedbackAppInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            macOS: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            model: model.isEmpty ? nil : model)
    }
}

public enum FeedbackLimits {
    /// Characters (Unicode scalars, the way the site counts them) a message may have.
    public static let maxCharacters = 5000
    /// Sends a person may make in one UTC day; the site refuses the sixth.
    public static let perDay = 5

    public static func characterCount(_ message: String) -> Int {
        message.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }
}

/// How a send ended, in the terms the sheet needs.
public enum FeedbackOutcome: Equatable, Sendable {
    case sent
    /// No session, or the site did not accept the one held (401).
    case signInNeeded
    /// This account has sent its five for the day.
    case dailyLimit
    /// The site's shared daily ceiling is reached.
    case busyToday
    /// Too many from this address in a minute.
    case slowDown
    case tooLong
    /// No connection, a timeout, or the site could not send it. Worth trying again.
    case failed
}

public protocol FeedbackTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A private session: no cookies, no cache, nothing kept between requests.
public struct URLSessionFeedbackTransport: FeedbackTransport {
    private let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Sends one piece of feedback to the site (`POST /api/feedback`, contract in `admin/APP-FLAGS-CONTRACT.md`).
/// The request carries the account's access token and the message; with the person's tick, four short facts
/// about the app and the Mac. It never carries dictation text, history, app names, the address (the site
/// takes that from the token) or any identifier beside the token.
public struct FeedbackClient: Sendable {
    public static let endpoint = AccountConfiguration.defaultSiteURL.appending(path: "api/feedback")
    public static let timeout: TimeInterval = 20

    private let endpoint: URL?
    private let transport: FeedbackTransport

    public init(endpoint: URL = FeedbackClient.endpoint, transport: FeedbackTransport = URLSessionFeedbackTransport()) {
        self.endpoint = MetricsEndpoint.parse(endpoint.absoluteString)
        self.transport = transport
    }

    /// The exact body, or nil for a message that is empty or over the limit.
    public func body(message: String, appInfo: FeedbackAppInfo?) -> Data? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, FeedbackLimits.characterCount(text) <= FeedbackLimits.maxCharacters else { return nil }
        var object: [String: Any] = ["message": text]
        if let app = appInfo?.cleaned { object["app"] = app }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public func request(message: String, appInfo: FeedbackAppInfo?, accessToken: String) -> URLRequest? {
        guard let endpoint, !accessToken.isEmpty, let body = body(message: message, appInfo: appInfo) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    public func send(message: String, appInfo: FeedbackAppInfo?, accessToken: String) async -> FeedbackOutcome {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if FeedbackLimits.characterCount(text) > FeedbackLimits.maxCharacters { return .tooLong }
        guard let request = request(message: message, appInfo: appInfo, accessToken: accessToken) else { return .failed }
        do {
            let (data, response) = try await transport.send(request)
            return Self.outcome(status: response.statusCode, data: data)
        } catch {
            return .failed
        }
    }

    static func outcome(status: Int, data: Data) -> FeedbackOutcome {
        switch status {
        case 200..<300: return .sent
        case 401: return .signInNeeded
        case 413: return .tooLong
        case 429:
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            switch code {
            case "daily_limit": return .dailyLimit
            case "busy_today": return .busyToday
            default: return .slowDown
            }
        default: return .failed
        }
    }
}
