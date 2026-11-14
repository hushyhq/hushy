import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// A calendar provider Hushy can read directly, with the user's own sign-in, from this Mac.
/// EventKit stays the zero-setup path (`CalendarSourceKind.eventKit`); these exist for people
/// who never added their work calendar to macOS. See `docs/product/CONNECTORS.md` §1.1.
public enum CalendarProvider: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case google
    case microsoft

    public var displayName: String {
        switch self {
        case .google: "Google Calendar"
        case .microsoft: "Outlook Calendar"
        }
    }

    var sourceKind: CalendarSourceKind {
        switch self {
        case .google: .google
        case .microsoft: .microsoft
        }
    }
}

/// Endpoints and client identity for one provider's authorization-code + PKCE flow. Built by
/// `CalendarConnectorConfiguration` from the build's Info.plist; never hardcoded with real ids.
public struct OAuthClientConfiguration: Sendable, Equatable {
    public let provider: CalendarProvider
    public let clientID: String
    /// Google issues a "client secret" for Desktop clients and documents that it is "obviously
    /// not treated as a secret" for installed apps; it is configuration, sent only on the token
    /// endpoint. Microsoft public clients must never have one.
    public let clientSecret: String?
    public let authorizationURL: URL
    public let tokenURL: URL
    public let scopes: [String]
    /// Provider-specific `/authorize` extras (Google: `access_type=offline`).
    public let extraAuthorizationParameters: [String: String]
    /// Always `127.0.0.1` for both providers — never `localhost`. The listener binds 127.0.0.1
    /// only; a `localhost` redirect would let a browser try `[::1]` first, where another local
    /// process could be squatting the same port and receive the code. The Entra app registration
    /// must therefore list `http://127.0.0.1` (added via the manifest), not `http://localhost`.
    public let loopbackHost: String
    /// RFC 7009 revocation endpoint (Google). Nil when disconnect is local-only (Microsoft has no
    /// public-client revocation endpoint for refresh tokens).
    public let revocationURL: URL?

    public init(
        provider: CalendarProvider, clientID: String, clientSecret: String?,
        authorizationURL: URL, tokenURL: URL, scopes: [String],
        extraAuthorizationParameters: [String: String] = [:], loopbackHost: String = "127.0.0.1",
        revocationURL: URL? = nil
    ) {
        self.provider = provider
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.extraAuthorizationParameters = extraAuthorizationParameters
        self.loopbackHost = loopbackHost
        self.revocationURL = revocationURL
    }

    /// RFC 9207: when the redirect carries `iss`, it must be this provider's authorization server.
    /// Google: exactly `https://accounts.google.com`. Microsoft (`/common`): the tenant-specific
    /// `https://login.microsoftonline.com/{tenant}/v2.0`.
    public func isExpectedIssuer(_ issuer: String) -> Bool {
        switch provider {
        case .google:
            return issuer == "https://accounts.google.com"
        case .microsoft:
            guard let url = URL(string: issuer), url.scheme == "https", url.host == "login.microsoftonline.com",
                  url.port == nil, url.user == nil, url.query == nil
            else { return false }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0].isEmpty && !parts[1].isEmpty && parts[2] == "v2.0"
                && parts[1].allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        }
    }

    public static let callbackPath = "/callback"

    public func redirectURI(port: Int) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = loopbackHost
        components.port = port
        components.path = Self.callbackPath
        // Force-unwrap is safe: scheme/host/port/path are all well-formed by construction.
        return components.url!
    }
}

extension OAuthClientConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OAuthClientConfiguration(\(provider.rawValue), scopes: \(scopes.joined(separator: " ")), secret: \(clientSecret == nil ? "none" : "<redacted>"))"
    }

    public var debugDescription: String { description }
}

/// Cryptographically secure random bytes (`SecRandomCopyBytes`, falling back to the system
/// CSPRNG behind `SystemRandomNumberGenerator` if the Security call ever fails).
enum SecureRandom {
    static func bytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess { return Data(bytes) }
        #endif
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        return Data(bytes)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// RFC 7636 Proof Key for Code Exchange, S256 only. Deterministic given a verifier so the RFC's
/// own Appendix B vector can be asserted.
public struct PKCEChallenge: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public static let method = "S256"

    /// RFC 7636 §4.1 unreserved alphabet.
    static let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(verifier: String) throws {
        guard (43...128).contains(verifier.count), verifier.allSatisfy(Self.allowedCharacters.contains) else {
            throw OAuthError.invalidVerifier
        }
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// 32 CSPRNG bytes, base64url without padding → 43 characters (256 bits of entropy).
    public static func generate() -> PKCEChallenge {
        // Force-try is safe: the string is always 43 chars from the base64url alphabet.
        try! PKCEChallenge(verifier: Base64URL.encode(SecureRandom.bytes(count: 32)))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`.
    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

extension PKCEChallenge: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PKCEChallenge(<redacted>)" }
    public var debugDescription: String { description }
}

/// One authorization attempt: the URL to open in the system browser, and everything needed to
/// validate the redirect that comes back. Single-use: build a fresh one per sign-in.
public struct OAuthAuthorizationRequest: Sendable, Equatable {
    public let configuration: OAuthClientConfiguration
    public let redirectURI: URL
    public let state: String
    public let pkce: PKCEChallenge
    /// Per-attempt `/authorize` extras on top of the configuration's (e.g. `prompt=consent`).
    public let additionalParameters: [String: String]

    /// Longest authorization code / error string accepted from a redirect.
    static let maxCodeLength = 4096

    public init(
        configuration: OAuthClientConfiguration, redirectURI: URL, state: String = Self.randomState(),
        pkce: PKCEChallenge = .generate(), additionalParameters: [String: String] = [:]
    ) {
        self.additionalParameters = additionalParameters
        self.configuration = configuration
        self.redirectURI = redirectURI
        self.state = state
        self.pkce = pkce
    }

    /// 16 CSPRNG bytes, base64url (22 characters, 128 bits).
    public static func randomState() -> String {
        Base64URL.encode(SecureRandom.bytes(count: 16))
    }

    /// The `/authorize` URL: code flow, S256 challenge, state, and the provider's extras.
    public var url: URL {
        // Force-unwraps are safe: `authorizationURL` is a fixed https constant from
        // `CalendarConnectorConfiguration`, and query items always re-serialize.
        var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCEChallenge.method),
        ]
        let extras = configuration.extraAuthorizationParameters.merging(additionalParameters) { _, new in new }
        for key in extras.keys.sorted() {
            items.append(URLQueryItem(name: key, value: extras[key]))
        }
        components.queryItems = items
        // `URLQueryItem` leaves "+" alone, which servers read as a space; encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Validates the redirect the loopback listener received. It must come back to exactly our
    /// redirect URI; `state` must be present once and equal ours (checked before anything else,
    /// so a forged redirect can't even inject an error message); a provider `error` surfaces as
    /// `.providerError`; and exactly one non-empty, printable `code` must be present.
    public func callback(from redirect: URL) throws -> OAuthCallback {
        guard let components = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              components.host?.lowercased() == redirectURI.host?.lowercased(),
              components.port == redirectURI.port,
              components.path == redirectURI.path
        else { throw OAuthError.unexpectedRedirect }
        let items = components.queryItems ?? []
        func single(_ name: String) throws -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { throw OAuthError.unexpectedRedirect }
            return matches.first?.value
        }
        guard let receivedState = try single("state"), Self.constantTimeEquals(receivedState, state) else {
            throw OAuthError.stateMismatch
        }
        if let issuer = try single("iss"), !configuration.isExpectedIssuer(issuer) {
            throw OAuthError.issuerMismatch
        }
        if let error = try single("error") {
            throw OAuthError.providerError(
                code: OAuthText.sanitized(error, limit: 64) ?? "unknown",
                description: try single("error_description").flatMap { OAuthText.sanitized($0, limit: 256) })
        }
        guard let code = try single("code"), !code.isEmpty, code.count <= Self.maxCodeLength,
              OAuthText.isTokenSafe(code)
        else { throw OAuthError.missingCode }
        return OAuthCallback(code: code, state: receivedState)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

extension OAuthAuthorizationRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "OAuthAuthorizationRequest(\(configuration.provider.rawValue), <redacted>)" }
    public var debugDescription: String { description }
}

public struct OAuthCallback: Sendable, Equatable {
    public let code: String
    public let state: String

    public init(code: String, state: String) {
        self.code = code
        self.state = state
    }
}

extension OAuthCallback: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "OAuthCallback(<redacted>)" }
    public var debugDescription: String { description }
}

/// Opens the browser and waits for the redirect. `LoopbackRedirectListener` is the real one
/// (a single-use 127.0.0.1 listener; `ASWebAuthenticationSession` can't receive loopback
/// redirects on macOS and Google no longer accepts custom schemes for desktop apps); tests use a
/// fake that returns a canned redirect URL.
public protocol OAuthAuthorizing: Sendable {
    /// The port the redirect must be sent to (the listener's ephemeral port).
    var redirectPort: Int { get }
    /// Opens `request.url` and returns the full redirect URL received at `request.redirectURI`.
    func authorize(_ request: OAuthAuthorizationRequest) async throws -> URL
}

public enum OAuthError: Error, Sendable, Equatable {
    case invalidVerifier
    case stateMismatch
    case missingCode
    /// The redirect didn't come back to our redirect URI, or repeated a parameter.
    case unexpectedRedirect
    case providerError(code: String, description: String?)
    case malformedTokenResponse
    case tokenEndpoint(status: Int, error: String?)
    /// The user unticked the calendar permission on the consent screen (Google's granular
    /// consent), so the token can't read events.
    case scopeNotGranted
    /// The refresh token was revoked or expired (`invalid_grant`), or no tokens are stored: the
    /// user must sign in again.
    case reauthorizationRequired
    case notConfigured(CalendarProvider)
    /// The redirect's RFC 9207 `iss` named a different authorization server (mix-up defense).
    case issuerMismatch
    /// The code exchange returned no refresh token; storing it would silently expire in an hour.
    case missingRefreshToken
    /// The loopback redirect never arrived.
    case timedOut
    case listenerFailed
}

/// Access + refresh tokens for one account, as stored in the Keychain by `OAuthTokenStore`.
public struct OAuthTokenSet: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// True when the access token should be refreshed before use: expired, or within `leeway`.
    public func needsRefresh(now: Date, leeway: TimeInterval = OAuthTokenClient.refreshLeeway) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

extension OAuthTokenSet: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "OAuthTokenSet(<redacted>, expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

/// Defensive checks on strings that come back from a provider and are later put into an HTTP
/// header or shown in UI.
enum OAuthText {
    /// Visible ASCII only (0x21–0x7E): no spaces, CR/LF or non-ASCII, so a hostile token can't
    /// inject a header line.
    static func isTokenSafe(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// Printable ASCII (spaces allowed), truncated; nil if nothing printable remains.
    static func sanitized(_ text: String, limit: Int) -> String? {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(limit)))
        return printable.isEmpty ? nil : printable
    }
}

/// Talks to the provider's token endpoint: code → tokens, and refresh. Pure over an injected
/// transport; `now` is passed in so expiry is testable.
public struct OAuthTokenClient: Sendable {
    /// Refresh when less than this remains, so a token never expires mid-request.
    public static let refreshLeeway: TimeInterval = 60
    /// Token responses are a few KB; anything larger is not a token response.
    static let maxResponseBytes = 64 * 1024
    static let maxTokenLength = 16 * 1024
    static let defaultLifetime: TimeInterval = 3600
    /// Floor for `expires_in`, so a bogus 0/negative value can't force a refresh on every use.
    static let minLifetime: TimeInterval = 5 * 60
    /// Clamp for `expires_in` (providers use ~1 h); a bogus huge value must not pin a token.
    static let maxLifetime: TimeInterval = 24 * 3600
    /// Scopes that are protocol flags, not grants to check for.
    static let nonGrantScopes: Set<String> = ["offline_access", "openid", "profile", "email"]

    public let configuration: OAuthClientConfiguration
    private let transport: any HTTPTransport

    public init(configuration: OAuthClientConfiguration, transport: any HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func exchange(_ callback: OAuthCallback, verifier: String, redirectURI: URL, now: Date) async throws -> OAuthTokenSet {
        var fields = [
            "grant_type": "authorization_code",
            "code": callback.code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": configuration.clientID,
        ]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        let tokens = try await post(fields: fields, previousRefreshToken: nil, now: now)
        try checkGrantedScopes(tokens.scope)
        guard tokens.refreshToken != nil else { throw OAuthError.missingRefreshToken }
        return tokens
    }

    /// Best-effort RFC 7009 revocation of the refresh token (Google), so a later reconnect gets a
    /// fresh consent and refresh token. Errors are swallowed on purpose: local deletion must not
    /// depend on the network. No-op when the provider has no revocation endpoint (Microsoft).
    public func revoke(_ tokens: OAuthTokenSet) async {
        guard let url = configuration.revocationURL else { return }
        let token = tokens.refreshToken ?? tokens.accessToken
        _ = try? await transport.send(HTTPRequest.form(url: url, fields: ["token": token]))
    }

    public func refresh(_ tokens: OAuthTokenSet, now: Date) async throws -> OAuthTokenSet {
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.reauthorizationRequired }
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        return try await post(fields: fields, previousRefreshToken: refreshToken, now: now)
    }

    /// When the provider reports what it granted, every requested read scope must be in it
    /// (Google lets people untick individual scopes). Microsoft reports fully-qualified names
    /// (`https://graph.microsoft.com/Calendars.Read`), so a `/`-suffix match counts.
    func checkGrantedScopes(_ granted: String?) throws {
        guard let granted else { return }
        let grantedScopes = granted.split(separator: " ").map { String($0).lowercased() }
        for scope in configuration.scopes where !Self.nonGrantScopes.contains(scope.lowercased()) {
            let wanted = scope.lowercased()
            guard grantedScopes.contains(where: { $0 == wanted || $0.hasSuffix("/" + wanted) }) else {
                throw OAuthError.scopeNotGranted
            }
        }
    }

    private func post(fields: [String: String], previousRefreshToken: String?, now: Date) async throws -> OAuthTokenSet {
        let request = HTTPRequest.form(url: configuration.tokenURL, fields: fields, headers: ["Accept": "application/json"])
        let response = try await transport.send(request)
        let json: [String: Any]? = response.body.count <= Self.maxResponseBytes
            ? (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            : nil
        guard response.isSuccess else {
            let error = (json?["error"] as? String).flatMap { OAuthText.sanitized($0, limit: 64) }
            if error == "invalid_grant" { throw OAuthError.reauthorizationRequired }
            throw OAuthError.tokenEndpoint(status: response.statusCode, error: error)
        }
        guard let json,
              let accessToken = json["access_token"] as? String,
              accessToken.count <= Self.maxTokenLength, OAuthText.isTokenSafe(accessToken)
        else { throw OAuthError.malformedTokenResponse }
        if let tokenType = json["token_type"] as? String, tokenType.lowercased() != "bearer" {
            throw OAuthError.malformedTokenResponse
        }
        var refreshToken = previousRefreshToken
        if let newRefresh = json["refresh_token"] as? String {
            guard newRefresh.count <= Self.maxTokenLength, OAuthText.isTokenSafe(newRefresh) else {
                throw OAuthError.malformedTokenResponse
            }
            refreshToken = newRefresh
        }
        return OAuthTokenSet(
            accessToken: accessToken, refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(Self.lifetime(json["expires_in"])),
            scope: (json["scope"] as? String).flatMap { OAuthText.sanitized($0, limit: 2048) })
    }

    /// `expires_in` as a JSON number or numeric string; 1 h when absent; clamped to 5 min…24 h.
    static func lifetime(_ value: Any?) -> TimeInterval {
        let seconds: Double? = switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.doubleValue
        case let text as String: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
        guard let seconds, seconds.isFinite else { return defaultLifetime }
        return min(max(seconds, minLifetime), maxLifetime)
    }
}

/// The whole sign-in, minus the browser: build a request for the authorizer's port, wait for the
/// redirect, validate it, exchange the code, store the tokens.
public enum OAuthConnectFlow {
    public static func connect(session: OAuthSession, authorizer: any OAuthAuthorizing) async throws {
        let configuration = session.configuration
        // Google only returns a refresh token on a consent screen; force one whenever we don't
        // already hold a refresh token (first connect, or reconnect after revoke/invalid_grant).
        let holdsRefreshToken = await session.hasRefreshToken()
        let needsConsent = configuration.provider == .google && !holdsRefreshToken
        let request = OAuthAuthorizationRequest(
            configuration: configuration, redirectURI: configuration.redirectURI(port: authorizer.redirectPort),
            additionalParameters: needsConsent ? ["prompt": "consent"] : [:])
        let redirect = try await authorizer.authorize(request)
        let callback = try request.callback(from: redirect)
        try await session.complete(callback, request: request)
    }
}
