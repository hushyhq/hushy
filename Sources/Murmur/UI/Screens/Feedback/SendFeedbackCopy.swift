import MurmurCore

/// Every word of the Send feedback sheet and its sidebar button, in one place so a test (and the founder) can read them.
enum SendFeedbackCopy {
    static let buttonHelp = "Send feedback"
    static let title = "Send feedback"
    static let intro = "It goes straight to the people who build Hushy."
    static let placeholder = "What's working, what isn't?"
    static let includeInfo = "Include my app version and Mac model"
    static let includeInfoDetail = "Never your dictations, your history or the apps you use."
    static let send = "Send"
    static let retry = "Try again"
    static let sending = "Sending…"
    static let sent = "Thanks, we read every one."
    static let done = "Done"
    static let cancel = "Cancel"
    static let openAccount = "Open Account settings"
    static let signedOut = "Sign in to send feedback. Hushy uses your account email so we can reply to you."

    static func replyLine(email: String?) -> String {
        guard let email, !email.isEmpty else { return "We'll reply to your account email." }
        return "We'll reply to \(email)."
    }

    static func counter(_ count: Int) -> String {
        "\(count) / \(FeedbackLimits.maxCharacters)"
    }

    /// Shown when the counter matters: close to the limit, or over it.
    static func showsCounter(_ count: Int) -> Bool { count >= FeedbackLimits.maxCharacters - 500 }

    static func failure(_ failure: SendFeedbackFailure) -> String {
        switch failure {
        case .signInNeeded: "Your sign-in needs refreshing. Sign in again in Settings → Account, then send this."
        case .dailyLimit: "You've sent \(FeedbackLimits.perDay) today. Please try again tomorrow."
        case .busyToday: "Feedback is very busy today. Please try again tomorrow."
        case .slowDown: "That was a little fast. Try again in a minute."
        case .tooLong: "That's too long to send. Please keep it under \(FeedbackLimits.maxCharacters) characters."
        case .couldNotSend: "Couldn't send that. Check your connection and try again."
        }
    }
}
