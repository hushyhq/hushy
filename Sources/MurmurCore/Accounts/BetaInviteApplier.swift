import Foundation

/// Where a signed-in person's own invite code is read from. `AccountClient` is the real one.
public protocol InviteCodeSource: Sendable {
    func inviteCode(accessToken: String, userID: String) async throws -> String?
}

extension AccountClient: InviteCodeSource {}

/// What one attempt to apply the person's own invite code came to. It never carries the code.
public enum BetaInviteOutcome: Equatable, Sendable {
    /// Redeemed just now; Pro runs until the date.
    case applied(until: Date)
    /// Already redeemed on this Mac, or a longer grant is already held. Nothing changed.
    case alreadyApplied
    /// The founder has not stored a code for this account yet. Try again at the next check.
    case noCode
    /// The read failed. Nothing changed, and the app opens regardless.
    case unavailable(reason: BetaInviteFailure)
    /// A code arrived but did not verify. Nothing was stored.
    case rejected
    case signedOut
    /// The account changed while the code was being read, so it was dropped unredeemed.
    case superseded
}

/// Fixed, non-identifying reason for a failed code read.
public enum BetaInviteFailure: String, Equatable, Sendable {
    case unauthorized, server, network, response

    static func classify(_ error: Error) -> Self {
        if let accountError = error as? AccountError, case .httpStatus(let status) = accountError {
            return status == 401 || status == 403 ? .unauthorized : .server
        }
        return error is URLError ? .network : .response
    }
}

/// After the approval check passes, fetch this account's own code and redeem it through the same
/// local path as a pasted code (`InviteRedeemer`). Every outcome is silent and none can block
/// opening the app. The code is read into a local, redeemed, and never stored, logged or returned.
public struct BetaInviteApplier: Sendable {
    private let redeem: @Sendable (String) -> InviteRedeemResult?

    public init(redeem: @escaping @Sendable (String) -> InviteRedeemResult? = { InviteRedeemer.redeem($0) }) {
        self.redeem = redeem
    }

    public func apply(
        session: AccountSession?,
        source: some InviteCodeSource,
        stillCurrent: @Sendable () async -> Bool = { true }
    ) async -> BetaInviteOutcome {
        guard let session else { return .signedOut }
        let fetched: String?
        do { fetched = try await source.inviteCode(accessToken: session.accessToken, userID: session.userID) }
        catch { return .unavailable(reason: .classify(error)) }
        guard let code = fetched, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noCode }
        guard await stillCurrent() else { return .superseded }
        switch redeem(code) {
        case .redeemed(let until): return .applied(until: until)
        case .alreadyRedeemed, .keptLonger: return .alreadyApplied
        case .failed: return .rejected
        case nil: return .noCode
        }
    }
}
