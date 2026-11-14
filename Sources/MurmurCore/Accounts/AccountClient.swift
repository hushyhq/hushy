import Foundation

public struct AccountConfiguration: Sendable {
    public let url: URL
    public let anonKey: String
    /// The website the app signs in through. Not a build setting: the page and the app's return address must agree.
    public let siteURL: URL

    /// Nil unless the build uses the Hushy services (`HushyServices.official`) and carries the
    /// account service's address and publishable key.
    public init?(bundle: Bundle = .main) {
        guard HushyServices(bundle: bundle).isOfficial,
              let raw = bundle.object(forInfoDictionaryKey: "HushySupabaseURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "HushySupabaseAnonKey") as? String,
              !key.isEmpty, !key.contains("__") else { return nil }
        self.url = url
        anonKey = key
        siteURL = Self.defaultSiteURL
    }

    public static let defaultSiteURL = URL(string: "https://tryhushy.com")!

    public init(url: URL, anonKey: String, siteURL: URL = AccountConfiguration.defaultSiteURL) {
        self.url = url; self.anonKey = anonKey; self.siteURL = siteURL
    }

    public var accountURL: URL { siteURL.appending(path: "account") }

}

public struct AccountSession: Codable, Sendable {
    public let userID: String
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let email: String?
    enum CodingKeys: String, CodingKey { case userID, accessToken = "access_token", refreshToken = "refresh_token", expiresAt, email }
    public init(userID: String, accessToken: String, refreshToken: String, expiresAt: Date, email: String?) {
        self.userID = userID
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.email = email
    }
}

public struct AccountSessionStore: Sendable {
    private let keys: any KeyStoreProtocol
    private let account = "account.session"
    public init(keys: any KeyStoreProtocol = FileKeyStore.account) { self.keys = keys }
    public func load() throws -> AccountSession? {
        guard let bytes = try keys.read(account: account) else { return nil }
        return try JSONDecoder().decode(AccountSession.self, from: bytes)
    }
    public func save(_ session: AccountSession) throws { try keys.write(JSONEncoder().encode(session), account: account) }
    public func clear() throws { try keys.delete(account: account) }
}

/// Account traffic contains only the sign-in hand-off and the resulting plan. Dictation
/// text, notes, audio, learned terms and history never leave this Mac through this client.
public struct AccountClient: Sendable {
    public let configuration: AccountConfiguration
    private let transport: URLSession
    public init(configuration: AccountConfiguration, transport: URLSession = .shared) {
        self.configuration = configuration; self.transport = transport
    }
    /// The site's sign-in page in "app" mode. The challenge is the SHA-256 of a secret that only
    /// this process holds; the page never sees the secret.
    public func appSignInURL(challenge: String) -> URL? {
        guard AppSignInShape.isValue(challenge),
              var parts = URLComponents(url: configuration.siteURL.appending(path: "login"), resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "app", value: challenge)]
        return parts.url
    }
    /// How long the claim may take. The person is looking at a waiting screen.
    public static let claimTimeout: TimeInterval = 15
    /// Trades the hand-off id and the app's secret for the session the browser signed in. The site
    /// takes this from the app only (no Origin, no cookies), keeps nothing, and answers every
    /// failure the same way. Neither value may be logged.
    public func claimRequest(id: String, secret: String) throws -> URLRequest {
        guard AppSignInShape.isValue(id), AppSignInShape.isValue(secret) else { throw AccountError.requestFailed }
        var request = URLRequest(url: configuration.siteURL.appending(path: "api/app-signin/claim"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.claimTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "secret": secret])
        return request
    }
    public func claimSignIn(id: String, secret: String) async throws -> AccountSession {
        try decodeSession(try await send(claimRequest(id: id, secret: secret)))
    }
    public func refresh(_ token: String) async throws -> AccountSession {
        var request = try makeRequest("auth/v1/token?grant_type=refresh_token", method: "POST")
        request.timeoutInterval = Self.approvalTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": token])
        return try decodeSession(try await send(request))
    }
    public func signOut(_ accessToken: String) async throws {
        var request = try makeRequest("auth/v1/logout", method: "POST")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }
    /// Ends only the session this token belongs to. Plain `signOut` uses the service's default,
    /// which ends every session of the account (the website, other Macs). Use this for a session
    /// the app made and then did not keep.
    public func signOutThisSession(_ accessToken: String) async throws {
        var request = try makeRequest("auth/v1/logout?scope=local", method: "POST")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }
    /// The gate waits on the token refresh and the approval read with a spinner, so neither may hang for the system default (60 s).
    public static let approvalTimeout: TimeInterval = 15
    /// PostgREST returns [] for a missing profile. Only a successful response can deny access.
    public func betaApproval(accessToken: String, userID: String) async throws -> Bool {
        var components = URLComponents(url: configuration.url.appending(path: "rest/v1/site_profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userID)"), URLQueryItem(name: "select", value: "approved_at")]
        guard let url = components?.url else { throw AccountError.requestFailed }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.approvalTimeout
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let rows = try JSONDecoder().decode([ApprovalRow].self, from: try await send(request))
        return rows.first?.approvedAt != nil
    }
    /// Whether the service is open to everyone, from the website's public answer. Once it is, a
    /// signed-in person needs no approval. The request carries no token, cookie or identifier and
    /// the answer says nothing about the person. A failure throws; callers treat it as "not open".
    public func serviceIsOpen() async throws -> Bool {
        var request = URLRequest(url: configuration.siteURL.appending(path: "api/service"))
        request.timeoutInterval = Self.approvalTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        return try JSONDecoder().decode(ServiceRow.self, from: try await send(request)).open
    }
    /// The signed-in person's own invite code. Row-level security returns only their row, and the
    /// column is written only by the founder console. `nil` means no code exists yet; an HTTP
    /// failure throws, so it is never mistaken for "no code". The value must never be logged.
    public func inviteCode(accessToken: String, userID: String) async throws -> String? {
        var components = URLComponents(url: configuration.url.appending(path: "rest/v1/site_profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userID)"), URLQueryItem(name: "select", value: "invite_code")]
        guard let url = components?.url else { throw AccountError.requestFailed }
        var request = URLRequest(url: url)
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let rows = try JSONDecoder().decode([InviteCodeRow].self, from: try await send(request))
        guard let code = rows.first?.inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
        return code
    }
    public func entitlement(_ accessToken: String, userID: String) async throws -> AccountEntitlement {
        var request = try makeRequest("rest/v1/rpc/my_entitlement", method: "POST")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formats: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
            for options in formats {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid timestamp")
        }
        let rows = try decoder.decode([EntitlementRow].self, from: try await send(request))
        return AccountEntitlement(userID: userID, isPro: rows.first?.plan == "pro", validUntil: rows.first?.validUntil, verifiedAt: Date())
    }
    private func makeRequest(_ path: String, method: String) throws -> URLRequest {
        let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = configuration.url.appending(path: pieces[0])
        if pieces.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = pieces[1]
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AccountError.requestFailed }
        guard (200..<300).contains(response.statusCode) else { throw AccountError.httpStatus(response.statusCode) }
        return data
    }
    private func decodeSession(_ data: Data) throws -> AccountSession {
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let userID = payload.user?.id else { throw AccountError.requestFailed }
        return AccountSession(userID: userID, accessToken: payload.accessToken, refreshToken: payload.refreshToken, expiresAt: Date().addingTimeInterval(payload.expiresIn), email: payload.user?.email)
    }
}
private struct TokenResponse: Decodable {
    let accessToken: String; let refreshToken: String; let expiresIn: TimeInterval; let user: User?
    struct User: Decodable { let id: String; let email: String? }
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", user }
}
private struct EntitlementRow: Decodable {
    let plan: String; let validUntil: Date?
    enum CodingKeys: String, CodingKey { case plan, validUntil = "valid_until" }
}
private struct ApprovalRow: Decodable {
    let approvedAt: String?
    enum CodingKeys: String, CodingKey { case approvedAt = "approved_at" }
}
private struct ServiceRow: Decodable { let open: Bool }
private struct InviteCodeRow: Decodable {
    let inviteCode: String?
    enum CodingKeys: String, CodingKey { case inviteCode = "invite_code" }
}
public enum AccountError: Error { case requestFailed, httpStatus(Int) }
