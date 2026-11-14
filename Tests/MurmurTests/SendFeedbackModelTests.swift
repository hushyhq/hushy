import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The Send feedback sheet's states: editing, sending, sent, failed with the text kept. Everything it
/// depends on is a fake; nothing is sent.
@Suite("Send feedback sheet", .timeLimit(.minutes(1)))
@MainActor
struct SendFeedbackModelTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(message: String, info: FeedbackAppInfo?)] = []
        var all: [(message: String, info: FeedbackAppInfo?)] { lock.withLock { sent } }
        func add(_ message: String, _ info: FeedbackAppInfo?) { lock.withLock { sent.append((message, info)) } }
    }

    private let info = FeedbackAppInfo(version: "1.4.2", build: "2622", macOS: "15.1.0", model: "Mac14,5")

    private func model(
        account: SendFeedbackAccount = .signedIn(email: "sam@example.com"), outcomes: [FeedbackOutcome] = [.sent], calls: Calls = Calls()
    ) -> (SendFeedbackModel, Calls) {
        let queue = OutcomeQueue(outcomes)
        let model = SendFeedbackModel(account: account, appInfo: { [info] in info }) { message, appInfo in
            calls.add(message, appInfo)
            return queue.next()
        }
        return (model, calls)
    }

    private final class OutcomeQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [FeedbackOutcome]
        init(_ outcomes: [FeedbackOutcome]) { remaining = outcomes }
        func next() -> FeedbackOutcome { lock.withLock { remaining.count > 1 ? remaining.removeFirst() : (remaining.first ?? .failed) } }
    }

    @Test("starts editing, with the version tick on and Send off until there is text")
    func startsEditing() {
        let (model, _) = model()
        #expect(model.phase == .editing)
        #expect(model.includeAppInfo)
        #expect(!model.canSend)
        model.message = "   "
        #expect(!model.canSend)
        model.message = "Hello"
        #expect(model.canSend)
    }

    @Test("a send goes through sending to sent, with the message and the version facts")
    func sends() async {
        let (model, calls) = model()
        model.message = "The pill sticks in Slack."
        await model.submit()
        #expect(model.phase == .sent)
        #expect(calls.all.count == 1)
        #expect(calls.all[0].message == "The pill sticks in Slack.")
        #expect(calls.all[0].info == info)
        #expect(!model.canSend)
    }

    @Test("with the box unticked the request carries no app facts")
    func versionOptOut() async {
        let (model, calls) = model()
        model.message = "Hello"
        model.includeAppInfo = false
        await model.submit()
        #expect(calls.all.count == 1)
        #expect(calls.all[0].info == nil)
    }

    @Test("sending shows while the request is out, and a second press does nothing")
    func sendingState() async {
        let gate = AsyncGate()
        let calls = Calls()
        let model = SendFeedbackModel(account: .signedIn(email: nil), appInfo: { FeedbackAppInfo() }) { message, info in
            calls.add(message, info)
            await gate.wait()
            return .sent
        }
        model.message = "Hello"
        let first = Task { await model.submit() }
        while model.phase != .sending || calls.all.isEmpty { await Task.yield() }
        #expect(!model.canSend)
        await model.submit()
        #expect(calls.all.count == 1)
        await gate.open()
        await first.value
        #expect(model.phase == .sent)
    }

    @Test("a failure keeps the text and the retry sends the same message")
    func failureThenRetry() async {
        let (model, calls) = model(outcomes: [.failed, .sent])
        model.message = "Keep this text"
        await model.submit()
        #expect(model.phase == .failed(.couldNotSend))
        #expect(model.message == "Keep this text")
        #expect(model.canSend)
        await model.submit()
        #expect(model.phase == .sent)
        #expect(calls.all.map(\.message) == ["Keep this text", "Keep this text"])
    }

    @Test("each outcome has its own state and its own sentence")
    func outcomesMapToStates() {
        let pairs: [(FeedbackOutcome, SendFeedbackModel.Phase)] = [
            (.sent, .sent), (.signInNeeded, .failed(.signInNeeded)), (.dailyLimit, .failed(.dailyLimit)),
            (.busyToday, .failed(.busyToday)), (.slowDown, .failed(.slowDown)), (.tooLong, .failed(.tooLong)),
            (.failed, .failed(.couldNotSend)),
        ]
        for (outcome, phase) in pairs { #expect(SendFeedbackModel.phase(for: outcome) == phase) }
        let failures: [SendFeedbackFailure] = [.signInNeeded, .dailyLimit, .busyToday, .slowDown, .tooLong, .couldNotSend]
        #expect(Set(failures.map(SendFeedbackCopy.failure)).count == failures.count)
    }

    @Test("signed out: nothing can be sent, however much is typed")
    func signedOut() async {
        let (model, calls) = model(account: .signedOut)
        model.message = "Hello"
        #expect(!model.isSignedIn)
        #expect(!model.canSend)
        await model.submit()
        #expect(calls.all.isEmpty)
        #expect(model.phase == .editing)
    }

    @Test("over 5,000 characters cannot be sent")
    func tooLong() {
        let (model, _) = model()
        model.message = String(repeating: "a", count: 5000)
        #expect(model.canSend)
        model.message += "a"
        #expect(model.isTooLong)
        #expect(!model.canSend)
    }

    @Test("the words: the reply line names the address, the counter shows near the limit")
    func words() {
        #expect(SendFeedbackCopy.replyLine(email: "sam@example.com") == "We'll reply to sam@example.com.")
        #expect(SendFeedbackCopy.replyLine(email: nil) == "We'll reply to your account email.")
        #expect(SendFeedbackCopy.sent == "Thanks, we read every one.")
        #expect(SendFeedbackCopy.placeholder == "What's working, what isn't?")
        #expect(SendFeedbackCopy.includeInfo == "Include my app version and Mac model")
        #expect(!SendFeedbackCopy.showsCounter(100))
        #expect(SendFeedbackCopy.showsCounter(4600))
    }
}

/// Holds a fake request open until the test lets it finish.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
