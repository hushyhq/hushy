import Foundation

/// One connected calendar account: which provider, and a stable id (the provider's account
/// identifier or, until one is known, a UUID minted at connect time).
public struct CalendarAccountID: Sendable, Hashable, Codable {
    public let provider: CalendarProvider
    public let id: String

    public init(provider: CalendarProvider, id: String) {
        self.provider = provider
        self.id = id
    }

    /// A fresh account id for a new sign-in.
    public static func new(_ provider: CalendarProvider) -> CalendarAccountID {
        CalendarAccountID(provider: provider, id: UUID().uuidString.lowercased())
    }

    var keychainAccount: String { "connector.\(provider.rawValue).\(id)" }
}

/// Where tokens live. The real one sits on `KeyStoreProtocol` (`KeychainKeyStore`), so tests use
/// `InMemoryKeyStore` and never touch the login Keychain.
public protocol OAuthTokenStoring: Sendable {
    func load(_ account: CalendarAccountID) throws -> OAuthTokenSet?
    /// Stores tokens and adds the account to the index.
    func save(_ tokens: OAuthTokenSet, for account: CalendarAccountID) throws
    /// Disconnect: removes the tokens and the account from the index. Missing is not an error.
    func delete(_ account: CalendarAccountID) throws
    /// Drops the tokens but keeps the account listed, so the Connectors row can say "Reconnect"
    /// after the provider revoked access.
    func removeTokens(for account: CalendarAccountID) throws
    func accounts() throws -> [CalendarAccountID]
}

/// Keychain-backed store (`docs/product/CONNECTORS.md` §6.3): one generic-password item per
/// account plus an index item listing the accounts, so `accounts()` needs no Keychain
/// enumeration. In the app it is built over `KeychainKeyStore(service: keychainService)`, whose
/// items are `WhenUnlockedThisDeviceOnly` and never synchronizable.
public struct OAuthTokenStore: OAuthTokenStoring {
    public static let keychainService = "app.hushy.connectors"
    static let indexAccount = "connector.accounts"

    private let keyStore: any KeyStoreProtocol

    public init(keyStore: any KeyStoreProtocol) {
        self.keyStore = keyStore
    }

    /// Unreadable stored data (e.g. from a future format) reads as "no tokens" — the account
    /// then needs a reconnect — rather than wedging every calendar read with a decode error.
    public func load(_ account: CalendarAccountID) throws -> OAuthTokenSet? {
        guard let data = try keyStore.read(account: account.keychainAccount) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    public func save(_ tokens: OAuthTokenSet, for account: CalendarAccountID) throws {
        try keyStore.write(try JSONEncoder().encode(tokens), account: account.keychainAccount)
        let index = try accounts()
        if !index.contains(account) {
            try writeIndex(index + [account])
        }
    }

    public func delete(_ account: CalendarAccountID) throws {
        try keyStore.delete(account: account.keychainAccount)
        let index = try accounts()
        if index.contains(account) {
            try writeIndex(index.filter { $0 != account })
        }
    }

    public func removeTokens(for account: CalendarAccountID) throws {
        try keyStore.delete(account: account.keychainAccount)
    }

    public func accounts() throws -> [CalendarAccountID] {
        guard let data = try keyStore.read(account: Self.indexAccount) else { return [] }
        return (try? JSONDecoder().decode([CalendarAccountID].self, from: data)) ?? []
    }

    private func writeIndex(_ index: [CalendarAccountID]) throws {
        if index.isEmpty {
            try keyStore.delete(account: Self.indexAccount)
        } else {
            try keyStore.write(try JSONEncoder().encode(index), account: Self.indexAccount)
        }
    }
}

/// Serializes token use for one account: hands out a valid access token, refreshing (once, even
/// with concurrent callers) and persisting when the stored one is within the leeway of expiry,
/// and turns a dead refresh token into `.reauthorizationRequired` after deleting the tokens.
public actor OAuthSession {
    public nonisolated let account: CalendarAccountID
    public nonisolated let configuration: OAuthClientConfiguration
    /// The signed-in user's address when known (Graph doesn't flag "self" on attendees).
    public nonisolated let accountEmail: String?
    private let client: OAuthTokenClient
    private let store: any OAuthTokenStoring
    private let clock: @Sendable () -> Date
    private var inFlightRefresh: (id: Int, task: Task<OAuthTokenSet, any Error>)?
    private var nextRefreshID = 0
    /// Bumped by `disconnect` and `complete`, so a refresh that was in flight can't write stale
    /// tokens back (or hand them to a waiter) after the account changed under it.
    private var generation = 0
    public private(set) var refreshCount = 0
    /// Set when the provider rejected the refresh token; cleared by a successful `complete`.
    public private(set) var needsReauthorization = false

    public init(
        account: CalendarAccountID, client: OAuthTokenClient, store: any OAuthTokenStoring,
        accountEmail: String? = nil, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(account.provider == client.configuration.provider, "account and client provider differ")
        self.account = account
        self.configuration = client.configuration
        self.accountEmail = accountEmail
        self.client = client
        self.store = store
        self.clock = clock
    }

    public func hasTokens() -> Bool {
        ((try? store.load(account)) ?? nil) != nil
    }

    public func hasRefreshToken() -> Bool {
        ((try? store.load(account)) ?? nil)?.refreshToken != nil
    }

    /// A usable access token. `forceRefresh` is for a 401 on a token we believed valid.
    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = try store.load(account) else { throw OAuthError.reauthorizationRequired }
        guard forceRefresh || tokens.needsRefresh(now: clock()) else { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ tokens: OAuthTokenSet) async throws -> OAuthTokenSet {
        let startGeneration = generation
        if let inFlightRefresh {
            let joined = try await inFlightRefresh.task.value
            guard generation == startGeneration else { throw OAuthError.reauthorizationRequired }
            return joined
        }
        let client = client, now = clock()
        let task = Task { try await client.refresh(tokens, now: now) }
        nextRefreshID += 1
        let id = nextRefreshID
        inFlightRefresh = (id, task)
        defer { if inFlightRefresh?.id == id { inFlightRefresh = nil } }
        do {
            let refreshed = try await task.value
            guard generation == startGeneration else { throw OAuthError.reauthorizationRequired }
            try store.save(refreshed, for: account)
            refreshCount += 1
            return refreshed
        } catch OAuthError.reauthorizationRequired where generation == startGeneration {
            needsReauthorization = true
            try? store.removeTokens(for: account)
            throw OAuthError.reauthorizationRequired
        }
    }

    /// Completes a sign-in: exchanges the code and stores the result. Supersedes any refresh
    /// still in flight for the old tokens.
    public func complete(_ callback: OAuthCallback, request: OAuthAuthorizationRequest) async throws {
        guard request.configuration == configuration else { throw OAuthError.unexpectedRedirect }
        generation += 1
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
        let startGeneration = generation
        let tokens = try await client.exchange(callback, verifier: request.pkce.verifier, redirectURI: request.redirectURI, now: clock())
        guard generation == startGeneration else { throw OAuthError.reauthorizationRequired }
        try store.save(tokens, for: account)
        needsReauthorization = false
    }

    /// Disconnect. The tokens and the account are deleted locally first (guaranteed, even if the
    /// app quits mid-call), then — Google only — the refresh token is revoked at the provider on
    /// a best-effort basis so a reconnect gets fresh consent. Microsoft has no public-client
    /// revocation endpoint, so an Outlook disconnect is local-only (the grant stays listed at
    /// account.microsoft.com / myapps.microsoft.com until the user removes it there).
    public func disconnect() async throws {
        generation += 1
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
        needsReauthorization = false
        let tokens = (try? store.load(account)) ?? nil
        try store.delete(account)
        if let tokens { await client.revoke(tokens) }
    }
}

/// Exactly one `OAuthSession` per account, so the single-flight refresh and the disconnect
/// generation guard actually cover every caller (two sessions for one account could both
/// refresh and race a rotating refresh token). The app keeps one registry and gets sessions
/// only from it.
public actor OAuthSessionRegistry {
    private let configuration: CalendarConnectorConfiguration
    private let store: any OAuthTokenStoring
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date
    private var sessions: [CalendarAccountID: OAuthSession] = [:]

    public init(
        configuration: CalendarConnectorConfiguration, store: any OAuthTokenStoring, transport: any HTTPTransport,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = store
        self.transport = transport
        self.clock = clock
    }

    /// The session for `account`, created on first use; nil when this build has no client id for
    /// the provider. `accountEmail` is only used when the session is first created.
    public func session(for account: CalendarAccountID, accountEmail: String? = nil) -> OAuthSession? {
        if let existing = sessions[account] { return existing }
        guard let session = makeSession(account, accountEmail: accountEmail) else { return nil }
        sessions[account] = session
        return session
    }

    /// Disconnects (revoking at Google, best-effort) and forgets the account's session.
    public func disconnect(_ account: CalendarAccountID) async throws {
        if let session = sessions.removeValue(forKey: account) ?? makeSession(account, accountEmail: nil) {
            try await session.disconnect()
        } else {
            try store.delete(account)
        }
    }

    private func makeSession(_ account: CalendarAccountID, accountEmail: String?) -> OAuthSession? {
        guard let client = configuration.client(for: account.provider) else { return nil }
        return OAuthSession(
            account: account, client: OAuthTokenClient(configuration: client, transport: transport),
            store: store, accountEmail: accountEmail, clock: clock)
    }
}
