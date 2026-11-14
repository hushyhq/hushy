import Foundation

/// The words around "Tune Hushy to your voice", in one place so they can only claim what a run
/// does. A run: has you read four sentences with your own words in them, shows how many it got
/// right and which words it misheard (each can be added to your dictionary), checks whether your
/// whisper is too quiet for your microphone, and, on Pro, can learn your voice for meeting
/// notes. It does NOT change how Hushy transcribes: the measured winner is not applied to
/// dictation (a separate product decision).
enum TuneCopy {
    /// Closing onboarding step.
    static let onboardingOffer =
        "Read four short sentences with your own words in them. Hushy shows what it misheard, so you can add those words to your dictionary, and checks your microphone is loud enough for whispering. About 30 seconds, optional, also in Settings."

    /// Settings → Advanced row.
    static let settingsRowDetail = "Read 4 short sentences to see which words Hushy mishears and whether your mic is loud enough."

    /// Under the Tune screen's title.
    static let intro = "About 30 seconds. Shows which of your words Hushy mishears and whether your mic is loud enough for whispering."

    static let stepRead = "Read 4 short sentences out loud, in your normal voice."
    static let stepRoom = "Stay quiet for 2 seconds so Hushy can hear your room."
    static let stepShow = "Hushy shows what it got right and which words it misheard."

    static let termsHint = "Names, product names or jargon you say often. They’re worked into the sentences, so you can see how Hushy hears them."

    static let roomTone = "This measures your room's noise floor, to check your whisper stands out from it."

    /// Under the result headline.
    static let resultNote = "This was a check. It didn’t change how Hushy transcribes your dictation."

    static func resultHeadline(passed: Int, total: Int) -> String {
        "Hushy got \(passed) of \(total) sentences right"
    }
}
