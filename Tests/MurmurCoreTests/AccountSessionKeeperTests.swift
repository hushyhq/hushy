import Foundation
import Testing
@testable import MurmurCore

/// One owner for the rotating refresh token: every caller reads the stored session first, so a
/// refresh by another caller is never lost, and a refusal is re-tried once with a token that
/// changed in the meantime. Fakes only: an in-memory Keychain and a scripted refresh.
@Suite("Account session keeper", .serialized, .timeLimit(.minutes(1)))
struct AccountSessionKeeperTests {
    private func session(_ access: String, refresh: String, expires: Date = .distantFuture, user: String = "person") -> AccountSession {
        AccountSession(userID: user, accessToken: access, refreshToken: refresh, expiresAt: expires, email: nil)
    }

    private func keeper(
        _ store: AccountSessionStore,
        calls: Calls = Calls(),
        refresh: @escaping @Sendable (String, Calls) async throws -> AccountSession
    ) -> AccountSessionKeeper {
        AccountSessionKeeper(store: store, refresh: { token in
            await calls.record(token)
            return try await refresh(token, calls)
        })
    }

    @Test("a stored token that has not expired is returned without a refresh")
    func freshIsReturned() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1"))
        let calls = Calls()
        let result = try await keeper(store, calls: calls) { _, _ in Issue.record("no refresh expected"); throw AccountError.requestFailed }.usable()
        #expect(result?.accessToken == "a1")
        #expect(await calls.tokens.isEmpty)
    }

    @Test("an expired session is renewed and saved")
    func expiredIsRenewed() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let renewed = session("a2", refresh: "r2")
        let result = try await keeper(store) { _, _ in renewed }.usable()
        #expect(result?.accessToken == "a2")
        #expect(try store.load()?.refreshToken == "r2")
    }

    @Test("a token the server just refused is replaced even though it has not expired")
    func rejectedIsReplaced() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1"))
        let result = try await keeper(store) { _, _ in session("a2", refresh: "r2") }.usable(rejecting: "a1")
        #expect(result?.accessToken == "a2")
    }

    @Test("a token rotated by another caller is picked up instead of refreshing with the old one")
    func rotatedElsewhere() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let k = keeper(store) { _, _ in Issue.record("no refresh expected"); throw AccountError.requestFailed }
        try store.save(session("a9", refresh: "r9"))
        #expect(try await k.usable()?.accessToken == "a9")
    }

    @Test("a refusal is retried once with a refresh token that changed meanwhile")
    func refusalThenRotated() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let calls = Calls()
        let result = try await keeper(store, calls: calls) { token, _ in
            if token == "r1" {
                try store.save(session("a9", refresh: "r9", expires: .distantPast))
                throw AccountError.httpStatus(400)
            }
            return session("a10", refresh: "r10")
        }.usable()
        #expect(result?.accessToken == "a10")
        #expect(await calls.tokens == ["r1", "r9"])
    }

    @Test("a refusal with nothing changed is final, and the stored session is left alone")
    func refusalIsFinal() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        for status in [400, 422] {
            await #expect(throws: AccountSessionError.refused) {
                try await keeper(store) { _, _ in throw AccountError.httpStatus(status) }.usable()
            }
        }
        #expect(try store.load()?.refreshToken == "r1")
    }

    @Test("a network or server failure, or a 401 about the project key, is 'unavailable', not a refusal")
    func unavailable() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        for failure in [AccountError.httpStatus(503), .httpStatus(401), .requestFailed] {
            await #expect(throws: AccountSessionError.unavailable) {
                try await keeper(store) { _, _ in throw failure }.usable()
            }
        }
    }

    @Test("two callers at once make one refresh and share its result")
    func oneRefreshAtATime() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let calls = Calls()
        let k = keeper(store, calls: calls) { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return session("a2", refresh: "r2")
        }
        async let first = k.usable()
        async let second = k.usable()
        let both = try await [first, second]
        #expect(both.compactMap { $0?.accessToken } == ["a2", "a2"])
        #expect(await calls.tokens == ["r1"])
    }

    @Test("an unreadable Keychain is its own error, and an in-memory session carries on")
    func unreadable() async throws {
        let store = AccountSessionStore(keys: BrokenKeyStore())
        let k = keeper(store) { _, _ in session("a2", refresh: "r2") }
        await #expect(throws: AccountSessionError.unreadable) { try await k.usable() }
        let held = session("a1", refresh: "r1", expires: .distantPast)
        let result = try await k.usable(fallback: held)
        #expect(result?.accessToken == "a2", "renewed even though it could not be saved")
    }

    @Test("with an empty store the fallback is used, and with no fallback there is no session")
    func emptyStore() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        let k = keeper(store) { _, _ in session("a2", refresh: "r2") }
        #expect(try await k.usable() == nil)
        #expect(try await k.usable(fallback: session("a1", refresh: "r1"))?.accessToken == "a1")
    }

    @Test("a renewal for a different account is not saved over the stored one")
    func otherAccountNotSaved() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        await #expect(throws: AccountSessionError.unavailable) {
            try await keeper(store) { _, _ in session("x", refresh: "rx", user: "someone-else") }.usable()
        }
        #expect(try store.load()?.userID == "person")
    }

    @Test("signing out while a refresh is running keeps the refreshed session from coming back")
    func signOutDuringRefresh() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let k = keeper(store) { _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return session("a2", refresh: "r2")
        }
        let result = Task { try await k.usable() }
        try await Task.sleep(for: .milliseconds(30))
        k.forget()
        await #expect(throws: AccountSessionError.signedOut) { try await result.value }
        #expect(try store.load() == nil)
    }

    @Test("another account signing in inside the window is not overwritten by the old refresh")
    func otherAccountInsideWindow() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let k = keeper(store) { _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return session("a2", refresh: "r2")
        }
        let result = Task { try await k.usable() }
        try await Task.sleep(for: .milliseconds(30))
        k.forget()
        try store.save(session("b1", refresh: "rb", user: "other"))
        await #expect(throws: AccountSessionError.signedOut) { try await result.value }
        #expect(try store.load()?.userID == "other")
    }

    @Test("a store changed without a sign-out is not overwritten either, but the caller still gets its tokens")
    func storeChangedUnderneath() async throws {
        let store = AccountSessionStore(keys: InMemoryKeyStore())
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let k = keeper(store) { _, _ in
            try store.save(session("b1", refresh: "rb", user: "other"))
            return session("a2", refresh: "r2")
        }
        #expect(try await k.usable()?.accessToken == "a2")
        #expect(try store.load()?.userID == "other")
    }

    @Test("a Keychain error while re-reading after a refusal is reported as unreadable")
    func unreadableAfterRefusal() async throws {
        let keys = SwitchKeyStore()
        let store = AccountSessionStore(keys: keys)
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        await #expect(throws: AccountSessionError.unreadable) {
            try await keeper(store) { _, _ in keys.failReads = true; throw AccountError.httpStatus(400) }.usable()
        }
    }

    @Test("when the renewal could not be saved, the in-memory session is tried before the stored one is refused")
    func fallbackBeatsStaleStore() async throws {
        let keys = SwitchKeyStore()
        let store = AccountSessionStore(keys: keys)
        try store.save(session("a1", refresh: "r1", expires: .distantPast))
        let calls = Calls()
        let k = keeper(store, calls: calls) { token, calls in
            if token == "r1" {
                // The server accepts r1 once; every later use of it is refused as spent.
                guard await calls.tokens.filter({ $0 == "r1" }).count == 1 else { throw AccountError.httpStatus(400) }
                return session("a2", refresh: "r2", expires: .distantPast)
            }
            return session("a3", refresh: "r3")
        }
        keys.failWrites = true
        let first = try #require(try await k.usable())
        #expect(first.refreshToken == "r2")
        #expect(try store.load()?.refreshToken == "r1", "the save failed, so the store still holds the spent token")
        keys.failWrites = false
        let second = try await k.usable(fallback: first)
        #expect(second?.accessToken == "a3")
        #expect(try store.load()?.refreshToken == "r3", "and the stale stored token is replaced once a save works")
    }
}

final class SwitchKeyStore: KeyStoreProtocol, @unchecked Sendable {
    struct Failure: Error {}
    private let inner = InMemoryKeyStore()
    private let lock = NSLock()
    private var reads = false, writes = false
    var failReads: Bool { get { lock.withLock { reads } } set { lock.withLock { reads = newValue } } }
    var failWrites: Bool { get { lock.withLock { writes } } set { lock.withLock { writes = newValue } } }
    func read(account: String) throws -> Data? { if failReads { throw Failure() }; return try inner.read(account: account) }
    func write(_ data: Data, account: String) throws { if failWrites { throw Failure() }; try inner.write(data, account: account) }
    func delete(account: String) throws { try inner.delete(account: account) }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

actor Calls {
    private(set) var tokens: [String] = []
    func record(_ token: String) { tokens.append(token) }
}

struct BrokenKeyStore: KeyStoreProtocol {
    struct Failure: Error {}
    func read(account: String) throws -> Data? { throw Failure() }
    func write(_ data: Data, account: String) throws { throw Failure() }
    func delete(account: String) throws { throw Failure() }
}
