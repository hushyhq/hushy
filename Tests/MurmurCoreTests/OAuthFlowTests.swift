import Foundation
import Testing
@testable import MurmurCore

@Suite("PKCE (RFC 7636)")
struct PKCETests {
    @Test("RFC 7636 Appendix B test vector")
    func rfcVector() throws {
        let pkce = try PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCEChallenge.method == "S256")
    }

    @Test("generated verifier is 43 chars of the unreserved alphabet and unique")
    func generated() {
        let first = PKCEChallenge.generate(), second = PKCEChallenge.generate()
        #expect(first.verifier.count == 43)
        #expect(first.verifier.allSatisfy(PKCEChallenge.allowedCharacters.contains))
        #expect(first.verifier != second.verifier)
        #expect(first.challenge == PKCEChallenge.challenge(for: first.verifier))
    }

    @Test("rejects 42 chars, 129 chars, '+' and '/'")
    func rejectsBadVerifiers() {
        let base = String(repeating: "a", count: 43)
        #expect(throws: OAuthError.invalidVerifier) { try PKCEChallenge(verifier: String(base.dropLast())) }
        #expect(throws: OAuthError.invalidVerifier) { try PKCEChallenge(verifier: String(repeating: "a", count: 129)) }
        #expect(throws: OAuthError.invalidVerifier) { try PKCEChallenge(verifier: String(base.dropLast()) + "+") }
        #expect(throws: OAuthError.invalidVerifier) { try PKCEChallenge(verifier: String(base.dropLast()) + "/") }
        #expect((try? PKCEChallenge(verifier: String(repeating: "a", count: 128))) != nil)
    }

    @Test("challenge is deterministic")
    func deterministic() {
        #expect(PKCEChallenge.challenge(for: String(repeating: "x", count: 50)) == PKCEChallenge.challenge(for: String(repeating: "x", count: 50)))
    }

    @Test("state is 22 random base64url chars")
    func state() {
        let a = OAuthAuthorizationRequest.randomState(), b = OAuthAuthorizationRequest.randomState()
        #expect(a.count == 22 && a != b)
        #expect(a.allSatisfy(PKCEChallenge.allowedCharacters.contains))
    }

    @Test("secrets never appear in descriptions")
    func redaction() throws {
        let pkce = try PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(!"\(pkce)".contains("dBjft"))
        let tokens = ConnectorFixtures.tokens(access: "secret-access", refresh: "secret-refresh", expiresIn: 60)
        #expect(!"\(tokens)".contains("secret") && !String(reflecting: tokens).contains("secret"))
        #expect(!"\(OAuthCallback(code: "the-code", state: "s"))".contains("the-code"))
        #expect(!"\(ConnectorFixtures.google)".contains("test-google-desktop-secret"))
        let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/x?token=abc")!, headers: ["Authorization": "Bearer abc"])
        #expect(!"\(request)".contains("abc"))
    }
}

@Suite("OAuth authorization request and redirect")
struct OAuthRedirectTests {
    private func request(_ config: OAuthClientConfiguration = ConnectorFixtures.google, port: Int = 50123) throws -> OAuthAuthorizationRequest {
        OAuthAuthorizationRequest(
            configuration: config, redirectURI: config.redirectURI(port: port), state: "state-abc",
            pkce: try PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    }

    private func items(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test("Google authorize URL has exactly the expected query items")
    func googleURL() throws {
        let url = try request().url
        #expect(url.host == "accounts.google.com" && url.path == "/o/oauth2/v2/auth")
        #expect(items(url) == [
            "client_id": "test-google-client-id", "response_type": "code",
            "redirect_uri": "http://127.0.0.1:50123/callback",
            "scope": "https://www.googleapis.com/auth/calendar.events.readonly",
            "state": "state-abc", "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256", "access_type": "offline",
        ])
        #expect(!url.absoluteString.contains("secret"))
    }

    @Test("Microsoft authorize URL: scope string, 127.0.0.1 redirect (never localhost), no extras")
    func microsoftURL() throws {
        let url = try request(ConnectorFixtures.microsoft).url
        #expect(url.host == "login.microsoftonline.com" && url.path == "/common/oauth2/v2.0/authorize")
        let query = items(url)
        #expect(query["scope"] == "Calendars.Read offline_access")
        #expect(query["redirect_uri"] == "http://127.0.0.1:50123/callback")
        #expect(query.count == 7 && query["access_type"] == nil)
    }

    @Test("per-attempt parameters (prompt=consent) are added to the authorize URL")
    func additionalParameters() throws {
        let config = ConnectorFixtures.google
        let request = OAuthAuthorizationRequest(
            configuration: config, redirectURI: config.redirectURI(port: 1), additionalParameters: ["prompt": "consent"])
        #expect(items(request.url)["prompt"] == "consent" && items(request.url)["access_type"] == "offline")
    }

    @Test("iss, when present, must be the provider's issuer (RFC 9207)")
    func issuer() throws {
        let google = try request()
        let base = "http://127.0.0.1:50123/callback?state=state-abc&code=c"
        #expect(try google.callback(from: URL(string: base + "&iss=https%3A%2F%2Faccounts.google.com")!).code == "c")
        #expect(try google.callback(from: URL(string: base)!).code == "c")
        for bad in ["https%3A%2F%2Flogin.microsoftonline.com%2Fcommon%2Fv2.0", "https%3A%2F%2Faccounts.google.com.evil", "accounts.google.com"] {
            #expect(throws: OAuthError.issuerMismatch) { try google.callback(from: URL(string: base + "&iss=" + bad)!) }
        }
        #expect(throws: OAuthError.unexpectedRedirect) {
            try google.callback(from: URL(string: base + "&iss=https%3A%2F%2Faccounts.google.com&iss=x")!)
        }
        let microsoft = try request(ConnectorFixtures.microsoft)
        let tenant = "https%3A%2F%2Flogin.microsoftonline.com%2Fexample-tenant-1%2Fv2.0"
        #expect(try microsoft.callback(from: URL(string: base + "&iss=" + tenant)!).code == "c")
        for bad in ["https%3A%2F%2Faccounts.google.com", "https%3A%2F%2Flogin.microsoftonline.com.evil%2Ft%2Fv2.0",
                    "http%3A%2F%2Flogin.microsoftonline.com%2Ft%2Fv2.0", "https%3A%2F%2Flogin.microsoftonline.com%2Fa%2Fb%2Fv2.0"] {
            #expect(throws: OAuthError.issuerMismatch) { try microsoft.callback(from: URL(string: base + "&iss=" + bad)!) }
        }
    }

    @Test("valid redirect yields the code")
    func validRedirect() throws {
        let callback = try request().callback(from: URL(string: "http://127.0.0.1:50123/callback?state=state-abc&code=4/0Ab-x_y&scope=x")!)
        #expect(callback.code == "4/0Ab-x_y")
    }

    @Test("state mismatch, missing state and state-prefix are rejected")
    func stateMismatch() throws {
        let r = try request()
        for query in ["state=state-abX&code=c", "code=c", "state=state-ab&code=c", "state=state-abcd&code=c", "state=&code=c"] {
            #expect(throws: OAuthError.stateMismatch) { try r.callback(from: URL(string: "http://127.0.0.1:50123/callback?\(query)")!) }
        }
    }

    @Test("provider error surfaces only after the state matches")
    func providerError() throws {
        let r = try request()
        #expect(throws: OAuthError.providerError(code: "access_denied", description: "User said no")) {
            try r.callback(from: URL(string: "http://127.0.0.1:50123/callback?state=state-abc&error=access_denied&error_description=User%20said%20no")!)
        }
        #expect(throws: OAuthError.stateMismatch) {
            try r.callback(from: URL(string: "http://127.0.0.1:50123/callback?state=forged&error=access_denied")!)
        }
        // An error together with a code is still an error.
        #expect(throws: OAuthError.providerError(code: "server_error", description: nil)) {
            try r.callback(from: URL(string: "http://127.0.0.1:50123/callback?state=state-abc&error=server_error&code=c")!)
        }
    }

    @Test("missing, empty or unprintable code is rejected")
    func missingCode() throws {
        let r = try request()
        for query in ["state=state-abc", "state=state-abc&code=", "state=state-abc&code=a%0D%0Ab", "state=state-abc&code=a%20b"] {
            #expect(throws: OAuthError.missingCode) { try r.callback(from: URL(string: "http://127.0.0.1:50123/callback?\(query)")!) }
        }
    }

    @Test("duplicate parameters and a redirect to anywhere else are rejected")
    func unexpectedRedirects() throws {
        let r = try request()
        for text in [
            "http://127.0.0.1:50123/callback?state=state-abc&state=state-abc&code=c",
            "http://127.0.0.1:50123/callback?state=state-abc&code=a&code=b",
            "http://127.0.0.1:50124/callback?state=state-abc&code=c",
            "http://127.0.0.1:50123/other?state=state-abc&code=c",
            "http://evil.example:50123/callback?state=state-abc&code=c",
            "https://127.0.0.1:50123/callback?state=state-abc&code=c",
        ] {
            #expect(throws: OAuthError.unexpectedRedirect) { try r.callback(from: URL(string: text)!) }
        }
    }

    @Test("provider error text is sanitized and truncated")
    func sanitizedError() throws {
        let long = String(repeating: "x", count: 500)
        do {
            _ = try request().callback(from: URL(string: "http://127.0.0.1:50123/callback?state=state-abc&error=bad%0Aline&error_description=\(long)")!)
            Issue.record("expected throw")
        } catch let OAuthError.providerError(code, description) {
            #expect(code == "badline")
            #expect(description?.count == 256)
        }
    }
}

@Suite("OAuth token client")
struct OAuthTokenClientTests {
    private let now = ConnectorFixtures.epoch
    private let callback = OAuthCallback(code: "code-1", state: "s")

    @Test("Google exchange sends verifier, redirect and the desktop secret")
    func googleExchange() async throws {
        let transport = RecordingTransport { _ in ConnectorFixtures.tokenJSON(access: "a", refresh: "r", scope: "https://www.googleapis.com/auth/calendar.events.readonly") }
        let client = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: transport)
        let tokens = try await client.exchange(callback, verifier: "v", redirectURI: URL(string: "http://127.0.0.1:1/callback")!, now: now)
        #expect(tokens.accessToken == "a" && tokens.refreshToken == "r")
        #expect(tokens.expiresAt == now.addingTimeInterval(3600))
        let sent = await transport.requests
        #expect(sent.count == 1)
        #expect(sent[0].method == .post && sent[0].url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(sent[0].headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(sent[0].formFields == [
            "grant_type": "authorization_code", "code": "code-1", "code_verifier": "v",
            "redirect_uri": "http://127.0.0.1:1/callback", "client_id": "test-google-client-id",
            "client_secret": "test-google-desktop-secret",
        ])
    }

    @Test("Microsoft exchange never sends a client secret")
    func microsoftExchange() async throws {
        let transport = RecordingTransport { _ in ConnectorFixtures.tokenJSON(refresh: "r", scope: "https://graph.microsoft.com/Calendars.Read") }
        let client = OAuthTokenClient(configuration: ConnectorFixtures.microsoft, transport: transport)
        _ = try await client.exchange(callback, verifier: "v", redirectURI: URL(string: "http://127.0.0.1:1/callback")!, now: now)
        let fields = await transport.requests[0].formFields
        #expect(fields["client_secret"] == nil && fields["code_verifier"] == "v")
        #expect(await transport.requests[0].url.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
    }

    @Test("exchange without a refresh token is an error (nothing that silently expires is stored)")
    func exchangeNeedsRefreshToken() async throws {
        let client = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: RecordingTransport { _ in ConnectorFixtures.tokenJSON(refresh: nil) })
        await #expect(throws: OAuthError.missingRefreshToken) {
            try await client.exchange(callback, verifier: "v", redirectURI: URL(string: "http://127.0.0.1:1/callback")!, now: now)
        }
    }

    @Test("revoke posts the refresh token to Google's revocation endpoint; Microsoft sends nothing")
    func revoke() async throws {
        let google = RecordingTransport { _ in HTTPResponse(statusCode: 200) }
        await OAuthTokenClient(configuration: ConnectorFixtures.google, transport: google).revoke(ConnectorFixtures.tokens(expiresIn: 60))
        let sent = await google.requests
        #expect(sent.count == 1 && sent[0].method == .post)
        #expect(sent[0].url.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(sent[0].formFields == ["token": "refresh-1"])

        let microsoft = RecordingTransport { _ in HTTPResponse(statusCode: 200) }
        await OAuthTokenClient(configuration: ConnectorFixtures.microsoft, transport: microsoft).revoke(ConnectorFixtures.tokens(expiresIn: 60))
        #expect(await microsoft.requests.isEmpty)
    }

    @Test("form encoding escapes reserved and non-ASCII characters")
    func formEncoding() {
        let request = HTTPRequest.form(url: URL(string: "https://x.test")!, fields: ["b": "a b&c=d+é/", "a": "1"])
        #expect(String(data: request.body!, encoding: .utf8) == "a=1&b=a%20b%26c%3Dd%2B%C3%A9%2F")
        #expect(request.formFields == ["a": "1", "b": "a b&c=d+é/"])
    }

    @Test("refresh keeps the old refresh token when the response omits one")
    func refreshKeepsToken() async throws {
        let transport = RecordingTransport { _ in ConnectorFixtures.tokenJSON(access: "new", refresh: nil, expiresIn: "\"1800\"") }
        let client = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: transport)
        let refreshed = try await client.refresh(ConnectorFixtures.tokens(expiresIn: -5), now: now)
        #expect(refreshed.accessToken == "new" && refreshed.refreshToken == "refresh-1")
        #expect(refreshed.expiresAt == now.addingTimeInterval(1800))
        #expect(await transport.requests[0].formFields == [
            "grant_type": "refresh_token", "refresh_token": "refresh-1",
            "client_id": "test-google-client-id", "client_secret": "test-google-desktop-secret",
        ])
    }

    @Test("refresh uses a rotated refresh token when one is returned")
    func refreshRotates() async throws {
        let transport = RecordingTransport { _ in ConnectorFixtures.tokenJSON(access: "new", refresh: "refresh-2") }
        let client = OAuthTokenClient(configuration: ConnectorFixtures.microsoft, transport: transport)
        #expect(try await client.refresh(ConnectorFixtures.tokens(expiresIn: 0), now: now).refreshToken == "refresh-2")
    }

    @Test("refresh without a refresh token needs reauthorization, with no request")
    func noRefreshToken() async throws {
        let transport = RecordingTransport { _ in ConnectorFixtures.tokenJSON() }
        let client = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: transport)
        await #expect(throws: OAuthError.reauthorizationRequired) {
            try await client.refresh(ConnectorFixtures.tokens(refresh: nil, expiresIn: 0), now: now)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("invalid_grant → reauthorization; other errors → tokenEndpoint")
    func errors() async throws {
        let grant = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: RecordingTransport { _ in
            .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400)
        })
        await #expect(throws: OAuthError.reauthorizationRequired) { try await grant.refresh(ConnectorFixtures.tokens(expiresIn: 0), now: now) }
        let other = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: RecordingTransport { _ in
            .json(#"{"error":"invalid_client"}"#, status: 401)
        })
        await #expect(throws: OAuthError.tokenEndpoint(status: 401, error: "invalid_client")) {
            try await other.refresh(ConnectorFixtures.tokens(expiresIn: 0), now: now)
        }
        let html = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: RecordingTransport { _ in
            HTTPResponse(statusCode: 503, body: Data("<html>".utf8))
        })
        await #expect(throws: OAuthError.tokenEndpoint(status: 503, error: nil)) {
            try await html.refresh(ConnectorFixtures.tokens(expiresIn: 0), now: now)
        }
    }

    @Test("malformed 200 responses are rejected", arguments: [
        #"{"token_type":"Bearer"}"#,
        #"not json"#,
        #"{"access_token":""}"#,
        #"{"access_token":"a b"}"#,
        #"{"access_token":"a\r\nX-Injected: 1"}"#,
        #"{"access_token":"a","token_type":"mac"}"#,
        #"{"access_token":"a","refresh_token":"r\n"}"#,
        #"[1,2]"#,
    ])
    func malformed(body: String) async throws {
        let client = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: RecordingTransport { _ in .json(body) })
        await #expect(throws: OAuthError.malformedTokenResponse) {
            try await client.exchange(callback, verifier: "v", redirectURI: URL(string: "http://127.0.0.1:1/callback")!, now: now)
        }
    }

    @Test("oversized token response is rejected")
    func oversized() async throws {
        let padding = String(repeating: "x", count: 70 * 1024)
        let client = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: RecordingTransport { _ in
            .json(#"{"access_token":"a","pad":"\#(padding)"}"#)
        })
        await #expect(throws: OAuthError.malformedTokenResponse) {
            try await client.refresh(ConnectorFixtures.tokens(expiresIn: 0), now: now)
        }
    }

    @Test("expires_in: number, string, missing, zero/negative/tiny (5 min floor), huge, boolean")
    func lifetimes() {
        #expect(OAuthTokenClient.lifetime(NSNumber(value: 1200)) == 1200)
        #expect(OAuthTokenClient.lifetime("900") == 900)
        #expect(OAuthTokenClient.lifetime(nil) == 3600)
        #expect(OAuthTokenClient.lifetime("soon") == 3600)
        #expect(OAuthTokenClient.lifetime(NSNumber(value: -10)) == 300)
        #expect(OAuthTokenClient.lifetime(NSNumber(value: 0)) == 300)
        #expect(OAuthTokenClient.lifetime("30") == 300)
        #expect(OAuthTokenClient.lifetime(NSNumber(value: 1e12)) == 24 * 3600)
        #expect(OAuthTokenClient.lifetime(NSNumber(value: true)) == 3600)
    }

    @Test("exchange fails when the user unticked the calendar scope")
    func scopeNotGranted() async throws {
        let client = OAuthTokenClient(configuration: ConnectorFixtures.google, transport: RecordingTransport { _ in
            ConnectorFixtures.tokenJSON(refresh: "r", scope: "openid email")
        })
        await #expect(throws: OAuthError.scopeNotGranted) {
            try await client.exchange(callback, verifier: "v", redirectURI: URL(string: "http://127.0.0.1:1/callback")!, now: now)
        }
    }

    @Test("needsRefresh uses a 60 s leeway")
    func leeway() {
        let tokens = ConnectorFixtures.tokens(expiresIn: 600)
        #expect(!tokens.needsRefresh(now: ConnectorFixtures.epoch))
        #expect(!tokens.needsRefresh(now: ConnectorFixtures.epoch.addingTimeInterval(539)))
        #expect(tokens.needsRefresh(now: ConnectorFixtures.epoch.addingTimeInterval(541)))
        #expect(tokens.needsRefresh(now: ConnectorFixtures.epoch.addingTimeInterval(700)))
    }
}
