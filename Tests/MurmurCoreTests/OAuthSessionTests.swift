import Foundation
import Testing
@testable import MurmurCore

@Suite("OAuth token store")
struct OAuthTokenStoreTests {
    private let google = CalendarAccountID(provider: .google, id: "g1")
    private let outlook = CalendarAccountID(provider: .microsoft, id: "m1")

    @Test("round trip through InMemoryKeyStore under connector.{provider}.{id}")
    func roundTrip() throws {
        let keys = InMemoryKeyStore()
        let store = OAuthTokenStore(keyStore: keys)
        let tokens = ConnectorFixtures.tokens(expiresIn: 3600)
        try store.save(tokens, for: google)
        #expect(try store.load(google) == tokens)
        #expect(try keys.read(account: "connector.google.g1") != nil)
        #expect(try store.load(outlook) == nil)
    }

    @Test("index add/remove, no duplicates")
    func index() throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        try store.save(ConnectorFixtures.tokens(expiresIn: 1), for: google)
        try store.save(ConnectorFixtures.tokens(expiresIn: 2), for: google)
        try store.save(ConnectorFixtures.tokens(expiresIn: 3), for: outlook)
        #expect(try store.accounts() == [google, outlook])
        try store.delete(google)
        #expect(try store.accounts() == [outlook])
        #expect(try store.load(google) == nil)
        try store.delete(outlook)
        #expect(try store.accounts().isEmpty)
    }

    @Test("deleting a missing account is not an error")
    func deleteMissing() throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        try store.delete(google)
        try store.removeTokens(for: google)
        #expect(try store.accounts().isEmpty)
    }

    @Test("removeTokens keeps the account listed (for Reconnect)")
    func removeTokensKeepsIndex() throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        try store.save(ConnectorFixtures.tokens(expiresIn: 1), for: google)
        try store.removeTokens(for: google)
        #expect(try store.load(google) == nil)
        #expect(try store.accounts() == [google])
    }

    @Test("corrupt stored data reads as no tokens")
    func corrupt() throws {
        let keys = InMemoryKeyStore()
        try keys.write(Data("garbage".utf8), account: "connector.google.g1")
        try keys.write(Data("garbage".utf8), account: "connector.accounts")
        let store = OAuthTokenStore(keyStore: keys)
        #expect(try store.load(google) == nil)
        #expect(try store.accounts().isEmpty)
    }
}

@Suite("OAuth session")
struct OAuthSessionTests {
    private func setup(expiresIn: TimeInterval?, response: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse = { _ in ConnectorFixtures.tokenJSON(access: "access-2") })
        throws -> (OAuthSession, RecordingTransport, OAuthTokenStore, TestClock)
    {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let clock = TestClock()
        let transport = RecordingTransport(response)
        let session = ConnectorFixtures.session(transport: transport, store: store, clock: clock)
        if let expiresIn {
            try store.save(ConnectorFixtures.tokens(expiresIn: expiresIn), for: session.account)
        }
        return (session, transport, store, clock)
    }

    @Test("no refresh when 10 minutes remain")
    func noRefresh() async throws {
        let (session, transport, _, _) = try setup(expiresIn: 600)
        #expect(try await session.validAccessToken() == "access-1")
        #expect(await transport.requests.isEmpty)
        #expect(await session.refreshCount == 0)
    }

    @Test("refresh at 59 s remaining, persisted")
    func refreshNearExpiry() async throws {
        let (session, transport, store, clock) = try setup(expiresIn: 600)
        clock.advance(541)
        #expect(try await session.validAccessToken() == "access-2")
        #expect(await session.refreshCount == 1)
        #expect(await transport.requests.count == 1)
        let stored = try store.load(session.account)
        #expect(stored?.accessToken == "access-2")
        #expect(stored?.refreshToken == "refresh-1")
        #expect(stored?.expiresAt == clock.now.addingTimeInterval(3600))
        // The persisted token is used next time without another refresh.
        #expect(try await session.validAccessToken() == "access-2")
        #expect(await transport.requests.count == 1)
    }

    @Test("concurrent callers share one refresh")
    func singleFlight() async throws {
        let (session, transport, _, _) = try setup(expiresIn: -10)
        async let a = session.validAccessToken()
        async let b = session.validAccessToken()
        async let c = session.validAccessToken()
        let tokens = try await [a, b, c]
        #expect(tokens == ["access-2", "access-2", "access-2"])
        #expect(await transport.requests.count == 1)
    }

    @Test("no tokens → reauthorization")
    func noTokens() async throws {
        let (session, _, _, _) = try setup(expiresIn: nil)
        await #expect(throws: OAuthError.reauthorizationRequired) { try await session.validAccessToken() }
        #expect(await !session.hasTokens())
    }

    @Test("invalid_grant deletes the tokens and marks needs-reauth, keeping the account listed")
    func invalidGrant() async throws {
        let (session, _, store, _) = try setup(expiresIn: 10) { _ in .json(#"{"error":"invalid_grant"}"#, status: 400) }
        await #expect(throws: OAuthError.reauthorizationRequired) { try await session.validAccessToken() }
        #expect(try store.load(session.account) == nil)
        #expect(try store.accounts() == [session.account])
        #expect(await session.needsReauthorization)
    }

    @Test("a transient refresh failure keeps the tokens")
    func transientFailure() async throws {
        let (session, _, store, _) = try setup(expiresIn: 10) { _ in HTTPResponse(statusCode: 503) }
        await #expect(throws: OAuthError.tokenEndpoint(status: 503, error: nil)) { try await session.validAccessToken() }
        #expect(try store.load(session.account) != nil)
        #expect(await !session.needsReauthorization)
    }

    @Test("Google disconnect: deletes locally and revokes the refresh token (best effort)")
    func disconnectRevokesGoogle() async throws {
        let (session, transport, store, _) = try setup(expiresIn: 600) { _ in HTTPResponse(statusCode: 503) }
        try await session.disconnect()
        #expect(try store.accounts().isEmpty && store.load(session.account) == nil)  // even though revoke failed
        let sent = await transport.requests
        #expect(sent.count == 1 && sent[0].url.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(sent[0].formFields == ["token": "refresh-1"])
    }

    @Test("Microsoft disconnect is local-only")
    func disconnectMicrosoftLocalOnly() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = RecordingTransport { _ in HTTPResponse(statusCode: 200) }
        let session = ConnectorFixtures.session(ConnectorFixtures.microsoft, transport: transport, store: store)
        try store.save(ConnectorFixtures.tokens(expiresIn: 600), for: session.account)
        try await session.disconnect()
        #expect(try store.accounts().isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test("a waiter joined to an in-flight refresh gets no token once disconnect happened")
    func joinerRechecksGeneration() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = GatedTransport()
        let gated = OAuthSession(
            account: CalendarAccountID(provider: .google, id: "acct-1"), client: OAuthTokenClient(configuration: ConnectorFixtures.google, transport: transport),
            store: store, clock: { ConnectorFixtures.epoch })
        try store.save(ConnectorFixtures.tokens(expiresIn: -10), for: gated.account)
        let first = Task { try await gated.validAccessToken() }
        await transport.waitUntilGated()
        let joiner = Task { try await gated.validAccessToken() }
        try await Task.sleep(for: .milliseconds(20))
        try await gated.disconnect()
        await transport.release()
        await #expect(throws: OAuthError.reauthorizationRequired) { try await first.value }
        await #expect(throws: OAuthError.reauthorizationRequired) { try await joiner.value }
        #expect(try store.load(gated.account) == nil && store.accounts().isEmpty)
    }

    @Test("complete() supersedes an in-flight refresh: the stale refresh result is never stored")
    func completeSupersedesRefresh() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = GatedTransport()
        let session = OAuthSession(
            account: CalendarAccountID(provider: .google, id: "acct-1"),
            client: OAuthTokenClient(configuration: ConnectorFixtures.google, transport: transport),
            store: store, clock: { ConnectorFixtures.epoch })
        try store.save(ConnectorFixtures.tokens(expiresIn: -10), for: session.account)
        let refresh = Task { try await session.validAccessToken() }
        await transport.waitUntilGated()
        let request = OAuthAuthorizationRequest(configuration: ConnectorFixtures.google, redirectURI: ConnectorFixtures.google.redirectURI(port: 1))
        try await session.complete(OAuthCallback(code: "c", state: request.state), request: request)
        await transport.release()
        await #expect(throws: OAuthError.reauthorizationRequired) { try await refresh.value }
        #expect(try store.load(session.account)?.accessToken == "from-exchange")
        #expect(await !session.needsReauthorization)
    }

    @Test("disconnect removes the account from accounts()")
    func disconnect() async throws {
        let (session, _, store, _) = try setup(expiresIn: 600)
        #expect(try store.accounts() == [session.account])
        try await session.disconnect()
        #expect(try store.accounts().isEmpty)
        #expect(try store.load(session.account) == nil)
        await #expect(throws: OAuthError.reauthorizationRequired) { try await session.validAccessToken() }
    }

    @Test("complete exchanges the code and stores tokens; wrong-provider request is refused")
    func complete() async throws {
        let (session, transport, store, _) = try setup(expiresIn: nil) { _ in
            ConnectorFixtures.tokenJSON(access: "fresh", refresh: "r", scope: "https://www.googleapis.com/auth/calendar.events.readonly")
        }
        let request = OAuthAuthorizationRequest(configuration: ConnectorFixtures.google, redirectURI: ConnectorFixtures.google.redirectURI(port: 4000))
        try await session.complete(OAuthCallback(code: "c", state: request.state), request: request)
        #expect(try store.load(session.account)?.accessToken == "fresh")
        #expect(await transport.requests[0].formFields["code_verifier"] == request.pkce.verifier)

        let foreign = OAuthAuthorizationRequest(configuration: ConnectorFixtures.microsoft, redirectURI: ConnectorFixtures.microsoft.redirectURI(port: 4000))
        await #expect(throws: OAuthError.unexpectedRedirect) {
            try await session.complete(OAuthCallback(code: "c", state: foreign.state), request: foreign)
        }
    }

    @Test("connect flow asks Google for consent only when no refresh token is held")
    func promptConsent() async throws {
        let prompts = PromptBox()
        let authorizer = FakeAuthorizer(port: 4555) { request in
            prompts.record(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prompt" }?.value)
            return URL(string: "http://127.0.0.1:4555/callback?code=abc&state=\(request.state)")!
        }
        let (session, _, store, _) = try setup(expiresIn: nil) { _ in
            ConnectorFixtures.tokenJSON(access: "fresh", refresh: "r", scope: "https://www.googleapis.com/auth/calendar.events.readonly")
        }
        try await OAuthConnectFlow.connect(session: session, authorizer: authorizer)
        try store.save(ConnectorFixtures.tokens(expiresIn: 60), for: session.account)
        try await OAuthConnectFlow.connect(session: session, authorizer: authorizer)
        #expect(prompts.values == ["consent", nil])

        let msStore = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let ms = ConnectorFixtures.session(ConnectorFixtures.microsoft, transport: RecordingTransport { _ in ConnectorFixtures.tokenJSON(refresh: "r") }, store: msStore)
        try await OAuthConnectFlow.connect(session: ms, authorizer: authorizer)
        #expect(prompts.values == ["consent", nil, nil])
    }

    @Test("connect flow: redirect validated, code exchanged, tokens stored")
    func connectFlow() async throws {
        let (session, _, store, _) = try setup(expiresIn: nil) { _ in
            ConnectorFixtures.tokenJSON(access: "fresh", refresh: "r", scope: "https://www.googleapis.com/auth/calendar.events.readonly")
        }
        try await OAuthConnectFlow.connect(session: session, authorizer: FakeAuthorizer(port: 4555) { request in
            URL(string: "http://127.0.0.1:4555/callback?code=abc&state=\(request.state)")!
        })
        #expect(try store.load(session.account)?.refreshToken == "r")

        let (other, otherTransport, otherStore, _) = try setup(expiresIn: nil)
        await #expect(throws: OAuthError.stateMismatch) {
            try await OAuthConnectFlow.connect(session: other, authorizer: FakeAuthorizer(port: 4555) { _ in
                URL(string: "http://127.0.0.1:4555/callback?code=abc&state=attacker")!
            })
        }
        #expect(await otherTransport.requests.isEmpty)
        #expect(try otherStore.accounts().isEmpty)
    }
}

struct FakeAuthorizer: OAuthAuthorizing {
    let redirectPort: Int
    let respond: @Sendable (OAuthAuthorizationRequest) -> URL

    init(port: Int, respond: @escaping @Sendable (OAuthAuthorizationRequest) -> URL) {
        self.redirectPort = port
        self.respond = respond
    }

    func authorize(_ request: OAuthAuthorizationRequest) async throws -> URL {
        #expect(request.redirectURI.port == redirectPort)
        return respond(request)
    }
}

@Suite("OAuth session registry")
struct OAuthSessionRegistryTests {
    @Test("one session per account; unconfigured providers get none; disconnect forgets and revokes")
    func registry() async throws {
        let store = OAuthTokenStore(keyStore: InMemoryKeyStore())
        let transport = RecordingTransport { _ in HTTPResponse(statusCode: 200) }
        let registry = OAuthSessionRegistry(configuration: ConnectorFixtures.configuration, store: store, transport: transport)
        let google = CalendarAccountID(provider: .google, id: "g")
        let a = try #require(await registry.session(for: google))
        let b = try #require(await registry.session(for: google))
        #expect(a === b)
        let other = try #require(await registry.session(for: CalendarAccountID(provider: .google, id: "g2")))
        #expect(other !== a)

        let bare = OAuthSessionRegistry(configuration: CalendarConnectorConfiguration(infoDictionary: nil), store: store, transport: transport)
        #expect(await bare.session(for: google) == nil)

        try store.save(ConnectorFixtures.tokens(expiresIn: 600), for: google)
        try await registry.disconnect(google)
        #expect(try store.accounts().isEmpty)
        #expect(await transport.requests.map(\.url.absoluteString) == ["https://oauth2.googleapis.com/revoke"])
        let fresh = try #require(await registry.session(for: google))
        #expect(fresh !== a)
    }
}

/// Holds refresh-token requests until `release()`, so tests can interleave disconnect/complete
/// with a refresh that is in flight. Code exchanges and revocations answer immediately.
actor GatedTransport: HTTPTransport {
    private var gate: CheckedContinuation<Void, Never>?
    private var gatedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isGated = false

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.formFields["grant_type"] {
        case "refresh_token":
            await withCheckedContinuation { continuation in
                gate = continuation
                isGated = true
                gatedWaiters.forEach { $0.resume() }
                gatedWaiters = []
            }
            return ConnectorFixtures.tokenJSON(access: "from-refresh")
        case "authorization_code":
            return ConnectorFixtures.tokenJSON(access: "from-exchange", refresh: "r2", scope: "https://www.googleapis.com/auth/calendar.events.readonly")
        default:
            return HTTPResponse(statusCode: 200)
        }
    }

    func waitUntilGated() async {
        if isGated { return }
        await withCheckedContinuation { gatedWaiters.append($0) }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []

    func record(_ value: String?) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite("Key store migration (legacy login keychain → data-protection keychain)")
struct MigratingKeyStoreTests {
    @Test("existing legacy items stay readable and are moved to the primary store")
    func migratesOnRead() throws {
        let primary = InMemoryKeyStore(), legacy = InMemoryKeyStore()
        try legacy.write(Data("old-key".utf8), account: "master")
        let store = MigratingKeyStore(primary: primary, legacy: legacy)
        #expect(try store.read(account: "master") == Data("old-key".utf8))
        #expect(try primary.read(account: "master") == Data("old-key".utf8))
        #expect(try legacy.read(account: "master") == nil)
        #expect(try store.read(account: "master") == Data("old-key".utf8))
        #expect(try store.read(account: "missing") == nil)
    }

    @Test("primary wins; writes clear the legacy copy; deletes clear both")
    func writesAndDeletes() throws {
        let primary = InMemoryKeyStore(), legacy = InMemoryKeyStore()
        let store = MigratingKeyStore(primary: primary, legacy: legacy)
        try primary.write(Data("new".utf8), account: "a")
        try legacy.write(Data("stale".utf8), account: "a")
        #expect(try store.read(account: "a") == Data("new".utf8))
        try store.write(Data("newer".utf8), account: "a")
        #expect(try legacy.read(account: "a") == nil && primary.read(account: "a") == Data("newer".utf8))
        try legacy.write(Data("x".utf8), account: "b")
        try store.delete(account: "b")
        #expect(try legacy.read(account: "b") == nil)
    }

    @Test("if the copy into the primary store fails, the legacy item is kept and still returned")
    func failedCopyKeepsLegacy() throws {
        let legacy = InMemoryKeyStore()
        try legacy.write(Data("old".utf8), account: "k")
        let store = MigratingKeyStore(primary: ReadOnlyStore(), legacy: legacy)
        #expect(try store.read(account: "k") == Data("old".utf8))
        #expect(try legacy.read(account: "k") == Data("old".utf8))
    }
}

private struct ReadOnlyStore: KeyStoreProtocol {
    struct Refused: Error {}
    func read(account: String) throws -> Data? { nil }
    func write(_ data: Data, account: String) throws { throw Refused() }
    func delete(account: String) throws {}
}
