import AppKit
import MurmurCore
import Observation

/// What the browser sign-in asks of the world around it, so tests can run it on fakes.
struct BrowserSignInDependencies {
    var open: @MainActor (URL) -> Void
    var makeSecret: @MainActor () -> PKCEChallenge
    /// How long an attempt waits for the browser before it lapses by itself.
    var lifetime: Duration
    /// How the lapse waits. The app passes the real clock; a test passes one it advances itself.
    var sleep: @Sendable (Duration) async throws -> Void

    @MainActor static func live() -> BrowserSignInDependencies {
        BrowserSignInDependencies(
            open: { NSWorkspace.shared.open($0) },
            makeSecret: { PKCEChallenge.generate() },
            lifetime: .seconds(15 * 60),
            sleep: { try await Task.sleep(for: $0) })
    }
}

/// Signing in through the website. The app makes a secret it keeps only in memory, opens the
/// site's sign-in page with the secret's challenge, and waits. When the browser returns to the app
/// with a hand-off id, the id and the secret are posted to the site, which hands back the session
/// once.
///
/// Only a successful claim, cancel, a new start or the lapse ends an attempt. A return the site
/// refuses (a stray page, or the first tab after "Start again") leaves the attempt waiting with
/// its secret, so it cannot burn the live one. A return with no attempt waiting is told apart
/// from silence: the person sees that it expired.
///
/// Nothing here is logged or stored: not the secret, not the id, not the session (the gate saves it).
@MainActor @Observable
final class BrowserSignIn {
    enum Phase: Equatable { case idle, waiting, claiming }
    enum Failure: Equatable { case unavailable, failed, expired }

    private(set) var phase: Phase = .idle
    /// Why the last attempt, or the last return, did not end in a sign-in. Cleared by the next start.
    private(set) var failure: Failure?
    /// Where a claimed session goes.
    @ObservationIgnored var onSession: (AccountSession) -> Void = { _ in }
    @ObservationIgnored private(set) var claimTask: Task<Void, Never>?
    /// The sign-out of a session that was claimed after its attempt had been given up.
    @ObservationIgnored private(set) var discardTask: Task<Void, Never>?

    @ObservationIgnored private let client: @MainActor () -> AccountClient?
    @ObservationIgnored private let deps: BrowserSignInDependencies
    /// The secret of the attempt in progress. Memory only; gone on a successful claim, cancel, a new start or the lapse.
    @ObservationIgnored private var pending: PKCEChallenge?
    /// Bumped by every start, cancel and lapse, so an older timer or claim cannot touch a newer attempt.
    @ObservationIgnored private var attempt = 0
    /// The timer of the latest attempt. Kept after it ends so a test can wait for it.
    @ObservationIgnored private(set) var lapseTask: Task<Void, Never>?

    init(client: @escaping @MainActor () -> AccountClient?, dependencies: BrowserSignInDependencies) {
        self.client = client
        deps = dependencies
    }

    var isActive: Bool { phase != .idle }

    /// Opens the sign-in page in the default browser. Starting again replaces the attempt in progress.
    func start() {
        reset()
        failure = nil
        let secret = deps.makeSecret()
        guard let url = client()?.appSignInURL(challenge: secret.challenge) else {
            failure = .unavailable
            return
        }
        pending = secret
        phase = .waiting
        let mine = attempt
        lapseTask = Task { [weak self, lifetime = deps.lifetime, sleep = deps.sleep] in
            try? await sleep(lifetime)
            guard !Task.isCancelled, let self, self.attempt == mine else { return }
            self.reset()
        }
        deps.open(url)
    }

    /// Gives up: the secret is forgotten, so a browser that comes back later finds nothing waiting.
    func cancel() {
        reset()
        failure = nil
    }

    /// Handles an address the system opened in the app. Returns true when the person should be
    /// shown something: a claim began, or a well-formed return arrived with nothing waiting for it.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let id = AppSignInCallback.id(from: url) else { return false }
        switch phase {
        case .claiming: return false
        case .idle:
            failure = .expired
            return true
        case .waiting: break
        }
        guard let secret = pending, let client = client() else { return false }
        phase = .claiming
        failure = nil
        let mine = attempt
        claimTask = Task { [weak self] in
            let result: Result<AccountSession, Error>
            do { result = .success(try await client.claimSignIn(id: id, secret: secret.verifier)) }
            catch { result = .failure(error) }
            guard let self else { return }
            guard self.attempt == mine else {
                // Given up while the claim ran: the session must not outlive the attempt.
                if case .success(let session) = result { self.discard(session, with: client) }
                return
            }
            switch result {
            case .success(let session):
                self.finish()
                self.onSession(session)
            case .failure(let error):
                if Self.isRefusal(error) {
                    // The site refuses a stray or stale return the same way it refuses a wrong secret.
                    // The attempt is still alive: keep the secret, the timer and the waiting screen.
                    self.phase = .waiting
                    self.failure = .expired
                } else {
                    self.finish()
                    self.failure = .failed
                }
            }
        }
        return true
    }

    /// The site's answers to a return it will not honour: its one refusal, or its rate limit. Neither
    /// ends the attempt, so a burst of stray returns cannot end a real sign-in.
    private static func isRefusal(_ error: Error) -> Bool {
        if case AccountError.httpStatus(let status) = error { return status == 404 || status == 429 }
        return false
    }

    private func discard(_ session: AccountSession, with client: AccountClient) {
        // This session only: the person's website and other Macs stay signed in.
        discardTask = Task { try? await client.signOutThisSession(session.accessToken) }
    }

    /// The attempt ended on its own terms (claimed, or failed for a reason that is not a refusal).
    private func finish() {
        pending = nil
        lapseTask?.cancel()
        phase = .idle
    }

    private func reset() {
        attempt += 1
        pending = nil
        lapseTask?.cancel()
        phase = .idle
    }
}
