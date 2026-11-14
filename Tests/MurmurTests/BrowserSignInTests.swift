import Foundation
import Testing
@testable import Murmur
@testable import MurmurCore

/// A clock the test owns. `sleep` waits until the test calls `advance`, so no test depends on the
/// wall clock. Cancelling a sleeper ends it, as a real sleep would.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Duration = .zero
    private var waiters: [UUID: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]

    /// How many sleeps are waiting right now.
    var waiting: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    /// Returns once `count` sleeps are waiting, so time is only advanced after the timer under test
    /// has started its sleep (a timer starts on its own task, a moment after `start()` returns).
    func untilWaiting(_ count: Int = 1) async {
        while waiting < count { await Task.yield() }
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (now + duration, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleep whose time has come.
    func advance(by duration: Duration) {
        lock.lock()
        now += duration
        let due = waiters.filter { $0.value.deadline <= now }
        for key in due.keys { waiters.removeValue(forKey: key) }
        lock.unlock()
        for waiter in due.values { waiter.continuation.resume() }
    }
}

/// What the browser sign-in needs from outside itself, scripted: which address was opened, which
/// secrets it was given, and the id the browser would come back with.
@MainActor final class BrowserFakes {
    static let id = "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U-_"
    static let callback = URL(string: "hushy://sign-in?id=\(id)")!
    static let sessionBody = #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3595,"user":{"id":"person","email":"person@example.com"}}"#

    /// 43 characters each, so they pass the shape check; `a…`, `b…`, `c…` in the order handed out.
    let secrets = ["a", "b", "c", "d"].map { try! PKCEChallenge(verifier: String(repeating: $0, count: 43)) }
    private(set) var opened: [URL] = []
    private var made = 0
    var lifetime: Duration = .seconds(900)
    /// The lapse's clock: nothing lapses until a test advances it.
    let sleeper = ManualSleeper()

    var dependencies: BrowserSignInDependencies {
        BrowserSignInDependencies(
            open: { [weak self] url in self?.opened.append(url) },
            makeSecret: { [weak self] in
                guard let self else { return PKCEChallenge.generate() }
                defer { made += 1 }
                return secrets[made]
            },
            lifetime: lifetime,
            sleep: { [sleeper] in try await sleeper.sleep($0) })
    }
}

@MainActor
@Suite("Browser sign-in flow", .serialized, .timeLimit(.minutes(1)))
struct BrowserSignInTests {
    @MainActor final class Rig {
        let fakes = BrowserFakes()
        let received = SessionLog()
        let flow: BrowserSignIn

        init(configured: Bool = true, lifetime: Duration = .seconds(900)) {
            ClaimStub.reset()
            fakes.lifetime = lifetime
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ClaimStub.self]
            let client = AccountClient(
                configuration: AccountConfiguration(url: URL(string: "https://example.supabase.co")!, anonKey: "public"),
                transport: URLSession(configuration: config))
            flow = BrowserSignIn(client: { configured ? client : nil }, dependencies: fakes.dependencies)
            let received = received
            flow.onSession = { received.add($0) }
        }

        /// The site as it really answers: a session only for the right id with the right secret.
        func siteAccepts(secret index: Int = 0, id: String = BrowserFakes.id) {
            ClaimStub.claim = (200, BrowserFakes.sessionBody)
            ClaimStub.accept = (id, fakes.secrets[index].verifier)
        }
    }

    @MainActor final class SessionLog {
        private(set) var sessions: [AccountSession] = []
        func add(_ session: AccountSession) { sessions.append(session) }
    }

    static let strayCallback = URL(string: "hushy://sign-in?id=Z9y8X7w6V5u4T3s2R1q0P9o8N7m6L5k4J3i2H1g0F-_")!

    @Test("starting opens the site's sign-in page for a fresh secret and shows the waiting state")
    func startOpensThePage() {
        let rig = Rig()
        rig.flow.start()
        #expect(rig.flow.phase == .waiting)
        #expect(rig.flow.failure == nil)
        #expect(rig.fakes.opened.map(\.absoluteString) == ["https://tryhushy.com/login?app=\(rig.fakes.secrets[0].challenge)"])
        #expect(!rig.fakes.opened[0].absoluteString.contains(rig.fakes.secrets[0].verifier))
    }

    @Test("coming back with the id claims the session with the secret kept in memory, once")
    func callbackClaims() async {
        let rig = Rig()
        rig.siteAccepts()
        rig.flow.start()
        #expect(rig.flow.handle(BrowserFakes.callback))
        #expect(rig.flow.phase == .claiming)
        await rig.flow.claimTask?.value
        #expect(ClaimStub.lastClaimBody == ["id": BrowserFakes.id, "secret": rig.fakes.secrets[0].verifier])
        #expect(rig.flow.phase == .idle)
        #expect(rig.received.sessions.map(\.userID) == ["person"])
        #expect(rig.received.sessions.first?.email == "person@example.com")
    }

    @Test("a return that nothing is waiting for makes no request and no session, and says it expired")
    func nothingPending() async {
        let rig = Rig()
        rig.siteAccepts()
        #expect(rig.flow.handle(BrowserFakes.callback), "the person is shown the notice")
        #expect(rig.flow.claimTask == nil)
        #expect(ClaimStub.claimRequests == 0)
        #expect(rig.received.sessions.isEmpty)
        #expect(rig.flow.phase == .idle)
        #expect(rig.flow.failure == .expired)
    }

    @Test("a second return for the same attempt is ignored, during the claim and after it")
    func secondCallback() async {
        let rig = Rig()
        rig.siteAccepts()
        rig.flow.start()
        #expect(rig.flow.handle(BrowserFakes.callback))
        #expect(!rig.flow.handle(BrowserFakes.callback))
        await rig.flow.claimTask?.value
        rig.flow.handle(BrowserFakes.callback)
        #expect(ClaimStub.claimRequests == 1)
        #expect(rig.received.sessions.count == 1)
    }

    @Test("an address that is not the app's callback is not ours and leaves the attempt waiting")
    func foreignAddressIsIgnored() {
        let rig = Rig()
        rig.flow.start()
        for address in ["hushy://note/7", "hushy://sign-in?id=short", "https://tryhushy.com/login", "hushy://sign-in?token=x"] {
            #expect(!rig.flow.handle(URL(string: address)!))
        }
        #expect(rig.flow.phase == .waiting)
        #expect(rig.flow.failure == nil)
        #expect(ClaimStub.claimRequests == 0)
    }

    @Test("cancel forgets the secret: a later return makes no claim and the screen goes back to sign-in")
    func cancelForgets() async {
        let rig = Rig()
        rig.siteAccepts()
        rig.flow.start()
        rig.flow.cancel()
        #expect(rig.flow.phase == .idle)
        rig.flow.handle(BrowserFakes.callback)
        #expect(ClaimStub.claimRequests == 0)
        #expect(rig.received.sessions.isEmpty)
    }

    @Test("cancel during the claim signs the claimed session out instead of dropping it")
    func cancelDuringClaim() async {
        let rig = Rig()
        rig.siteAccepts()
        ClaimStub.holdClaims = true
        rig.flow.start()
        rig.flow.handle(BrowserFakes.callback)
        await ClaimStub.waitForHeldClaim()
        rig.flow.cancel()
        ClaimStub.releaseHeldClaims()
        await rig.flow.claimTask?.value
        await rig.flow.discardTask?.value
        #expect(rig.flow.phase == .idle)
        #expect(rig.received.sessions.isEmpty)
        #expect(ClaimStub.logoutRequests == 1)
        #expect(ClaimStub.lastLogoutAuthorization == "Bearer access-1")
        #expect(ClaimStub.lastLogoutQuery == "scope=local", "this session only, not every device")
    }

    @Test("a lapse that fires during the claim signs the claimed session out too, this session only")
    func lapseDuringClaim() async {
        let rig = Rig(lifetime: .seconds(900))
        rig.siteAccepts()
        ClaimStub.holdClaims = true
        rig.flow.start()
        let timer = rig.flow.lapseTask
        await rig.fakes.sleeper.untilWaiting()
        rig.flow.handle(BrowserFakes.callback)
        await ClaimStub.waitForHeldClaim()
        #expect(rig.flow.phase == .claiming)
        rig.fakes.sleeper.advance(by: .seconds(900))
        await timer?.value
        #expect(rig.flow.phase == .idle)
        ClaimStub.releaseHeldClaims()
        await rig.flow.claimTask?.value
        await rig.flow.discardTask?.value
        #expect(rig.received.sessions.isEmpty)
        #expect(ClaimStub.logoutRequests == 1)
        #expect(ClaimStub.lastLogoutQuery == "scope=local")
    }

    @Test("a rate-limited return is treated like a refused one: the attempt, its secret and its timer survive")
    func rateLimitedReturnKeepsTheAttempt() async throws {
        let rig = Rig()
        ClaimStub.claim = (429, #"{"error":"Please try again in a minute."}"#)
        rig.flow.start()
        for _ in 0..<3 {
            #expect(rig.flow.handle(Self.strayCallback))
            await rig.flow.claimTask?.value
            #expect(rig.flow.phase == .waiting)
        }
        #expect(rig.received.sessions.isEmpty)
        // The real return still works once the burst is over.
        rig.siteAccepts()
        rig.flow.handle(BrowserFakes.callback)
        await rig.flow.claimTask?.value
        #expect(rig.received.sessions.map(\.userID) == ["person"])
    }

    @Test("a rate limit does not extend the wait: the attempt still lapses on time")
    func rateLimitedReturnStillLapses() async {
        let rig = Rig(lifetime: .seconds(900))
        ClaimStub.claim = (429, "")
        rig.flow.start()
        let timer = rig.flow.lapseTask
        await rig.fakes.sleeper.untilWaiting()
        rig.flow.handle(Self.strayCallback)
        await rig.flow.claimTask?.value
        rig.fakes.sleeper.advance(by: .seconds(899))
        #expect(rig.flow.phase == .waiting)
        rig.fakes.sleeper.advance(by: .seconds(1))
        await timer?.value
        #expect(rig.flow.phase == .idle)
    }

    @Test("starting again during the claim does the same: the old session is signed out")
    func restartDuringClaim() async {
        let rig = Rig()
        rig.siteAccepts()
        ClaimStub.holdClaims = true
        rig.flow.start()
        rig.flow.handle(BrowserFakes.callback)
        await ClaimStub.waitForHeldClaim()
        rig.flow.start()
        ClaimStub.releaseHeldClaims()
        await rig.flow.claimTask?.value
        await rig.flow.discardTask?.value
        #expect(rig.flow.phase == .waiting)
        #expect(rig.received.sessions.isEmpty)
        #expect(ClaimStub.logoutRequests == 1)
    }

    @Test("starting again replaces the pending secret, and only the new one can be claimed")
    func startAgainReplacesSecret() async {
        let rig = Rig()
        rig.siteAccepts(secret: 1)
        rig.flow.start()
        rig.flow.start()
        #expect(rig.fakes.opened.count == 2)
        #expect(rig.fakes.opened[0] != rig.fakes.opened[1])
        #expect(rig.flow.phase == .waiting)
        rig.flow.handle(BrowserFakes.callback)
        await rig.flow.claimTask?.value
        #expect(ClaimStub.lastClaimBody?["secret"] == rig.fakes.secrets[1].verifier)
        #expect(rig.received.sessions.count == 1)
    }

    @Test("a refused return does not burn the live attempt: the secret and the wait are kept and the right return still signs in")
    func refusedReturnKeepsTheAttempt() async {
        let rig = Rig()
        rig.siteAccepts()
        rig.flow.start()
        // A stray page, or the first tab after "Start again": well formed, but not this attempt's id.
        #expect(rig.flow.handle(Self.strayCallback))
        await rig.flow.claimTask?.value
        #expect(rig.flow.phase == .waiting)
        #expect(rig.flow.failure == .expired)
        #expect(rig.received.sessions.isEmpty)
        #expect(rig.flow.handle(BrowserFakes.callback))
        await rig.flow.claimTask?.value
        #expect(ClaimStub.claimRequests == 2)
        #expect(ClaimStub.lastClaimBody?["secret"] == rig.fakes.secrets[0].verifier)
        #expect(rig.flow.phase == .idle)
        #expect(rig.flow.failure == nil)
        #expect(rig.received.sessions.map(\.userID) == ["person"])
    }

    @Test("the site checks the secret: a claim made with the wrong one is refused and nothing is handed on")
    func wrongSecretIsRefused() async {
        let rig = Rig()
        rig.siteAccepts(secret: 3)
        rig.flow.start()
        rig.flow.handle(BrowserFakes.callback)
        await rig.flow.claimTask?.value
        #expect(rig.received.sessions.isEmpty)
        #expect(rig.flow.phase == .waiting)
    }

    @Test("the attempt still lapses on time after a refused return")
    func lapseSurvivesRefusal() async {
        let rig = Rig(lifetime: .seconds(900))
        rig.siteAccepts()
        rig.flow.start()
        let timer = rig.flow.lapseTask
        await rig.fakes.sleeper.untilWaiting()
        rig.flow.handle(Self.strayCallback)
        await rig.flow.claimTask?.value
        #expect(rig.flow.phase == .waiting)
        #expect(rig.fakes.sleeper.waiting == 1, "the same timer is still running")
        rig.fakes.sleeper.advance(by: .seconds(899))
        #expect(rig.flow.phase == .waiting)
        rig.fakes.sleeper.advance(by: .seconds(1))
        await timer?.value
        #expect(rig.flow.phase == .idle)
    }

    @Test("a claim that fails for any other reason ends the attempt with a plain failure and hands nothing on")
    func claimFailsOtherwise() async {
        let rig = Rig()
        ClaimStub.claim = (500, "")
        rig.flow.start()
        rig.flow.handle(BrowserFakes.callback)
        await rig.flow.claimTask?.value
        #expect(rig.flow.phase == .idle)
        #expect(rig.flow.failure == .failed)
        #expect(rig.received.sessions.isEmpty)
        #expect(ClaimStub.claimRequests == 1)
    }

    @Test("starting clears an earlier failure")
    func startClearsFailure() async {
        let rig = Rig()
        ClaimStub.claim = (500, "")
        rig.flow.start()
        rig.flow.handle(BrowserFakes.callback)
        await rig.flow.claimTask?.value
        #expect(rig.flow.failure == .failed)
        rig.flow.start()
        #expect(rig.flow.failure == nil)
        #expect(rig.flow.phase == .waiting)
    }

    @Test("without a configured account nothing is opened and the person is told sign-in is unavailable")
    func unavailable() {
        let rig = Rig(configured: false)
        rig.flow.start()
        #expect(rig.flow.phase == .idle)
        #expect(rig.flow.failure == .unavailable)
        #expect(rig.fakes.opened.isEmpty)
    }

    @Test("if the person never comes back the attempt lapses by itself and nothing is stuck")
    func lapses() async {
        let rig = Rig(lifetime: .seconds(900))
        rig.flow.start()
        let timer = rig.flow.lapseTask
        await rig.fakes.sleeper.untilWaiting()
        #expect(rig.flow.phase == .waiting)
        rig.fakes.sleeper.advance(by: .seconds(899))
        #expect(rig.flow.phase == .waiting)
        rig.fakes.sleeper.advance(by: .seconds(1))
        await timer?.value
        #expect(rig.flow.phase == .idle)
        #expect(rig.flow.failure == nil)
        rig.flow.handle(BrowserFakes.callback)
        #expect(ClaimStub.claimRequests == 0)
        rig.flow.start()
        #expect(rig.flow.phase == .waiting)
    }

    @Test("an old attempt's timer does not end a newer attempt")
    func oldTimerDoesNotEndNewAttempt() async {
        let rig = Rig(lifetime: .seconds(900))
        rig.flow.start()
        await rig.fakes.sleeper.untilWaiting()
        rig.fakes.sleeper.advance(by: .seconds(800))
        rig.flow.start()
        let second = rig.flow.lapseTask
        await rig.fakes.sleeper.untilWaiting()
        #expect(rig.fakes.sleeper.waiting == 1, "only the new attempt has a timer")
        // The first attempt's time (900 s) has now passed; the second's (1700 s) has not.
        rig.fakes.sleeper.advance(by: .seconds(200))
        #expect(rig.flow.phase == .waiting)
        rig.fakes.sleeper.advance(by: .seconds(700))
        await second?.value
        #expect(rig.flow.phase == .idle)
    }

}

/// The site's endpoints, scripted. Separate from the gate's stub so the two suites, which run
/// side by side, cannot reset each other's answers. Like the real site, a claim gets a session
/// only when the id and the secret are the ones it was told to expect.
final class ClaimStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: (Int, String) = (404, #"{"error":"Not available"}"#)
    nonisolated(unsafe) private static var accepted: (id: String, secret: String)?
    nonisolated(unsafe) private static var holding = false
    nonisolated(unsafe) private static var held: [() -> Void] = []
    nonisolated(unsafe) private static var count = 0, logouts = 0
    nonisolated(unsafe) private static var body: [String: String]?
    nonisolated(unsafe) private static var logoutAuthorization: String?
    nonisolated(unsafe) private static var logoutScope: String?

    static var claim: (Int, String) {
        get { lock.lock(); defer { lock.unlock() }; return answer }
        set { lock.lock(); answer = newValue; lock.unlock() }
    }
    /// When set, the 200 answer goes only to a claim with exactly this id and secret.
    static var accept: (id: String, secret: String)? {
        get { lock.lock(); defer { lock.unlock() }; return accepted }
        set { lock.lock(); accepted = newValue; lock.unlock() }
    }
    /// While true, a claim is received but not answered until `releaseHeldClaims`.
    static var holdClaims: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holding }
        set { lock.lock(); holding = newValue; lock.unlock() }
    }
    /// Returns once a claim has arrived and is being held.
    static func waitForHeldClaim() async {
        while heldCount == 0 { await Task.yield() }
    }
    private static var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    static func releaseHeldClaims() {
        lock.lock()
        holding = false
        let release = held
        held = []
        lock.unlock()
        release.forEach { $0() }
    }
    static var claimRequests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var logoutRequests: Int { lock.lock(); defer { lock.unlock() }; return logouts }
    static var lastLogoutAuthorization: String? { lock.lock(); defer { lock.unlock() }; return logoutAuthorization }
    static var lastLogoutQuery: String? { lock.lock(); defer { lock.unlock() }; return logoutScope }
    static var lastClaimBody: [String: String]? { lock.lock(); defer { lock.unlock() }; return body }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        answer = (404, #"{"error":"Not available"}"#); accepted = nil; holding = false; held = []; count = 0; logouts = 0; body = nil; logoutAuthorization = nil; logoutScope = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let sent = path == "/api/app-signin/claim" ? GateStub.bodyOf(request) : nil
        let reply: (Int, String), hold: Bool
        Self.lock.lock()
        if path == "/api/app-signin/claim" {
            Self.count += 1
            Self.body = sent
            let matches = Self.accepted.map { $0.id == sent?["id"] && $0.secret == sent?["secret"] } ?? true
            reply = matches ? Self.answer : (404, #"{"error":"Not available"}"#)
            hold = Self.holding
        } else if path == "/auth/v1/logout" {
            Self.logouts += 1
            Self.logoutAuthorization = request.value(forHTTPHeaderField: "Authorization")
            Self.logoutScope = request.url?.query
            reply = (204, ""); hold = false
        } else { reply = (404, ""); hold = false }
        let finish = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if hold { Self.held.append(finish) }
        Self.lock.unlock()
        if !hold { finish() }
    }
    override func stopLoading() {}
}
