import Foundation

/// A feature that could be gated. Every one is free today (founder, 2026-11-11: Pro removed, Hushy
/// is free). The type stays as the single source of truth for entitlement checks, and the hook a
/// future Teams plan would use (docs/research/speaker-labeling.md §4.1 for the original rationale).
public enum ProFeature: String, CaseIterable, Sendable {
    case speakerLabels
    case voiceSignatures
    /// System-audio ("the other side of the call") capture. Free (see `isFree`).
    case systemAudio
    /// Voice actions, with no monthly allowance. Free since 2026-11-11; it was the last Pro feature.
    case voiceActions
    /// Home's assistant chat (ask a connected agent CLI about your history over Hushy's MCP
    /// tools). Free for now — the product owner hasn't decided (2026-09-26); it's an entry here
    /// only so it can be flipped to Pro in one place.
    case assistantChat
    /// Direct read-only Google/Outlook calendar sign-in (`docs/product/CONNECTORS.md` §1.1.2
    /// item 4). Free — same capture feature as the macOS calendar path; kept as a case so it
    /// can flip in one place.
    case calendarConnectors

    /// Price (founder decision 2026-11-11, .claude/DECISIONS.md): "What runs on your Mac stays
    /// free; if we ever charge, it's for things we host." Everything here runs on the Mac, so every
    /// case is free. A hosted feature or a Teams policy would add its own case.
    public var isFree: Bool {
        switch self {
        case .speakerLabels, .systemAudio, .voiceSignatures, .assistantChat, .calendarConnectors, .voiceActions: true
        }
    }
}

/// Single source of truth for "is this feature unlocked." Every call site (diarization's
/// segment-rendering gate in the transcript UI, a future paywall banner, a future StoreKit
/// entitlement check) should go through `Entitlements.has(_:)` rather than checking
/// `UserDefaults` or a purchase receipt directly — this isolates the real StoreKit-vs-direct-sale
/// decision (research doc §4.3) behind one type that can be swapped or faked in tests.
///
/// For now this always returns a `UserDefaults`-backed debug override in DEBUG builds, and
/// `false` unconditionally in release — there is no real purchase/entitlement backend yet
/// (Phase 4 of the research doc, not built in this task). The debug override lets development
/// and QA builds exercise the gated UI without a StoreKit sandbox.
public enum Entitlements {
    /// Whether `feature` is unlocked for the current user: free features always; Pro features
    /// while Pro is active (`proActiveUntil`) or, in DEBUG only, the developer override is on.
    public static func has(
        _ feature: ProFeature, now: Date = Date(), defaults: UserDefaults = .standard,
        accounts: AccountSessionStore = AccountSessionStore(), entitlements: AccountEntitlementStore = AccountEntitlementStore()
    ) -> Bool {
        if feature.isFree { return true }
        return proActiveUntil(now: now, defaults: defaults, accounts: accounts, entitlements: entitlements) != nil
    }

    /// The instant Pro lapses (`.distantFuture` for the DEBUG override), or `nil` on Free. The
    /// app mirrors this into the store for the out-of-process MCP helper
    /// (`Store.writeProSnapshot`, `AppModel.refreshEntitlementSnapshot`).
    ///
    /// Pro comes from the latest of three sources: a redeemed invite code, a paid account, and the
    /// open service. While the service is open (`OpenServiceStore`, the website's go-live switch)
    /// every signed-in account has Pro with no code. A future paywall adds its own source here.
    public static func proActiveUntil(
        now: Date = Date(), defaults: UserDefaults = .standard,
        accounts: AccountSessionStore = AccountSessionStore(), entitlements: AccountEntitlementStore = AccountEntitlementStore()
    ) -> Date? {
        let session = (try? accounts.load()) ?? nil
        let paid = session.flatMap { (try? entitlements.load(for: $0.userID))?.activeUntil(now: now) }
        let open = session == nil ? nil : OpenServiceStore(defaults: defaults).activeUntil(now: now)
        let invite = InviteRedemptionStore.activeExpiry(now: now, defaults: defaults)
        if let latest = [invite, paid, open].compactMap({ $0 }).max() { return latest }
        #if DEBUG
        if defaults.bool(forKey: debugUnlockedKey) { return .distantFuture }
        #endif
        return nil
    }

    /// DEBUG-only override, toggled from the Developer settings pane
    /// (`DeveloperSettingsPane`), that unlocks every `ProFeature` at once. Reads/writes
    /// `UserDefaults` key `pro.debugUnlocked`. Has no effect in release builds — `has(_:)`
    /// never reads this outside `#if DEBUG`, so a value left over in a build's defaults from a
    /// prior debug run can't leak a paid feature into a release build reading the same defaults
    /// domain.
    public static var debugUnlocked: Bool {
        get { UserDefaults.standard.bool(forKey: debugUnlockedKey) }
        set { UserDefaults.standard.set(newValue, forKey: debugUnlockedKey) }
    }

    static let debugUnlockedKey = "pro.debugUnlocked"
}
