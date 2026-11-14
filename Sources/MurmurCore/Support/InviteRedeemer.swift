import CryptoKit
import Foundation

/// What a redeem attempt came to, with the one sentence both Settings and onboarding show.
/// The sentences live here (next to `InviteCode.Error.message`) so the two screens can't drift.
public enum InviteRedeemResult: Equatable, Sendable {
    case redeemed(until: Date)
    case alreadyRedeemed(until: Date)
    case keptLonger(until: Date)
    case failed(InviteCode.Error)

    public var isSuccess: Bool {
        if case .failed = self { return false }
        return true
    }

    /// When Pro runs until, for the three success cases.
    public var until: Date? {
        switch self {
        case .redeemed(let date), .alreadyRedeemed(let date), .keptLonger(let date): date
        case .failed: nil
        }
    }

    /// No screen takes a code any more (Pro removed, founder 2026-11-11); a code attached to an
    /// account is still applied silently (`BetaInviteApplier`) and its record kept, because it marks
    /// a founding member (`FoundingMember`).
    public var message: String {
        switch self {
        case .redeemed: "Invite code redeemed."
        case .alreadyRedeemed: "This code was already redeemed on this Mac."
        case .keptLonger: "Valid, and already redeemed on this Mac."
        case .failed(let error): error.message
        }
    }
}

/// Verifies a pasted code and stores the redemption (`InviteRedemptionStore.redeem`); the single
/// entry point for every screen that takes a code. Local only: no network, no account.
public enum InviteRedeemer {
    /// `nil` when `text` is blank (nothing to do).
    public static func redeem(
        _ text: String,
        publicKey: Curve25519.Signing.PublicKey? = InviteCode.embeddedPublicKey,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> InviteRedeemResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch InviteRedemptionStore.redeem(trimmed, publicKey: publicKey, now: now, defaults: defaults) {
        case .failure(let error): return .failed(error)
        case .success(.redeemed(let record)): return .redeemed(until: record.expiresAt)
        case .success(.alreadyRedeemed(let record)): return .alreadyRedeemed(until: record.expiresAt)
        case .success(.keptLonger(let record)): return .keptLonger(until: record.expiresAt)
        }
    }
}
