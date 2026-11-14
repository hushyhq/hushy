import Foundation

public enum AccountSessionError: Error, Equatable, Sendable {
    /// The server refused the refresh token and no newer one was stored: the person must sign in.
    case refused
    /// The network or server could not be reached or understood. The session is still good.
    case unavailable
    /// The Keychain could not be read.
    case unreadable
    /// The person signed out while this refresh was running, so its result was dropped.
    case signedOut
}

/// A counter bumped by sign-out. A refresh that started before the bump must not save its result.
private final class SignOutEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

/// The one owner of the rotating refresh token. The gate, the plan refresh and the Pro pane used
/// to refresh the same token separately, so whichever ran second held a spent token, was refused,
/// and signed the person out. Everyone now asks here: the stored session is read every time, a
/// refresh by someone else is picked up instead of repeated, simultaneous callers share one
/// refresh, and a refusal is retried once if the stored token changed while it was in flight.
public actor AccountSessionKeeper {
    /// Production keeper: the Keychain store and the app's configured Supabase project.
    public static let shared = AccountSessionKeeper(store: AccountSessionStore()) { token in
        guard let configuration = AccountConfiguration() else { throw AccountError.requestFailed }
        return try await AccountClient(configuration: configuration).refresh(token)
    }

    public nonisolated let store: AccountSessionStore
    private let refresh: @Sendable (String) async throws -> AccountSession
    private let now: @Sendable () -> Date
    private var inFlight: (token: String, task: Task<AccountSession, Error>)?
    private nonisolated let epoch = SignOutEpoch()
    private static let expirySkew: TimeInterval = 30
    /// Only a 400 or 422 from the token endpoint says the refresh token itself is bad. A 401 is
    /// normally the project key being rejected, and says nothing about the person's session.
    private static let refusalStatuses = [400, 422]

    public init(
        store: AccountSessionStore,
        now: @escaping @Sendable () -> Date = { Date() },
        refresh: @escaping @Sendable (String) async throws -> AccountSession
    ) {
        self.store = store
        self.now = now
        self.refresh = refresh
    }

    /// Sign-out: clears the stored session and cancels the right of any refresh already running to
    /// save its result, so a refresh in flight can never bring a signed-out account back.
    public nonisolated func forget() {
        epoch.bump()
        try? store.clear()
    }

    /// A session whose access token can be used now, or `nil` when nothing is signed in.
    /// `rejecting` names an access token the server just refused, so it is replaced even if the
    /// clock says it is still good. `fallback` is a session held only in memory (for example one
    /// the Keychain would not save); it is used when the store has none, and tried when the stored
    /// copy has been refused but the in-memory one carries a newer token.
    public func usable(rejecting rejected: String? = nil, fallback: AccountSession? = nil) async throws -> AccountSession? {
        let startEpoch = epoch.value
        var start: AccountSession
        do {
            if let loaded = try store.load() { start = loaded }
            else if let fallback { start = fallback }
            else { return nil }
        } catch {
            guard let fallback else { throw AccountSessionError.unreadable }
            start = fallback
        }
        var spent = Set<String>()
        for _ in 0..<3 {
            if isUsable(start, rejecting: rejected) { return start }
            spent.insert(start.refreshToken)
            do { return try await renew(start, epoch: startEpoch, spent: spent, fallbackPassed: fallback != nil) }
            catch AccountError.httpStatus(let status) where Self.refusalStatuses.contains(status) {
                // The token may have been rotated by another caller, or the stored copy may be
                // older than the one in memory (a save that failed). Try those before refusing.
                let latest: AccountSession?
                do { latest = try store.load() } catch { throw AccountSessionError.unreadable }
                if let latest, latest.userID == start.userID, !spent.contains(latest.refreshToken) { start = latest; continue }
                if let fallback, fallback.userID == start.userID, !spent.contains(fallback.refreshToken) { start = fallback; continue }
                throw AccountSessionError.refused
            } catch let error as AccountSessionError {
                throw error
            } catch { throw AccountSessionError.unavailable }
        }
        throw AccountSessionError.refused
    }

    private func isUsable(_ session: AccountSession, rejecting rejected: String?) -> Bool {
        session.expiresAt.timeIntervalSince(now()) > Self.expirySkew && session.accessToken != rejected
    }

    private func renew(_ session: AccountSession, epoch startEpoch: Int, spent: Set<String>, fallbackPassed: Bool) async throws -> AccountSession {
        if let running = inFlight, running.token == session.refreshToken {
            // Another caller is already refreshing this very token; share its result (it saves it).
            let shared = try await running.task.value
            guard shared.userID == session.userID else { throw AccountSessionError.unavailable }
            guard epoch.value == startEpoch else { throw AccountSessionError.signedOut }
            return shared
        }
        let refresh = self.refresh
        let token = session.refreshToken
        let task = Task { try await refresh(token) }
        inFlight = (token, task)
        defer { if inFlight?.token == token { inFlight = nil } }
        let renewed = try await task.value
        guard renewed.userID == session.userID else { throw AccountSessionError.unavailable }
        // Signed out meanwhile: the result is dropped, not saved.
        guard epoch.value == startEpoch else { throw AccountSessionError.signedOut }
        // Save only over what this refresh started from: the token it spent (or one already known to
        // be spent), or an empty store when the caller supplied the session. If the store now holds
        // anything else (another account signed in, another caller rotated), leave it alone.
        let current = try? store.load()
        let mayWrite = current.map { spent.contains($0.refreshToken) } ?? fallbackPassed
        if mayWrite {
            guard epoch.value == startEpoch else { throw AccountSessionError.signedOut }
            try? store.save(renewed)
        }
        return renewed
    }
}
