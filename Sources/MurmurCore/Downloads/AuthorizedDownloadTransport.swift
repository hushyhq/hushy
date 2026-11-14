import Foundation

/// Hushy's own model host. Its files are served only to a signed-in Hushy account (the `hushy-models`
/// Worker, `models-gate/`); every other download (Hugging Face, the speech model) carries no token.
public enum ModelDownloadHost {
    public static let host = "models.tryhushy.com"

    public static func requiresAccount(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == host
    }
}

/// A transport that can send a bearer token with a request.
public protocol BearerDownloadTransport: DownloadTransport {
    func open(_ url: URL, from offset: Int64, ifRange validator: String?, bearer: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>)
}

/// Hands out the account's access token for a model download.
public protocol DownloadAuthorizing: Sendable {
    /// A token that can be used now. `rejecting` is a token the server just refused, so a fresh one is
    /// fetched even if the clock says it is still good. Throws `AssetDownloadError.signInRequired` when
    /// nobody is signed in or the account's session was refused, `.accountUnavailable` when the account
    /// service could not be reached.
    func accessToken(rejecting: String?) async throws -> String
}

/// Adds the account's token to every request for `ModelDownloadHost`, and nothing to any other host.
/// A 401 gets one fresh token and one more try; a second 401 means the person must sign in again.
/// Resume is untouched: the range and validator go through as they came.
public struct AuthorizedDownloadTransport<Base: BearerDownloadTransport>: DownloadTransport {
    public let base: Base
    public let authorizer: any DownloadAuthorizing

    public init(base: Base, authorizer: any DownloadAuthorizing) {
        self.base = base
        self.authorizer = authorizer
    }

    public func open(_ url: URL, from offset: Int64, ifRange validator: String?) async throws
        -> (TransportResponse, AsyncThrowingStream<Data, Error>)
    {
        guard ModelDownloadHost.requiresAccount(url) else {
            return try await base.open(url, from: offset, ifRange: validator, bearer: nil)
        }
        // Never a token-less request to the model host: a signed-out app learns it here, without the network.
        let token = try await authorizer.accessToken(rejecting: nil)
        let first = try await base.open(url, from: offset, ifRange: validator, bearer: token)
        guard first.0.statusCode == 401 else { return first }
        try await Self.drain(first.1)
        let fresh = try await authorizer.accessToken(rejecting: token)
        guard fresh != token else { throw AssetDownloadError.signInRequired }
        let second = try await base.open(url, from: offset, ifRange: validator, bearer: fresh)
        guard second.0.statusCode == 401 else { return second }
        try await Self.drain(second.1)
        throw AssetDownloadError.signInRequired
    }

    /// A refusal's body is a few bytes of JSON; reading it lets its connection finish cleanly.
    private static func drain(_ body: AsyncThrowingStream<Data, Error>) async throws {
        var read = 0
        for try await chunk in body {
            read += chunk.count
            if read > 64 * 1024 { break }
        }
    }
}

/// The signed-in account's token from `AccountSessionKeeper`, which owns every refresh of the rotating
/// refresh token. `fallback` is a session held only in memory by the sign-in gate (one the Keychain
/// would not save). The token is never logged.
public struct AccountDownloadAuthorizer: DownloadAuthorizing {
    public let keeper: AccountSessionKeeper
    public let fallback: @Sendable () async -> AccountSession?

    public init(keeper: AccountSessionKeeper = .shared, fallback: @escaping @Sendable () async -> AccountSession? = { nil }) {
        self.keeper = keeper
        self.fallback = fallback
    }

    public func accessToken(rejecting: String?) async throws -> String {
        let session: AccountSession?
        do {
            session = try await keeper.usable(rejecting: rejecting, fallback: await fallback())
        } catch AccountSessionError.refused, AccountSessionError.signedOut {
            throw AssetDownloadError.signInRequired
        } catch {
            throw AssetDownloadError.accountUnavailable
        }
        guard let session, !session.accessToken.isEmpty else { throw AssetDownloadError.signInRequired }
        return session.accessToken
    }
}
