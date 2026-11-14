import AppKit
import MurmurCore
import Observation
import os

/// One compile-time switch for a later public build: -D HUSHY_DISABLE_BETA_GATE.
///
/// The automation bypass (a disposable home folder, the test bundle, the eval tool, snapshots)
/// exists only in builds made for automation: a debug build, or a release build compiled with
/// -Xswiftc -DHUSHY_AUTOMATION_BUILD. `scripts/build-app.sh` passes neither, so the app that
/// ships has the gate on and no bypass, whatever the environment or process name says.
@MainActor enum BetaGateBuild {
    #if HUSHY_DISABLE_BETA_GATE
    static let enabled = false
    #else
    static let enabled = true
    #endif

    static var buildAllowsAutomationBypass: Bool {
        #if DEBUG || HUSHY_AUTOMATION_BUILD
        true
        #else
        false
        #endif
    }

    static var bypassesAutomation: Bool {
        BetaGateAutomation.bypasses(
            buildAllowsBypass: buildAllowsAutomationBypass,
            snapshotRequested: Snapshots.requestedDirectory != nil,
            bundlePath: Bundle.main.bundlePath,
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment,
            temporaryDirectory: FileManager.default.temporaryDirectory)
    }
}

/// What the gate asks of the app around it.
@MainActor protocol BetaGateHost: AnyObject {
    func launch()
    func suspendBetaAccess()
    func resumeBetaAccess()
    func refreshEntitlementSnapshot()
    /// A sign-in was accepted: work waiting for an account (model downloads) can go on.
    func accountSignedIn()
}

extension BetaGateHost {
    func accountSignedIn() {}
}

extension AppModel: BetaGateHost {}

/// Everything the gate touches outside itself, so tests can run it on fakes.
struct BetaGateDependencies {
    var keeper: AccountSessionKeeper
    var approvals: BetaApprovalStore
    var client: @MainActor () -> AccountClient?
    var clearEntitlement: @MainActor () -> Void
    var applyInvite: @Sendable (AccountSession, AccountClient, @escaping @Sendable () async -> Bool) async -> BetaInviteOutcome
    var browser: BrowserSignInDependencies
    var bypass: Bool
    var dailyCheck: Bool
    /// Where the last answer to "is the service open?" is kept: while it is, every signed-in
    /// account has Pro.
    var openService: OpenServiceStore = OpenServiceStore()

    @MainActor static func live() -> BetaGateDependencies {
        BetaGateDependencies(
            keeper: .shared,
            approvals: BetaApprovalStore(),
            client: { AccountConfiguration().map { AccountClient(configuration: $0) } },
            clearEntitlement: { try? AccountEntitlementStore().clear() },
            applyInvite: { session, client, stillCurrent in
                await BetaInviteApplier().apply(session: session, source: client, stillCurrent: stillCurrent)
            },
            browser: .live(),
            // No Hushy services in this build (built from source): there is no account to sign in
            // to, so the gate stays open and dictation works with no account.
            bypass: !BetaGateBuild.enabled || !HushyServices.current.isOfficial || BetaGateBuild.bypassesAutomation,
            dailyCheck: true)
    }
}

@MainActor @Observable
final class BetaGateController {
    private(set) var decision: BetaGateDecision = .signIn
    private(set) var email: String?
    /// True while an approval check is running. The screens show a spinner and disable buttons.
    private(set) var isChecking = false
    /// The fixed word for the last change of `decision`. Logged; never an address, id or token.
    private(set) var lastReason = "launch"
    private(set) var inviteTask: Task<Void, Never>?
    private(set) var inviteOutcome: BetaInviteOutcome?
    /// Signing in through the website: the one way in. The screens read its state and start it.
    let browser: BrowserSignIn
    /// Bumped each time a sign-in is accepted, so Settings can pick the new account up.
    private(set) var signedInRevision = 0

    @ObservationIgnored private let deps: BetaGateDependencies
    @ObservationIgnored private var session: AccountSession?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inviteID = UUID()
    @ObservationIgnored private var launched = false
    @ObservationIgnored private weak var host: (any BetaGateHost)?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var inFlightGeneration = 0
    @ObservationIgnored private var inFlightID = UUID()
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "beta-gate")

    init(dependencies: BetaGateDependencies = .live()) {
        deps = dependencies
        browser = BrowserSignIn(client: dependencies.client, dependencies: dependencies.browser)
        browser.onSession = { [weak self] in self?.completeBrowserSignIn($0) }
    }

    /// The account signed in on this run, as the gate knows it.
    var currentSession: AccountSession? { session }

    /// Hands an address the system opened in the app to the browser sign-in. True when the person
    /// should be shown something. An app that is already open with no sign-in under way ignores it.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        if isOpen && !browser.isActive { return false }
        return browser.handle(url)
    }

    private func completeBrowserSignIn(_ value: AccountSession) {
        if deps.bypass {
            // An automation build never closes its gate; it only keeps the account for Settings.
            try? deps.keeper.store.save(value)
            session = value
            email = value.email
            signedInRevision += 1
            host?.accountSignedIn()
        } else {
            signedIn(value)
        }
    }

    var client: AccountClient? { deps.client() }
    var isOpen: Bool { decision == .open }

    func start(host: any BetaGateHost) {
        self.host = host
        guard !deps.bypass else { transition(.open, "bypass"); open(); return }
        let stored = loadStored()
        session = stored.session
        email = stored.session?.email
        let approved = try? deps.approvals.approvedUserID()
        if stored.unreadable {
            transition(.couldNotCheck, "keychain-unreadable")
        } else {
            transition(BetaGateDecision.resolve(session: session, approvedUserID: approved, check: .notChecked), session == nil ? "no-session" : "launch")
        }
        if isOpen { open() }
        if session != nil || stored.unreadable { startCheck() }
        guard deps.dailyCheck else { return }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard let self else { return }
                if self.session != nil { await self.checkAgain() }
            }
        }
    }

    func signedIn(_ value: AccountSession) {
        generation += 1
        inviteID = UUID()
        inviteOutcome = nil
        if session?.userID != value.userID { try? deps.approvals.clear() }
        // A Keychain that will not save the session must not lock the person out: keep it in
        // memory, check it, and let them in for this run. They sign in again next launch.
        do { try deps.keeper.store.save(value) }
        catch { log.error("gate: could not save the session; keeping it in memory") }
        session = value
        email = value.email
        signedInRevision += 1
        host?.accountSignedIn()
        transition(.couldNotCheck, "signed-in")
        startCheck()
    }

    func signOut() {
        generation += 1
        inviteID = UUID()
        inviteOutcome = nil
        inFlight?.cancel()
        let old = session
        deps.keeper.forget()
        try? deps.approvals.clear()
        deps.clearEntitlement()
        session = nil
        email = nil
        // Signed out means no Pro from the open service either.
        host?.refreshEntitlementSnapshot()
        transition(.signIn, "signed-out")
        suspendIfLaunched()
        if let old, let client { Task { try? await client.signOut(old.accessToken) } }
    }

    /// Runs one approval check, or joins the one already running for this account.
    func checkAgain() async { await startCheck().value }

    @discardableResult
    private func startCheck() -> Task<Void, Never> {
        if let running = inFlight, inFlightGeneration == generation { return running }
        let stale = inFlight
        stale?.cancel()
        let id = UUID()
        let requested = generation
        isChecking = true
        let task = Task { [weak self] in
            await stale?.value
            guard let self else { return }
            await self.runCheck(generation: requested)
            self.finishCheck(id)
        }
        inFlight = task
        inFlightGeneration = requested
        inFlightID = id
        return task
    }

    private func finishCheck(_ id: UUID) {
        guard inFlightID == id else { return }
        inFlight = nil
        isChecking = false
    }

    /// Suspending an app that never launched would leave its recording guard set when it launches
    /// later; there is nothing running to suspend before that.
    private func suspendIfLaunched() {
        if launched { host?.suspendBetaAccess() }
    }

    private func runCheck(generation requested: Int) async {
        guard !Task.isCancelled, generation == requested else { return }
        // The Keychain is the truth: another part of the app may have renewed the tokens since
        // this one loaded them. A read error is "could not check", never "signed out".
        let stored = loadStored()
        if let loaded = stored.session, session == nil || session?.userID == loaded.userID {
            session = loaded
            email = loaded.email ?? email
        }
        guard let current = session else {
            if stored.unreadable { transition(.couldNotCheck, "keychain-unreadable") }
            else { transition(.signIn, "no-session") }
            return
        }
        guard let client else {
            let approved = try? deps.approvals.approvedUserID()
            transition(BetaGateDecision.resolve(session: current, approvedUserID: approved, check: .failed), "no-configuration")
            return
        }
        let (checked, result) = await BetaApprovalVerifier(openService: deps.openService).check(session: current, client: client, keeper: deps.keeper)
        guard !Task.isCancelled, generation == requested, session?.userID == checked.userID else { return }
        if result == .sessionRefused {
            try? deps.keeper.store.clear()
            session = nil
            email = nil
        } else {
            session = checked
            email = checked.email ?? email
        }
        switch result {
        case .approved: try? deps.approvals.save(userID: checked.userID)
        case .notApproved: try? deps.approvals.clear()
        default: break
        }
        // Read after the await: another answer may have opened the app while this one ran.
        let prior = (try? deps.approvals.approvedUserID()) ?? (isOpen ? checked.userID : nil)
        let wasOpen = isOpen
        transition(BetaGateDecision.resolve(session: checked, approvedUserID: prior, check: result), Self.reason(for: result))
        if isOpen {
            if launched { if !wasOpen { host?.resumeBetaAccess() } }
            else { open() }
        } else { suspendIfLaunched() }
        // The check may have heard a new answer about the service being open, which decides Pro.
        host?.refreshEntitlementSnapshot()
        if result == .approved { applyInvite(for: checked, generation: requested) }
    }

    /// Reads this account's own invite code and redeems it. Runs beside opening the app, never in
    /// front of it. Only the outcome is logged, never the code.
    private func applyInvite(for checked: AccountSession, generation requested: Int) {
        guard let client else { return }
        inviteID = UUID()
        let id = inviteID
        inviteOutcome = nil
        let stillCurrent: @Sendable () async -> Bool = { [weak self] in
            await self?.isCurrent(userID: checked.userID, generation: requested) ?? false
        }
        let apply = deps.applyInvite
        inviteTask = Task { [weak self] in
            let outcome = await apply(checked, client, stillCurrent)
            guard let self, self.inviteID == id,
                  self.isCurrent(userID: checked.userID, generation: requested) else { return }
            self.inviteOutcome = outcome
            self.log.info("invite apply: \(String(describing: outcome), privacy: .public)")
            if case .applied = outcome { self.host?.refreshEntitlementSnapshot() }
        }
    }

    private func isCurrent(userID: String, generation requested: Int) -> Bool {
        generation == requested && session?.userID == userID
    }

    private func loadStored() -> (session: AccountSession?, unreadable: Bool) {
        do { return (try deps.keeper.store.load(), false) }
        catch { return (nil, true) }
    }

    private func transition(_ new: BetaGateDecision, _ reason: String) {
        decision = new
        lastReason = reason
        log.info("gate decision=\(String(describing: new), privacy: .public) reason=\(reason, privacy: .public)")
    }

    private static func reason(for result: BetaApprovalCheck) -> String {
        switch result {
        case .approved: "approved"
        case .notApproved: "not-approved"
        case .failed: "check-failed"
        case .sessionRefused: "session-refused"
        case .notChecked: "not-checked"
        }
    }

    private func open() {
        decision = .open
        if !launched { launched = true; host?.launch() }
    }
}
