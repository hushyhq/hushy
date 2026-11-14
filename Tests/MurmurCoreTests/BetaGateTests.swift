import Foundation
import Testing
@testable import MurmurCore

@Suite(.serialized) struct BetaGateTests {
    private let session = AccountSession(userID: "person", accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, email: "person@example.com")

    @Test func decisionCoversEveryCheckResult() {
        #expect(BetaGateDecision.resolve(session: nil, approvedUserID: nil, check: .notChecked) == .signIn)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: nil, check: .notChecked) == .couldNotCheck)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: nil, check: .approved) == .open)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: nil, check: .notApproved) == .waiting)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: nil, check: .failed) == .couldNotCheck)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: "person", check: .failed) == .open)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: "other", check: .failed) == .couldNotCheck)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: "person", check: .notApproved) == .waiting)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: nil, check: .sessionRefused) == .signIn)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: "other", check: .sessionRefused) == .signIn)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: "person", check: .sessionRefused) == .open)
        #expect(BetaGateDecision.resolve(session: nil, approvedUserID: "person", check: .notChecked) == .signIn)
    }

    @Test func approvalStoreIsBoundToUserAndCanBeCleared() throws {
        let store = BetaApprovalStore(keys: InMemoryKeyStore())
        try store.save(userID: "person")
        #expect(try store.approvedUserID() == "person")
        try store.clear()
        #expect(try store.approvedUserID() == nil)
    }

    @Test(arguments: [
        ("[{\"approved_at\":\"2026-10-01T00:00:00Z\"}]", BetaGateDecision.open),
        ("[{\"approved_at\":null}]", .waiting),
        ("[]", .waiting),
    ]) func profileResponses(body: String, expected: BetaGateDecision) async {
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data(body.utf8)
        let (checked, result) = await check(session)
        #expect(checked.userID == session.userID)
        #expect(BetaGateDecision.resolve(session: checked, approvedUserID: nil, check: result) == expected)
        #expect(GateURLProtocol.lastProfileRequest?.url?.path == "/rest/v1/site_profiles")
        #expect(GateURLProtocol.lastProfileRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test(arguments: [
        ("[]", 200, #"{"open":true}"#, BetaGateDecision.open),
        (#"[{"approved_at":null}]"#, 200, #"{"open":true}"#, .open),
        ("[]", 200, #"{"open":false}"#, .waiting),
        ("[]", 503, "", .waiting),
        ("[]", 200, "not json", .waiting),
        ("[]", 200, #"{"opened":true}"#, .waiting),
    ]) func openServiceNeedsNoApproval(profile: String, serviceStatus: Int, service: String, expected: BetaGateDecision) async {
        defer { GateURLProtocol.service = nil }
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data(profile.utf8)
        GateURLProtocol.service = (serviceStatus, service)
        let (checked, result) = await check(session)
        #expect(BetaGateDecision.resolve(session: checked, approvedUserID: nil, check: result) == expected)
    }

    @Test func everyCheckRecordsTheServiceAnswerWhoeverIsApproved() async {
        defer { GateURLProtocol.service = nil }
        let store = OpenServiceStore(defaults: freshDefaults())
        for (profile, service, expected) in [
            (#"[{"approved_at":"2026-10-01T00:00:00Z"}]"#, #"{"open":true}"#, true),
            (#"[{"approved_at":"2026-10-01T00:00:00Z"}]"#, #"{"open":false}"#, false),
            ("[]", #"{"open":true}"#, true),
        ] {
            GateURLProtocol.status = 200
            GateURLProtocol.body = Data(profile.utf8)
            GateURLProtocol.service = (200, service)
            _ = await check(session, openService: store)
            #expect(store.last()?.open == expected)
        }
    }

    @Test func aFailedServiceReadKeepsTheLastAnswer() async {
        defer { GateURLProtocol.service = nil }
        let store = OpenServiceStore(defaults: freshDefaults())
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(open: true, now: earlier)
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data(#"[{"approved_at":"2026-10-01T00:00:00Z"}]"#.utf8)
        for failure in [(503, ""), (200, "not json"), (200, #"{"opened":true}"#)] {
            GateURLProtocol.service = failure
            _ = await check(session, openService: store)
            #expect(store.last() == OpenServiceAnswer(open: true, checkedAt: earlier))
        }
    }

    @Test func serviceQuestionCarriesNothingAboutThePerson() async throws {
        defer { GateURLProtocol.service = nil }
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data("[]".utf8)
        GateURLProtocol.service = (200, #"{"open":true}"#)
        GateURLProtocol.lastServiceRequest = nil
        let opened = try await stubClient().serviceIsOpen()
        #expect(opened)
        let request = try #require(GateURLProtocol.lastServiceRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://tryhushy.com/api/service")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "apikey") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 15)
    }

    @Test func serviceDownDoesNotRevokeCachedApproval() async {
        GateURLProtocol.status = 503
        GateURLProtocol.body = Data()
        let (_, result) = await check(session)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: "person", check: result) == .open)
        #expect(BetaGateDecision.resolve(session: session, approvedUserID: nil, check: result) == .couldNotCheck)
    }

    @Test func expiredTokenRefreshesBeforeApprovalRead() async {
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data("[{\"approved_at\":\"2026-10-01T00:00:00Z\"}]".utf8)
        let expired = AccountSession(userID: "person", accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, email: nil)
        let (renewed, result) = await check(expired)
        #expect(renewed.accessToken == "new")
        #expect(BetaGateDecision.resolve(session: renewed, approvedUserID: nil, check: result) == .open)
    }

    @Test(arguments: [400, 422]) func refusedRefreshEndsSession(status: Int) async {
        GateURLProtocol.status = status
        GateURLProtocol.body = Data()
        let expired = AccountSession(userID: "person", accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, email: nil)
        let (checked, result) = await check(expired)
        #expect(checked.userID == expired.userID)
        #expect(result == .sessionRefused)
        #expect(BetaGateDecision.resolve(session: checked, approvedUserID: nil, check: result) == .signIn)
        #expect(BetaGateDecision.resolve(session: checked, approvedUserID: "person", check: result) == .open)
    }

    @Test func rejectedProjectKeyIsNotARefusedSession() async {
        GateURLProtocol.status = 401
        GateURLProtocol.body = Data()
        let expired = AccountSession(userID: "person", accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, email: nil)
        let (_, result) = await check(expired)
        #expect(result == .failed)
        #expect(BetaGateDecision.resolve(session: expired, approvedUserID: "person", check: result) == .open)
    }

    @Test func tokenRefreshAlsoGivesUpAfterFifteenSeconds() async {
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data("[]".utf8)
        GateURLProtocol.lastRefreshRequest = nil
        let expired = AccountSession(userID: "person", accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, email: nil)
        _ = await check(expired)
        #expect(GateURLProtocol.lastRefreshRequest?.timeoutInterval == 15)
    }

    @Test func unreadableOrUnavailableRefreshDoesNotEndSession() async {
        let expired = AccountSession(userID: "person", accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, email: nil)
        defer { GateURLProtocol.refreshBody = nil }
        for (status, body) in [(503, Data()), (200, Data("bad response".utf8))] {
            GateURLProtocol.status = status
            GateURLProtocol.body = body
            GateURLProtocol.refreshBody = body
            let (_, result) = await check(expired)
            #expect(result == .failed)
            #expect(BetaGateDecision.resolve(session: expired, approvedUserID: nil, check: result) == .couldNotCheck)
            #expect(BetaGateDecision.resolve(session: expired, approvedUserID: "person", check: result) == .open)
        }
    }

    @Test func timedOutRefreshDoesNotEndSession() async {
        let expired = AccountSession(userID: "person", accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, email: nil)
        GateURLProtocol.failure = URLError(.timedOut)
        defer { GateURLProtocol.failure = nil }
        let (_, result) = await check(expired)
        #expect(result == .failed)
        #expect(BetaGateDecision.resolve(session: expired, approvedUserID: nil, check: result) == .couldNotCheck)
        #expect(BetaGateDecision.resolve(session: expired, approvedUserID: "person", check: result) == .open)
    }

    @Test func signOutUsesOnlyTokenAndLocalApprovalCanBeForgotten() async throws {
        GateURLProtocol.status = 204
        GateURLProtocol.body = Data()
        try await stubClient().signOut("access")
        #expect(GateURLProtocol.lastRequest?.url?.path == "/auth/v1/logout")
        #expect(GateURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(GateURLProtocol.lastRequest?.httpBody == nil)
        let keys = InMemoryKeyStore()
        let sessions = AccountSessionStore(keys: keys)
        let approvals = BetaApprovalStore(keys: keys)
        try sessions.save(session)
        try approvals.save(userID: session.userID)
        try sessions.clear()
        try approvals.clear()
        #expect(try sessions.load() == nil)
        #expect(try approvals.approvedUserID() == nil)
        #expect(BetaGateDecision.resolve(session: try sessions.load(), approvedUserID: try approvals.approvedUserID(), check: .notChecked) == .signIn)
    }

    /// A private defaults suite, so a check never records into the real defaults.
    private func freshDefaults() -> UserDefaults {
        let name = "app.hushy.tests.betagate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The verifier as the app wires it: tokens come from a keeper over an in-memory Keychain that
    /// holds the session, and refreshes go to the stubbed server.
    private func check(
        _ value: AccountSession, openService: OpenServiceStore? = nil
    ) async -> (AccountSession, BetaApprovalCheck) {
        let client = stubClient()
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try? store.save(value)
        let keeper = AccountSessionKeeper(store: store) { try await client.refresh($0) }
        return await BetaApprovalVerifier(openService: openService ?? OpenServiceStore(defaults: freshDefaults())).check(session: value, client: client, keeper: keeper)
    }

    @Test func unauthorizedProfileReadRefreshesOnceAndRetries() async {
        defer { GateURLProtocol.profileStatuses = [] }
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data("[{\"approved_at\":\"2026-10-01T00:00:00Z\"}]".utf8)
        GateURLProtocol.profileStatuses = [401]
        let (checked, result) = await check(session)
        #expect(result == .approved)
        #expect(checked.accessToken == "new")
        #expect(GateURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test func secondUnauthorizedAnswerIsNotAnEndlessLoop() async {
        defer { GateURLProtocol.profileStatuses = [] }
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data()
        GateURLProtocol.profileStatuses = [401, 401, 401]
        let (_, result) = await check(session)
        #expect(result == .failed)
    }

    @Test func approvalReadGivesUpAfterFifteenSeconds() async {
        GateURLProtocol.status = 200
        GateURLProtocol.body = Data("[]".utf8)
        _ = await check(session)
        #expect(GateURLProtocol.lastRequest?.timeoutInterval == 15)
    }

    private func stubClient() -> AccountClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GateURLProtocol.self]
        return AccountClient(configuration: AccountConfiguration(url: URL(string: "https://example.supabase.co")!, anonKey: "public"), transport: URLSession(configuration: config))
    }
}

private final class GateURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var refreshBody: Data?
    nonisolated(unsafe) static var failure: URLError?
    nonisolated(unsafe) static var profileStatuses: [Int] = []
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastProfileRequest: URLRequest?
    nonisolated(unsafe) static var lastServiceRequest: URLRequest?
    /// The website's public "is the service open" answer. `nil` falls through to `status` and `body`.
    nonisolated(unsafe) static var service: (Int, String)?
    nonisolated(unsafe) static var lastRefreshRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if request.url?.path == "/auth/v1/token" { Self.lastRefreshRequest = request }
        if request.url?.path == "/rest/v1/site_profiles" { Self.lastProfileRequest = request }
        if request.url?.path == "/api/service" { Self.lastServiceRequest = request }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        var data: Data
        if request.url?.path == "/auth/v1/token" {
            data = Self.refreshBody ?? Data("{\"access_token\":\"new\",\"refresh_token\":\"renewed\",\"expires_in\":3600,\"user\":{\"id\":\"person\"}}".utf8)
        } else { data = Self.body }
        var status = Self.status
        if request.url?.path == "/api/service", let service = Self.service { status = service.0; data = Data(service.1.utf8) }
        if request.url?.path == "/rest/v1/site_profiles", !Self.profileStatuses.isEmpty { status = Self.profileStatuses.removeFirst() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
