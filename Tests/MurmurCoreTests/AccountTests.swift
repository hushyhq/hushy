import Foundation
import Testing
@testable import MurmurCore

struct AccountTests {
    @Test func offlineGraceAndMerge() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cached = AccountEntitlement(userID: "user-a", isPro: true, validUntil: now.addingTimeInterval(-3600), verifiedAt: now.addingTimeInterval(-7200))
        #expect(cached.activeUntil(now: now) != nil)
        #expect(cached.activeUntil(now: now.addingTimeInterval(8 * 86400)) == nil)
        let free = AccountEntitlement(userID: "user-a", isPro: false, validUntil: now.addingTimeInterval(86400), verifiedAt: now)
        #expect(free.activeUntil(now: now) == nil)
    }

    @Test func cacheIsBoundToSignedInAccountAndFreeReplacesPro() throws {
        let keys = InMemoryKeyStore()
        let store = AccountEntitlementStore(keys: keys)
        let now = Date()
        try store.save(AccountEntitlement(userID: "user-a", isPro: true, validUntil: now.addingTimeInterval(3600), verifiedAt: now))
        #expect(try store.load(for: "user-b") == nil)
        #expect(try store.load(for: "user-a") == nil)
        try store.save(AccountEntitlement(userID: "user-a", isPro: true, validUntil: now.addingTimeInterval(3600), verifiedAt: now))
        try store.save(AccountEntitlement(userID: "user-a", isPro: false, validUntil: nil, verifiedAt: now))
        #expect(try store.load(for: "user-a")?.activeUntil(now: now) == nil)
    }

    @Test func entitlementDecodesPostgRESTDates() async throws {
        let configuration = AccountConfiguration(url: URL(string: "https://example.supabase.co")!, anonKey: "public")
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [EntitlementURLProtocol.self]; return c }())
        let client = AccountClient(configuration: configuration, transport: session)
        for stamp in ["2026-09-28T12:34:56Z", "2026-09-28T12:34:56.123Z", "2026-09-28T12:34:56.123+00:00"] {
            EntitlementURLProtocol.body = Data("[{\"plan\":\"pro\",\"valid_until\":\"\(stamp)\"}]".utf8)
            let value = try await client.entitlement("access", userID: "user-a")
            #expect(value.isPro)
            #expect(value.userID == "user-a")
            #expect(value.validUntil != nil)
        }
    }

    @Test func sessionWrapperUsesInjectedKeyStore() throws {
        let fake = InMemoryKeyStore()
        let store = AccountSessionStore(keys: fake)
        let session = AccountSession(userID: "user-a", accessToken: "access", refreshToken: "refresh", expiresAt: Date(), email: "a@example.com")
        try store.save(session)
        #expect(try store.load()?.email == "a@example.com")
        try store.clear()
        #expect(try store.load() == nil)
    }
}

private final class EntitlementURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
