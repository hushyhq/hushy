import Foundation
import Testing
@testable import Murmur
@testable import MurmurCore

/// The sign-in gate's controller, driven end to end with fakes: an in-memory (or failing)
/// Keychain, a scripted server behind a URLProtocol, and a fake app host. No real Keychain,
/// network or app model.
@MainActor
@Suite("Beta gate controller", .serialized, .timeLimit(.minutes(1)))
struct BetaGateControllerTests {
    private let person = AccountSession(userID: "person", accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, email: "person@example.com")
    private let approvedBody = #"[{"approved_at":"2026-10-01T00:00:00Z"}]"#

    @MainActor final class Rig {
        let sessionKeys = FlakyKeyStore()
        let approvalKeys = InMemoryKeyStore()
        let host = FakeHost()
        let invites = InviteLog()
        let entitlementClears = Counter()
        let browser = BrowserFakes()
        /// Where the gate keeps what it hears about the service being open: a private suite.
        let openService: OpenServiceStore
        var gate: BetaGateController!

        init(bypass: Bool = false) {
            GateStub.reset()
            let name = "app.hushy.tests.betagatecontroller.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            openService = OpenServiceStore(defaults: defaults)
            gate = makeGate(bypass: bypass)
        }

        /// A second controller over the same Keychain, as after quitting and relaunching.
        func makeGate(bypass: Bool = false) -> BetaGateController {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GateStub.self]
            let client = AccountClient(
                configuration: AccountConfiguration(url: URL(string: "https://example.supabase.co")!, anonKey: "public"),
                transport: URLSession(configuration: config))
            let keeper = AccountSessionKeeper(store: AccountSessionStore(keys: sessionKeys)) { try await client.refresh($0) }
            let invites = invites, clears = entitlementClears
            return BetaGateController(dependencies: BetaGateDependencies(
                keeper: keeper,
                approvals: BetaApprovalStore(keys: approvalKeys),
                client: { client },
                clearEntitlement: { clears.bump() },
                applyInvite: { _, _, _ in invites.bump(); return .noCode },
                browser: browser.dependencies,
                bypass: bypass,
                dailyCheck: false,
                openService: openService))
        }

        var sessions: AccountSessionStore { AccountSessionStore(keys: sessionKeys) }
        var approvals: BetaApprovalStore { BetaApprovalStore(keys: approvalKeys) }
        func seedSession(_ value: AccountSession) throws { try sessions.save(value) }
    }

    @Test("an automation build opens at once and asks nothing of the server")
    func bypass() async {
        let rig = Rig(bypass: true)
        rig.gate.start(host: rig.host)
        #expect(rig.gate.isOpen)
        #expect(rig.host.launched == 1)
        #expect(GateStub.profileRequests == 0)
    }

    @Test("nobody signed in: the sign-in screen, nothing launched, no request")
    func noSession() async {
        let rig = Rig()
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .signIn)
        #expect(rig.host.launched == 0)
        #expect(GateStub.profileRequests == 0)
        #expect(rig.gate.lastReason == "no-session")
    }

    @Test("a remembered approval opens the app before the check, and a failed check keeps it open")
    func rememberedApprovalSurvivesFailedCheck() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        try rig.approvals.save(userID: "person")
        GateStub.profile = (503, "")
        rig.gate.start(host: rig.host)
        #expect(rig.gate.isOpen)
        #expect(rig.host.launched == 1)
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(rig.host.suspended == 0)
        #expect(rig.gate.lastReason == "check-failed")
    }

    @Test("a session without a remembered approval is 'checking' until the check answers, then opens")
    func checkingThenOpen() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        #expect(rig.gate.isChecking)
        #expect(!rig.gate.isOpen)
        await rig.gate.checkAgain()
        #expect(!rig.gate.isChecking)
        #expect(rig.gate.isOpen)
        #expect(rig.host.launched == 1)
        #expect(try rig.approvals.approvedUserID() == "person")
        await rig.gate.inviteTask?.value
        #expect(rig.invites.count == 1)
    }

    @Test("fresh sign-in after an empty store applies the invite, then refresh tries again")
    func freshSignInAndRefreshApplyInvite() async {
        let rig = Rig()
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        rig.gate.signedIn(person)
        await rig.gate.checkAgain()
        await rig.gate.inviteTask?.value
        #expect(rig.invites.count == 1)
        #expect(rig.gate.inviteOutcome == .noCode)
        await rig.gate.checkAgain()
        await rig.gate.inviteTask?.value
        #expect(rig.invites.count == 2)
    }

    @Test("once the service is open an account with no approval is let in, and the answer is kept")
    func openServiceLetsAnUnapprovedAccountIn() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, "[]")
        GateStub.service = (200, #"{"open":true}"#)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(rig.host.launched == 1)
        #expect(rig.gate.lastReason == "approved")
        #expect(rig.openService.last()?.open == true)
        #expect(rig.openService.activeUntil() != nil)
        #expect(rig.host.refreshed >= 1, "the plan snapshot is refreshed so Pro shows at once")
    }

    @Test("while the service is closed an account with no approval still waits, with no free Pro")
    func closedServiceStillWaits() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, "[]")
        GateStub.service = (200, #"{"open":false}"#)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .waiting)
        #expect(rig.host.launched == 0)
        #expect(rig.openService.last()?.open == false)
        #expect(rig.openService.activeUntil() == nil)
    }

    @Test("the service answer being unreadable keeps the last one, and closing the service ends the free Pro")
    func serviceAnswerFollowsTheServer() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        GateStub.service = (200, #"{"open":true}"#)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.openService.activeUntil() != nil)
        GateStub.service = (503, "")
        await rig.gate.checkAgain()
        #expect(rig.openService.activeUntil() != nil, "a failed read is not a closed answer")
        GateStub.service = (200, #"{"open":false}"#)
        await rig.gate.checkAgain()
        #expect(rig.openService.activeUntil() == nil)
        #expect(rig.gate.isOpen, "an approved account stays in either way")
    }

    @Test("signing out refreshes the plan snapshot, so the open service's Pro goes with the account")
    func signOutRefreshesTheSnapshot() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        let before = rig.host.refreshed
        rig.gate.signOut()
        #expect(rig.host.refreshed == before + 1)
    }

    @Test("not approved: waiting, the app stays suspended and no invite is applied")
    func notApproved() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, "[]")
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .waiting)
        #expect(rig.host.suspended == 0, "nothing was launched, so there is nothing to suspend")
        #expect(rig.host.launched == 0)
        #expect(rig.invites.count == 0)
    }

    @Test("waiting, then approved: the app opens and is not left suspended")
    func waitingThenApproved() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, "[]")
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .waiting)
        GateStub.profile = (200, approvedBody)
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(rig.host.launched == 1)
        #expect(!rig.host.isSuspended)
    }

    @Test("a failed first check, 'use another address', then approval also leaves the app running")
    func failedThenOtherAddressThenApproved() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (503, "")
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .couldNotCheck)
        rig.gate.signOut()
        GateStub.profile = (200, approvedBody)
        rig.gate.signedIn(person)
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(!rig.host.isSuspended)
    }

    @Test("an app that was open is suspended when approval goes away, and resumed when it comes back")
    func openThenSuspendedThenResumed() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        GateStub.profile = (200, "[]")
        await rig.gate.checkAgain()
        #expect(rig.host.isSuspended)
        GateStub.profile = (200, approvedBody)
        await rig.gate.checkAgain()
        #expect(!rig.host.isSuspended)
        #expect(rig.host.launched == 1)
    }

    @Test("signing out while a refresh is running does not bring the session back")
    func signOutDuringRefresh() async throws {
        let rig = Rig()
        try rig.seedSession(AccountSession(userID: "person", accessToken: "a1", refreshToken: "r1", expiresAt: .distantPast, email: nil))
        GateStub.refreshPaused = true
        async let refreshStarted = GateStub.waitForRefreshStart()
        rig.gate.start(host: rig.host)
        await refreshStarted
        rig.gate.signOut()
        GateStub.resumeRefresh()
        await rig.gate.checkAgain()
        #expect(try rig.sessions.load() == nil)
        #expect(rig.gate.decision == .signIn)
    }

    @Test("pressing Try again while a check is running joins it instead of starting another")
    func overlappingChecks() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        GateStub.profileDelay = 0.2
        rig.gate.start(host: rig.host)
        async let first: Void = rig.gate.checkAgain()
        async let second: Void = rig.gate.checkAgain()
        _ = await (first, second)
        #expect(GateStub.profileRequests == 1)
        #expect(rig.host.launched == 1)
        #expect(!rig.gate.isChecking)
    }

    @Test("a late failure cannot close an app that an earlier answer opened")
    func lateFailureDoesNotSuspend() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        GateStub.profile = (503, "")
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(rig.host.suspended == 0)
    }

    @Test("tokens rotated by another part of the app are used, not the copy loaded at launch")
    func usesRotatedSession() async throws {
        let rig = Rig()
        let old = AccountSession(userID: "person", accessToken: "a1", refreshToken: "r1", expiresAt: .distantFuture, email: nil)
        try rig.seedSession(old)
        try rig.approvals.save(userID: "person")
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        // The entitlement loop renews: the stored session is now a2/r2 and the old token is spent.
        try rig.seedSession(AccountSession(userID: "person", accessToken: "a2", refreshToken: "r2", expiresAt: .distantFuture, email: nil))
        GateStub.refresh = (400, "")
        await rig.gate.checkAgain()
        #expect(GateStub.lastProfileAuthorization == "Bearer a2")
        #expect(GateStub.refreshRequests == 0)
        #expect(try rig.sessions.load()?.refreshToken == "r2")
    }

    @Test("a refused session is cleared, and after a relaunch the person is asked to sign in")
    func refusedThenRelaunch() async throws {
        let rig = Rig()
        try rig.seedSession(AccountSession(userID: "person", accessToken: "a1", refreshToken: "r1", expiresAt: .distantPast, email: nil))
        GateStub.refresh = (400, "")
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .signIn)
        #expect(try rig.sessions.load() == nil)
        let relaunched = rig.makeGate()
        relaunched.start(host: rig.host)
        #expect(relaunched.decision == .signIn)
        #expect(!relaunched.isChecking)
    }

    @Test("a Keychain that will not save the new session still lets the person in for this run")
    func saveFailureKeepsSessionInMemory() async {
        let rig = Rig()
        rig.sessionKeys.failWrites = true
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        rig.gate.signedIn(person)
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(rig.host.launched == 1)
        #expect(GateStub.lastProfileAuthorization == "Bearer access")
    }

    @Test("a Keychain read error is 'could not check', never 'signed out'")
    func readFailureIsNotSignedOut() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        rig.sessionKeys.failReads = true
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .couldNotCheck)
        #expect(rig.gate.lastReason == "keychain-unreadable")
        #expect(GateStub.profileRequests == 0)
        rig.sessionKeys.failReads = false
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(try rig.sessions.load() != nil)
    }

    @Test("signing in with a different address forgets the old approval and checks the new account")
    func signedInOtherAccount() async throws {
        let rig = Rig()
        try rig.approvals.save(userID: "someone-else")
        GateStub.profile = (200, "[]")
        rig.gate.start(host: rig.host)
        rig.gate.signedIn(person)
        #expect(try rig.approvals.approvedUserID() == nil)
        #expect(rig.gate.isChecking)
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .waiting)
        #expect(rig.gate.email == "person@example.com")
    }

    @Test("signing out clears everything stored, suspends the app and shows sign-in")
    func signOut() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        try rig.approvals.save(userID: "person")
        rig.gate.start(host: rig.host)
        rig.gate.signOut()
        #expect(rig.gate.decision == .signIn)
        #expect(try rig.sessions.load() == nil)
        #expect(try rig.approvals.approvedUserID() == nil)
        #expect(rig.entitlementClears.count == 1)
        #expect(rig.host.suspended == 1, "it had launched, so it is suspended")
        #expect(rig.gate.email == nil)
    }

    @Test("a check that finishes after the person signed out changes nothing")
    func staleCheckIgnored() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        GateStub.profileDelay = 0.2
        rig.gate.start(host: rig.host)
        rig.gate.signOut()
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.gate.decision == .signIn)
        #expect(rig.host.launched == 0)
    }

    // MARK: signing in through the browser

    @Test("browser sign-in: start, return to the app, claim, then the approval check opens the app")
    func browserSignInThenApproval() async throws {
        let rig = Rig()
        GateStub.profile = (200, approvedBody)
        GateStub.claim = (200, BrowserFakes.sessionBody)
        GateStub.claimAccepts = (BrowserFakes.id, rig.browser.secrets[0].verifier)
        rig.gate.start(host: rig.host)
        #expect(rig.gate.decision == .signIn)
        rig.gate.browser.start()
        #expect(rig.gate.browser.phase == .waiting)
        #expect(rig.browser.opened.count == 1)
        #expect(rig.gate.browser.handle(BrowserFakes.callback))
        await rig.gate.browser.claimTask?.value
        #expect(rig.gate.browser.phase == .idle)
        #expect(GateStub.lastClaimBody == ["id": BrowserFakes.id, "secret": rig.browser.secrets[0].verifier])
        #expect(try rig.sessions.load()?.userID == "person")
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(rig.host.launched == 1)
        #expect(try rig.approvals.approvedUserID() == "person")
        #expect(rig.gate.email == "person@example.com")
        #expect(rig.gate.signedInRevision == 1)
    }

    @Test("browser sign-in by an account that is not approved ends on the waiting screen, as any sign-in does")
    func browserSignInNotApproved() async {
        let rig = Rig()
        GateStub.profile = (200, "[]")
        GateStub.claim = (200, BrowserFakes.sessionBody)
        rig.gate.start(host: rig.host)
        rig.gate.browser.start()
        rig.gate.browser.handle(BrowserFakes.callback)
        await rig.gate.browser.claimTask?.value
        await rig.gate.checkAgain()
        #expect(rig.gate.decision == .waiting)
        #expect(rig.host.launched == 0)
    }

    @Test("a refused claim leaves the person signed out, still waiting, with nothing stored")
    func browserSignInClaimRefused() async throws {
        let rig = Rig()
        GateStub.claim = (404, #"{"error":"Not available"}"#)
        rig.gate.start(host: rig.host)
        rig.gate.browser.start()
        rig.gate.browser.handle(BrowserFakes.callback)
        await rig.gate.browser.claimTask?.value
        #expect(rig.gate.decision == .signIn)
        #expect(rig.gate.browser.phase == .waiting)
        #expect(rig.gate.browser.failure == .expired)
        #expect(try rig.sessions.load() == nil)
        #expect(GateStub.profileRequests == 0)
        #expect(rig.gate.signedInRevision == 0)
    }

    @Test("a stray return first, then the real one: the gate signs in and runs its check")
    func strayThenRealReturn() async throws {
        let rig = Rig()
        GateStub.profile = (200, approvedBody)
        GateStub.claim = (200, BrowserFakes.sessionBody)
        GateStub.claimAccepts = (BrowserFakes.id, rig.browser.secrets[0].verifier)
        rig.gate.start(host: rig.host)
        rig.gate.browser.start()
        rig.gate.browser.handle(BrowserSignInTests.strayCallback)
        await rig.gate.browser.claimTask?.value
        #expect(rig.gate.browser.phase == .waiting)
        rig.gate.browser.handle(BrowserFakes.callback)
        await rig.gate.browser.claimTask?.value
        await rig.gate.checkAgain()
        #expect(rig.gate.isOpen)
        #expect(try rig.sessions.load()?.userID == "person")
    }

    @Test("an app that is already open ignores a return nobody asked for")
    func openAppIgnoresReturn() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        try rig.approvals.save(userID: "person")
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        #expect(rig.gate.isOpen)
        #expect(!rig.gate.handleOpenURL(BrowserFakes.callback))
        #expect(rig.gate.browser.failure == nil)
        #expect(GateStub.claimRequests == 0)
    }

    @Test("a return to the app that nothing is waiting for signs nobody in and says it expired")
    func browserCallbackWithNothingPending() async throws {
        let rig = Rig()
        GateStub.claim = (200, BrowserFakes.sessionBody)
        rig.gate.start(host: rig.host)
        #expect(rig.gate.handleOpenURL(BrowserFakes.callback), "the person is shown that it expired")
        #expect(rig.gate.browser.failure == .expired)
        #expect(GateStub.claimRequests == 0)
        #expect(rig.gate.decision == .signIn)
        #expect(try rig.sessions.load() == nil)
    }

    @Test("an automation build keeps a browser sign-in without opening the gate's check")
    func browserSignInInAutomationBuild() async throws {
        let rig = Rig(bypass: true)
        GateStub.claim = (200, BrowserFakes.sessionBody)
        rig.gate.start(host: rig.host)
        rig.gate.browser.start()
        rig.gate.browser.handle(BrowserFakes.callback)
        await rig.gate.browser.claimTask?.value
        #expect(try rig.sessions.load()?.userID == "person")
        #expect(rig.gate.currentSession?.userID == "person")
        #expect(rig.gate.signedInRevision == 1)
        #expect(GateStub.profileRequests == 0)
        #expect(rig.gate.isOpen)
    }

    @Test("logged reasons are fixed words that carry no address, id or token")
    func reasonWordsAreFixed() async throws {
        let rig = Rig()
        try rig.seedSession(person)
        GateStub.profile = (200, approvedBody)
        rig.gate.start(host: rig.host)
        await rig.gate.checkAgain()
        let reason = rig.gate.lastReason
        #expect(["approved"].contains(reason))
        for secret in ["person", "access", "refresh", "@"] { #expect(!reason.contains(secret)) }
    }
}

/// Models the app's recording guard as the real one is set: suspend sets it, only resume clears it.
/// (The real `launch()` also clears it as a second guard; the fake does not, so a controller that
/// suspends before launch shows up as a suspended app after it opens.)
@MainActor final class FakeHost: BetaGateHost {
    private(set) var launched = 0, suspended = 0, resumed = 0, refreshed = 0
    private(set) var isSuspended = false
    func launch() { launched += 1 }
    func suspendBetaAccess() { suspended += 1; isSuspended = true }
    func resumeBetaAccess() { resumed += 1; isSuspended = false }
    func refreshEntitlementSnapshot() { refreshed += 1 }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
typealias InviteLog = Counter

/// A Keychain that can be told to fail, to prove errors are not mistaken for "signed out".
final class FlakyKeyStore: KeyStoreProtocol, @unchecked Sendable {
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

/// A scripted Supabase: one answer for the profile read, one for the token refresh.
final class GateStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var profile: (Int, String) = (200, "[]")
    nonisolated(unsafe) static var refresh: (Int, String) = (200, #"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":3600,"user":{"id":"person"}}"#)
    nonisolated(unsafe) static var profileDelay: TimeInterval = 0
    nonisolated(unsafe) static var refreshDelay: TimeInterval = 0
    /// When true, the token refresh waits until `resumeRefresh()` before answering.
    nonisolated(unsafe) static var refreshPaused = false
    nonisolated(unsafe) private static var refreshStartWaiters: [CheckedContinuation<Void, Never>] = []
    nonisolated(unsafe) private static var refreshProceedHandlers: [() -> Void] = []
    /// The site's answer to the app collecting a browser sign-in.
    nonisolated(unsafe) static var claim: (Int, String) = (404, #"{"error":"Not available"}"#)
    nonisolated(unsafe) static var claimDelay: TimeInterval = 0
    /// The website's public answer to "is the service open".
    nonisolated(unsafe) static var service: (Int, String) = (200, #"{"open":false}"#)
    /// When set, the claim succeeds only for exactly this id and secret, as the real site does.
    nonisolated(unsafe) static var claimAccepts: (id: String, secret: String)?
    nonisolated(unsafe) private static var profileCount = 0, refreshCount = 0, claimCount = 0
    nonisolated(unsafe) private static var lastAuthorization: String?
    nonisolated(unsafe) private static var lastClaim: [String: String]?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        profile = (200, "[]")
        refresh = (200, #"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":3600,"user":{"id":"person"}}"#)
        claim = (404, #"{"error":"Not available"}"#); claimAccepts = nil
        service = (200, #"{"open":false}"#)
        profileDelay = 0; refreshDelay = 0; refreshPaused = false
        refreshStartWaiters = []; refreshProceedHandlers = []
        claimDelay = 0; profileCount = 0; refreshCount = 0; claimCount = 0; lastAuthorization = nil; lastClaim = nil
    }

    static func waitForRefreshStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            refreshStartWaiters.append(continuation)
            lock.unlock()
        }
    }

    static func resumeRefresh() {
        lock.lock()
        let handlers = refreshProceedHandlers
        refreshProceedHandlers = []
        lock.unlock()
        handlers.forEach { $0() }
    }
    static var claimRequests: Int { lock.lock(); defer { lock.unlock() }; return claimCount }
    /// The id and secret the app posted, as the site would read them.
    static var lastClaimBody: [String: String]? { lock.lock(); defer { lock.unlock() }; return lastClaim }
    static var profileRequests: Int { lock.lock(); defer { lock.unlock() }; return profileCount }
    static var refreshRequests: Int { lock.lock(); defer { lock.unlock() }; return refreshCount }
    static var lastProfileAuthorization: String? { lock.lock(); defer { lock.unlock() }; return lastAuthorization }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var answer = (204, "")
        var delay: TimeInterval = 0
        Self.lock.lock()
        if path == "/auth/v1/token" {
            Self.refreshCount += 1
            answer = Self.refresh
            delay = Self.refreshDelay
            let paused = Self.refreshPaused
            Self.lock.unlock()
            if paused {
                Self.lock.lock()
                let starters = Self.refreshStartWaiters
                Self.refreshStartWaiters = []
                Self.lock.unlock()
                starters.forEach { $0.resume() }
                let response = answer
                DispatchQueue.global().async { [self] in
                    let gate = DispatchSemaphore(value: 0)
                    Self.lock.lock()
                    Self.refreshProceedHandlers.append { gate.signal() }
                    Self.lock.unlock()
                    gate.wait()
                    deliver(response)
                }
                return
            }
            Self.lock.lock()
        }
        else if path == "/rest/v1/site_profiles" {
            Self.profileCount += 1
            Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
            answer = Self.profile; delay = Self.profileDelay
        } else if path == "/api/app-signin/claim" {
            Self.claimCount += 1
            Self.lastClaim = Self.bodyOf(request)
            let matches = Self.claimAccepts.map { $0.id == Self.lastClaim?["id"] && $0.secret == Self.lastClaim?["secret"] } ?? true
            answer = matches ? Self.claim : (404, #"{"error":"Not available"}"#); delay = Self.claimDelay
        } else if path == "/api/service" {
            answer = Self.service; delay = 0
        }
        Self.lock.unlock()
        let response = answer
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in deliver(response) } }
        else { deliver(response) }
    }

    private func deliver(_ answer: (Int, String)) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func bodyOf(_ request: URLRequest) -> [String: String]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }
}
