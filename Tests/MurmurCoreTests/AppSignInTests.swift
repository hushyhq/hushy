import Foundation
import Testing
@testable import MurmurCore

/// Signing in through the website: the app's secret, the page address, the app's own return
/// address, and the claim that trades the handoff id and the secret for the session.
@Suite("Browser sign-in", .serialized) struct AppSignInTests {
    // RFC 7636's example pair. The Worker's tests use the same two values, so the app and the
    // site are held to one definition of "challenge".
    private let secret = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    private let id = "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_"

    private func client(_ transport: URLSession = .shared) -> AccountClient {
        AccountClient(configuration: AccountConfiguration(url: URL(string: "https://example.supabase.co")!, anonKey: "public"), transport: transport)
    }

    // MARK: the secret and its challenge

    @Test func challengeIsTheUnpaddedBase64URLSHA256OfTheSecretText() throws {
        let pair = try PKCEChallenge(verifier: secret)
        #expect(pair.challenge == challenge)
    }

    @Test func aGeneratedSecretIs32BytesAsBase64URLAndNeverRepeats() {
        let first = PKCEChallenge.generate(), second = PKCEChallenge.generate()
        #expect(first.verifier.count == 43)
        #expect(first.challenge.count == 43)
        #expect(first.verifier != second.verifier)
        #expect(AppSignInShape.isValue(first.verifier))
        #expect(AppSignInShape.isValue(first.challenge))
    }

    @Test func aSecretIsNeverPrintedByAccident() {
        let pair = PKCEChallenge.generate()
        #expect(!"\(pair)".contains(pair.verifier))
        #expect(!String(reflecting: pair).contains(pair.verifier))
    }

    // MARK: the page address

    @Test func theSignInAddressIsTheSitesLoginPageWithOnlyTheChallenge() throws {
        let url = try #require(client().appSignInURL(challenge: challenge))
        #expect(url.absoluteString == "https://tryhushy.com/login?app=\(challenge)")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.count == 1)
        #expect(!url.absoluteString.contains(secret))
    }

    @Test(arguments: ["", "short", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cMA", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-c=", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw+cM", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-c&"])
    func aChallengeOfTheWrongShapeMakesNoAddress(bad: String) {
        #expect(client().appSignInURL(challenge: bad) == nil)
    }

    // MARK: the app's own return address

    @Test func theCallbackAcceptsOnlyItsOwnSchemeHostAndAWellFormedId() {
        #expect(AppSignInCallback.id(from: URL(string: "hushy://sign-in?id=\(id)")!) == id)
        #expect(AppSignInCallback.id(from: URL(string: "HUSHY://Sign-In?id=\(id)")!) == id)
        #expect(AppSignInCallback.id(from: URL(string: "hushy://sign-in/?id=\(id)")!) == id)
    }

    @Test(arguments: [
        "https://sign-in?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_",
        "hushy://auth-callback?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_",
        "hushy://note/7",
        "hushy://sign-in",
        "hushy://sign-in?id=",
        "hushy://sign-in?id=short",
        "hushy://sign-in?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_A",
        "hushy://sign-in?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U%2F_",
        "hushy://sign-in?code=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_",
        "hushy://sign-in?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_&id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_",
        "hushy://sign-in?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_&token=x",
        "hushy://evil.example/sign-in?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_",
        "hushy://sign-in/extra?id=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_",
    ])
    func anythingElseIsNotACallback(address: String) throws {
        #expect(AppSignInCallback.id(from: try #require(URL(string: address))) == nil)
    }

    // MARK: the claim

    @Test func theClaimRequestCarriesOnlyTheIdAndTheSecretAndWaitsFifteenSeconds() throws {
        let request = try client().claimRequest(id: id, secret: secret)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://tryhushy.com/api/app-signin/claim")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(AccountClient.claimTimeout == 15)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        // The site sees no project key and no Origin: it takes this request from the app only.
        #expect(request.value(forHTTPHeaderField: "apikey") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["id": id, "secret": secret])
    }

    @Test func aClaimThatIsNotShapedRightIsNeverSent() {
        #expect(throws: AccountError.self) { try client().claimRequest(id: "short", secret: secret) }
        #expect(throws: AccountError.self) { try client().claimRequest(id: id, secret: "short") }
    }

    @Test func aGoodClaimAnswerBecomesASession() async throws {
        ClaimStub.reset()
        ClaimStub.answer = (200, #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3595,"user":{"id":"person","email":"person@example.com"}}"#)
        let before = Date()
        let session = try await client(ClaimStub.session()).claimSignIn(id: id, secret: secret)
        #expect(session.userID == "person")
        #expect(session.email == "person@example.com")
        #expect(session.accessToken == "access-1")
        #expect(session.refreshToken == "refresh-1")
        #expect(abs(session.expiresAt.timeIntervalSince(before.addingTimeInterval(3595))) < 5)
        #expect(ClaimStub.lastRequest?.url?.path == "/api/app-signin/claim")
    }

    @Test func signingOutAKeptOrDiscardedBrowserSessionEndsOnlyThatSession() async throws {
        ClaimStub.reset()
        ClaimStub.answer = (204, "")
        try await client(ClaimStub.session()).signOutThisSession("access-1")
        let request = try #require(ClaimStub.lastRequest)
        #expect(request.url?.path == "/auth/v1/logout")
        #expect(request.url?.query == "scope=local")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test(arguments: [404, 429, 500, 200]) func aRefusedOrBrokenClaimThrowsAndSaysNothingMore(status: Int) async {
        ClaimStub.reset()
        ClaimStub.answer = (status, status == 200 ? "not json" : #"{"error":"Not available"}"#)
        await #expect(throws: (any Error).self) { try await client(ClaimStub.session()).claimSignIn(id: id, secret: secret) }
    }
}

private final class ClaimStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: (Int, String) = (404, "")
    nonisolated(unsafe) static var lastRequest: URLRequest?
    static func reset() { answer = (404, ""); lastRequest = nil }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaimStub.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.answer.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
