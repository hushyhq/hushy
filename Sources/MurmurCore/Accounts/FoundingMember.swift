import Foundation

/// Founding members: Hushy accounts made before 1 December 2026, wherever the person is
/// (founder, 2026-11-11, when Pro was removed). Nothing a founding member can use on that date will
/// ever go behind a paywall, and they get six months free of any paid plan Hushy adds. The binding
/// wording is on the site's terms page ("Price and founding members").
///
/// The server's account creation time is the record of who is a founding member. The app does not
/// receive it, so for the in-app badge it keeps the first time this Mac saw a signed-in account, or a
/// redeemed invite code, and calls the person a founding member when that came before the cut-off.
/// An account made before the cut-off but first signed in on this Mac after it shows no badge; it is
/// still a founding member on the server, which is what the pledge rests on.
public struct FoundingMember: @unchecked Sendable {
    /// 12:00 UTC on 1 December 2026: midnight at UTC−12, the last place where 30 November ends, so
    /// an account made on 30 November anywhere in the world counts.
    public static let cutoff = Date(timeIntervalSince1970: 1_796_126_400)
    public static let firstSignedInKey = "account.firstSignedInAt"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The first time this Mac saw a signed-in account, if it has.
    public var firstSignedInAt: Date? { defaults.object(forKey: Self.firstSignedInKey) as? Date }

    /// Keeps the first sign-in time; later calls never move it.
    public func noteSignedIn(now: Date = Date()) {
        guard firstSignedInAt == nil else { return }
        defaults.set(now, forKey: Self.firstSignedInKey)
    }

    /// Whether to show the founding-member badge: signed in, and first seen signed in (or an invite
    /// code redeemed) before the cut-off. Before the cut-off every signed-in account qualifies.
    public func isMember(signedIn: Bool, now: Date = Date()) -> Bool {
        guard signedIn else { return false }
        if now < Self.cutoff { return true }
        let invite = InviteRedemptionStore.current(defaults: defaults)?.redeemedAt
        return [firstSignedInAt, invite].compactMap { $0 }.contains { $0 < Self.cutoff }
    }
}
