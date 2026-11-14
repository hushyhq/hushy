import Foundation

/// A failed check preserves an approval already observed for this same account.
public enum BetaApprovalCheck: Equatable, Sendable { case notChecked, approved, notApproved, failed, sessionRefused }
public enum BetaGateDecision: Equatable, Sendable {
    case open, signIn, waiting, couldNotCheck

    public static func resolve(session: AccountSession?, approvedUserID: String?, check: BetaApprovalCheck) -> Self {
        guard let session else { return .signIn }
        switch check {
        case .approved: return .open
        case .notApproved: return .waiting
        case .sessionRefused: return approvedUserID == session.userID ? .open : .signIn
        case .notChecked, .failed:
            return approvedUserID == session.userID ? .open : .couldNotCheck
        }
    }
}

public struct BetaApprovalStore: Sendable {
    private let keys: any KeyStoreProtocol
    private let account = "account.betaApproval"
    public init(keys: any KeyStoreProtocol = FileKeyStore.account) { self.keys = keys }
    public func approvedUserID() throws -> String? {
        guard let data = try keys.read(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func save(userID: String) throws { try keys.write(Data(userID.utf8), account: account) }
    public func clear() throws { try keys.delete(account: account) }
}

public struct BetaApprovalVerifier: Sendable {
    private let openService: OpenServiceStore
    public init(openService: OpenServiceStore = OpenServiceStore()) { self.openService = openService }
    /// Reads whether this account is approved. Tokens come from `keeper`, which reads the stored
    /// session fresh and owns every refresh; `session` is only used when the store holds none.
    /// A 401 on the profile read itself gets one fresh token and one retry.
    ///
    /// Also asks whether the service is open (a public answer with nothing about the person) and
    /// keeps what it hears in `openService`: once it is open nobody needs an approval, and every
    /// signed-in account has Pro (`Entitlements`). A failed read keeps the last answer.
    public func check(
        session: AccountSession, client: AccountClient, keeper: AccountSessionKeeper
    ) async -> (AccountSession, BetaApprovalCheck) {
        var current = session
        var rejected: String?
        let serviceIsOpen = try? await client.serviceIsOpen()
        if let serviceIsOpen { openService.record(open: serviceIsOpen) }
        for attempt in 0..<2 {
            let usable: AccountSession?
            do { usable = try await keeper.usable(rejecting: rejected, fallback: current) }
            catch AccountSessionError.refused { return (current, .sessionRefused) }
            catch { return (current, .failed) }
            guard let usable, usable.userID == session.userID else { return (current, .failed) }
            current = usable
            do {
                if try await client.betaApproval(accessToken: usable.accessToken, userID: usable.userID) { return (current, .approved) }
                // No approval on the profile: an open service lets the person in anyway. A failed
                // read of that answer leaves this as it was, waiting.
                return (current, serviceIsOpen == true ? .approved : .notApproved)
            } catch AccountError.httpStatus(401) where attempt == 0 {
                rejected = usable.accessToken
            } catch { return (current, .failed) }
        }
        return (current, .failed)
    }
}
