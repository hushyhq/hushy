import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// A signed-in, approved person's own invite code is fetched and redeemed without pasting.
/// Fakes only: a throwaway key pair made here, a private defaults suite, a fake code source.
@Suite("Beta invite applier", .serialized, .timeLimit(.minutes(1)))
struct BetaInviteApplierTests {
    let signer = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = AccountSession(userID: "person", accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, email: "person@example.com")

    private func freshDefaults() -> UserDefaults {
        let name = "app.hushy.tests.betainvite.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func code() throws -> String {
        try InviteCode.generate(InviteCode.Payload(grantDays: InviteCode.defaultGrantDays, issuedAt: now), privateKey: signer)
    }

    private func applier(_ defaults: UserDefaults) -> BetaInviteApplier {
        let key = signer.publicKey
        let moment = now
        let box = DefaultsBox(defaults)
        return BetaInviteApplier(redeem: { InviteRedeemer.redeem($0, publicKey: key, now: moment, defaults: box.value) })
    }

    @Test("a fetched code is redeemed and Pro is active")
    func fetchThenRedeem() async throws {
        let defaults = freshDefaults()
        let source = FakeCodeSource(.code(try code()))
        let outcome = await applier(defaults).apply(session: session, source: source)
        let until = now.addingTimeInterval(TimeInterval(InviteCode.defaultGrantDays) * 86_400)
        #expect(outcome == .applied(until: until))
        #expect(InviteRedemptionStore.activeExpiry(now: now, defaults: defaults) == until)
        #expect(await source.requests == [.init(accessToken: "access", userID: "person")])
    }

    @Test("a code already redeemed here changes nothing and says so quietly")
    func alreadyRedeemed() async throws {
        let defaults = freshDefaults()
        let text = try code()
        _ = InviteRedeemer.redeem(text, publicKey: signer.publicKey, now: now, defaults: defaults)
        let before = InviteRedemptionStore.current(defaults: defaults)
        let outcome = await applier(defaults).apply(session: session, source: FakeCodeSource(.code(text)))
        #expect(outcome == .alreadyApplied)
        #expect(InviteRedemptionStore.current(defaults: defaults) == before)
    }

    @Test("applying twice in a row is a no-op the second time")
    func twice() async throws {
        let defaults = freshDefaults()
        let source = FakeCodeSource(.code(try code()))
        _ = await applier(defaults).apply(session: session, source: source)
        let first = InviteRedemptionStore.current(defaults: defaults)
        let second = await applier(defaults).apply(session: session, source: source)
        #expect(second == .alreadyApplied)
        #expect(InviteRedemptionStore.current(defaults: defaults) == first)
    }

    @Test("no code yet means nothing happens")
    func noCode() async {
        let defaults = freshDefaults()
        for answer in [FakeCodeSource.Answer.none, .code(""), .code("   ")] {
            let outcome = await applier(defaults).apply(session: session, source: FakeCodeSource(answer))
            #expect(outcome == .noCode)
        }
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil)
    }

    @Test("a failed fetch changes nothing and never throws")
    func fetchFails() async {
        let defaults = freshDefaults()
        for (failure, reason) in [(AccountError.httpStatus(503), BetaInviteFailure.server), (.httpStatus(401), .unauthorized), (.requestFailed, .response)] {
            let outcome = await applier(defaults).apply(session: session, source: FakeCodeSource(.failure(failure)))
            #expect(outcome == .unavailable(reason: reason))
        }
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil)
    }

    @Test("a transient read failure can be followed by a successful application")
    func retryAfterFailure() async throws {
        let defaults = freshDefaults()
        let worker = applier(defaults)
        #expect(await worker.apply(session: session, source: FakeCodeSource(.failure(.httpStatus(503)))) == .unavailable(reason: .server))
        #expect(await worker.apply(session: session, source: FakeCodeSource(.code(try code()))) != .noCode)
        #expect(InviteRedemptionStore.activeExpiry(now: now, defaults: defaults) != nil)
    }

    @Test("signed out: no request is made")
    func signedOut() async throws {
        let defaults = freshDefaults()
        let source = FakeCodeSource(.code(try code()))
        let outcome = await applier(defaults).apply(session: nil, source: source)
        #expect(outcome == .signedOut)
        #expect(await source.requests.isEmpty)
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil)
    }

    @Test("a code that does not verify stores nothing")
    func rejected() async {
        let defaults = freshDefaults()
        let outcome = await applier(defaults).apply(session: session, source: FakeCodeSource(.code("HUSHY-NOPE")))
        #expect(outcome == .rejected)
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil)
    }

    @Test("if the account changed while fetching, the code is dropped unredeemed")
    func superseded() async throws {
        let defaults = freshDefaults()
        let outcome = await applier(defaults).apply(
            session: session, source: FakeCodeSource(.code(try code())), stillCurrent: { false })
        #expect(outcome == .superseded)
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil)
    }

    @Test("a longer grant already held is kept, quietly")
    func keptLonger() async throws {
        let defaults = freshDefaults()
        InviteRedemptionStore.save(InviteRedemption(codeID: "ffffffffffffffff", redeemedAt: now, grantDays: 3_650), defaults: defaults)
        let outcome = await applier(defaults).apply(session: session, source: FakeCodeSource(.code(try code())))
        #expect(outcome == .alreadyApplied)
    }

    @Test("the outcome carries no code text")
    func outcomeNeverCarriesTheCode() async throws {
        let text = try code()
        let outcome = await applier(freshDefaults()).apply(session: session, source: FakeCodeSource(.code(text)))
        #expect(!String(describing: outcome).contains(text))
        #expect(!String(reflecting: outcome).contains(text))
    }
}

/// The real client's one read, against a stubbed transport.
@Suite("Account client invite code read", .serialized, .timeLimit(.minutes(1)))
struct AccountInviteCodeReadTests {
    private func client() -> AccountClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InviteReadURLProtocol.self]
        return AccountClient(configuration: AccountConfiguration(url: URL(string: "https://example.supabase.co")!, anonKey: "public"), transport: URLSession(configuration: config))
    }

    @Test("asks for the signed-in person's own row and returns the code")
    func readsOwnRow() async throws {
        InviteReadURLProtocol.status = 200
        InviteReadURLProtocol.body = Data(#"[{"invite_code":"HUSHY-TEST"}]"#.utf8)
        let value = try await client().inviteCode(accessToken: "access", userID: "person")
        #expect(value == "HUSHY-TEST")
        let request = InviteReadURLProtocol.lastRequest
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.path == "/rest/v1/site_profiles")
        let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "user_id" })?.value == "eq.person")
        #expect(items.first(where: { $0.name == "select" })?.value == "invite_code")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request?.value(forHTTPHeaderField: "apikey") == "public")
    }

    @Test(arguments: ["[]", #"[{"invite_code":null}]"#, #"[{"invite_code":""}]"#])
    func missingCodeIsNil(body: String) async throws {
        InviteReadURLProtocol.status = 200
        InviteReadURLProtocol.body = Data(body.utf8)
        #expect(try await client().inviteCode(accessToken: "access", userID: "person") == nil)
    }

    @Test("an error status throws instead of looking like no code")
    func errorStatusThrows() async {
        InviteReadURLProtocol.status = 503
        InviteReadURLProtocol.body = Data()
        await #expect(throws: AccountError.self) { try await client().inviteCode(accessToken: "access", userID: "person") }
    }
}

@Suite("Web account destination")
struct WebAccountDestinationTests {
    @Test("the plan link has no account identifier or token")
    func accountURL() {
        let config = AccountConfiguration(url: URL(string: "https://example.invalid")!, anonKey: "fixture",
                                          siteURL: URL(string: "https://plans.example.invalid")!)
        #expect(config.accountURL.absoluteString == "https://plans.example.invalid/account")
        #expect(config.accountURL.query == nil)
    }
}

/// UserDefaults is thread-safe but not marked Sendable in this SDK; the suite is serialized.
private struct DefaultsBox: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}

private actor FakeCodeSource: InviteCodeSource {
    enum Answer { case code(String), none, failure(AccountError) }
    struct Request: Equatable { let accessToken: String; let userID: String }
    private let answer: Answer
    private(set) var requests: [Request] = []
    init(_ answer: Answer) { self.answer = answer }
    func inviteCode(accessToken: String, userID: String) async throws -> String? {
        requests.append(Request(accessToken: accessToken, userID: userID))
        switch answer {
        case .code(let text): return text
        case .none: return nil
        case .failure(let error): throw error
        }
    }
}

private final class InviteReadURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
