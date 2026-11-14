import MurmurCore
import Observation

/// Why a send did not go through. Each has its own sentence in `SendFeedbackCopy`; the person's text is kept.
enum SendFeedbackFailure: Equatable {
    case signInNeeded
    case dailyLimit
    case busyToday
    case slowDown
    case tooLong
    case couldNotSend
}

/// Who is sending: the signed-in account (its address is where we reply), or nobody.
enum SendFeedbackAccount: Equatable {
    case signedOut
    /// `email` is nil only when the session carries none; the site still replies to the account's address.
    case signedIn(email: String?)
}

/// The feedback sheet's state: editing, sending, sent, or failed with the text kept for a retry.
/// Everything outside it (the session, the request, the clock) is passed in, so a test drives it on fakes.
@MainActor @Observable
final class SendFeedbackModel {
    enum Phase: Equatable {
        case editing
        case sending
        case sent
        case failed(SendFeedbackFailure)
    }

    var message = ""
    /// "Include my app version and Mac model", on by default.
    var includeAppInfo = true
    private(set) var phase: Phase = .editing
    let account: SendFeedbackAccount

    private let send: @Sendable (_ message: String, _ appInfo: FeedbackAppInfo?) async -> FeedbackOutcome
    private let appInfo: @Sendable () -> FeedbackAppInfo

    /// - Parameters:
    ///   - sendMessage: gets a usable session and posts; returns how it ended. See `live(client:session:)`.
    init(account: SendFeedbackAccount,
         appInfo: @escaping @Sendable () -> FeedbackAppInfo = { FeedbackAppInfo.current() },
         sendMessage: @escaping @Sendable (String, FeedbackAppInfo?) async -> FeedbackOutcome) {
        self.account = account
        self.appInfo = appInfo
        self.send = sendMessage
    }

    /// The model the app uses: a fresh access token from the session keeper on every send.
    static func live(account: SendFeedbackAccount, fallback: AccountSession?, client: FeedbackClient = FeedbackClient()) -> SendFeedbackModel {
        SendFeedbackModel(account: account) { message, info in
            do {
                guard let session = try await AccountSessionKeeper.shared.usable(fallback: fallback) else { return .signInNeeded }
                return await client.send(message: message, appInfo: info, accessToken: session.accessToken)
            } catch AccountSessionError.unavailable {
                return .failed
            } catch {
                return .signInNeeded
            }
        }
    }

    var characterCount: Int { FeedbackLimits.characterCount(message) }
    var isTooLong: Bool { characterCount > FeedbackLimits.maxCharacters }
    var isSignedIn: Bool { account != .signedOut }
    var canSend: Bool {
        isSignedIn && phase != .sending && phase != .sent && characterCount > 0 && !isTooLong
    }

    /// Sends the text. A second press while one is in flight does nothing; after a failure the same call retries.
    func submit() async {
        guard canSend else { return }
        phase = .sending
        let info = includeAppInfo ? appInfo() : nil
        let outcome = await send(message, info)
        guard !Task.isCancelled else { phase = .editing; return }
        phase = Self.phase(for: outcome)
    }

    static func phase(for outcome: FeedbackOutcome) -> Phase {
        switch outcome {
        case .sent: .sent
        case .signInNeeded: .failed(.signInNeeded)
        case .dailyLimit: .failed(.dailyLimit)
        case .busyToday: .failed(.busyToday)
        case .slowDown: .failed(.slowDown)
        case .tooLong: .failed(.tooLong)
        case .failed: .failed(.couldNotSend)
        }
    }
}
