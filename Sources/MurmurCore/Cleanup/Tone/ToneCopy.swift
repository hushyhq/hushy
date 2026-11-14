import Foundation

/// The sentences around the tone choice, kept here so a test can read every one of them.
public enum ToneCopy {
    /// The status note under the tone choice: its heading, and the line added when nothing can
    /// polish on this Mac right now. The sentence in between is the cleanup controller's, and it
    /// already says that the simpler fixes run; only the part that tidies longer or messier speech
    /// is simpler, so tones still apply.
    public static let polishStatusTitle = "What polishes your text"
    public static let tonesStillApply = "Tones still apply."

    /// Shown while "As spoken" is selected, under the per-app tones.
    public static let pausedByAsSpoken = "Tones are paused while As spoken is selected."

    /// One line under the per-app tone cards.
    public static func destinationNote(_ settings: ToneSettings, for context: StyleContext) -> String {
        if let layout = settings.keptLayout(for: context) {
            return "Still using your earlier “\(layout.title)” layout here. Pick a tone to replace it."
        }
        if settings.isShippedTone(for: context) {
            return "Here, Hushy starts on \(settings.tone(for: context).title)."
        }
        if settings.hasOverride(for: context) {
            return "Here, Hushy writes in \(settings.tone(for: context).title)."
        }
        return "Here, Hushy uses your default tone, \(settings.defaultTone.title)."
    }

    /// Voice & style → Style: the heading over the tone choice.
    public static let writingPointerTitle = "How Hushy writes"

    /// Voice & style → Style: the two switches under the tone choice.
    public static let voiceCommandsTitle = "Voice commands"
    public static let voiceCommandsDetail =
        "Say “new line”, “new paragraph”, “scratch that” or “press enter” and Hushy does it instead of writing the words."
    public static let americanSpellingTitle = "Use American spelling"
    public static let americanSpellingDetail =
        "Rewrites British spellings Hushy hears (“colour”, “programme”) to American ones (“color”, “program”)."

    /// Voice & style page banner.
    public static let pageBanner = "How Hushy cleans up what you say, the words it should know, and phrases it expands. A tone changes how your words read, never what you meant."

    /// The kinds of apps, and the apps inside them.
    public static let appsTitle = "Your apps"
    public static let onboardingAppsDetail = "Each kind of app can have its own tone. Fine control is on the Voice & style page."
    public static let promptName = "Prompt"
    public static let comingBadge = "Coming"
    public static let noToneInCode = "No tone (code)"
    public static let codeKindNote = "Punctuation in code is syntax, so Hushy leaves it alone."
    public static let codeAppsLeftAlone = "Code editors and terminals get no tone: punctuation there is syntax."
    public static let browsersNeedKind = "A browser can be anything, so add the website instead: Add, then pick the site."
    public static let couldNotReadApp = "Hushy could not read that app."
    public static let nothingFoundHere = "None found on this Mac"
    public static let followsDefault = "Follows"
    public static let websitesNote =
        "Websites follow what the page is: a Gmail tab uses Email; Slack, Google Meet and Zoom tabs use Work messages; any other page uses Everything else. A website you add to a tone uses that tone."
    public static func moreApps(_ count: Int) -> String { "and \(count) more" }
    public static func aiToolsNote(_ settings: ToneSettings) -> String {
        "Uses your Everything else tone, \(settings.tone(for: .other).title), for now."
    }

    /// The tone page: apps organised by tone (`ToneBoard`).
    public static let dropHere = "Drop here"
    public static let addApp = "Add app"
    public static let add = "Add"
    public static let addAppItem = "App…"
    public static let addWebsiteSection = "Website"
    public static let otherWebsite = "Other website…"
    public static let websiteFieldPrompt = "Website address"
    public static let websiteFieldPlaceholder = "docs.google.com"
    public static func addWebsiteTo(_ lane: ToneLane) -> String { "Add to \(lane.title)" }
    public static let websiteNotAddress = "That is not a website address. Try one like docs.google.com."
    public static let websiteKeptNote = "Only the site’s address is kept, on this Mac. Hushy never reads the page."
    public static let removeWebsite = "Remove from this page"
    public static func websiteChipLabel(_ name: String, in lane: ToneLane) -> String { "\(name) website, \(lane.title)" }
    public static let youSay = "You say"
    public static func hushyWrites(in app: String) -> String { "Hushy writes · in \(app)" }
    public static let noToneTitle = "No tone"
    public static func moveTitle(_ name: String) -> String { "Move \(name) to" }
    public static func moveTo(_ lane: ToneLane) -> String { "Move to \(lane.title)" }
    public static func backTo(_ lane: ToneLane) -> String { "Back to \(lane.title)" }
    public static let followsItsKind = "Follows its kind of app"
    public static let placedByYou = "Placed by you"
    public static func chipLabel(_ name: String, in lane: ToneLane) -> String { "\(name), \(lane.title)" }
    public static let chipHint = "Opens a menu to move it to another tone. You can also drag it."

    /// What a lane does, in one line. With register lines Professional, Casual and Prompt reword; without them a tone
    /// changes contractions only, and the line says exactly that (`DictationTone.detail`).
    public static func laneDetail(_ lane: ToneLane, registerLines: Bool) -> String {
        switch (lane, registerLines) {
        case (.refined, _): DictationTone.refined.detail
        case (.professional, true): "Courteous and complete, worded the way you would write to a client."
        case (.casual, true): "Relaxed and conversational, like a note to a friend."
        case (.professional, false): DictationTone.professional.detail
        case (.casual, false): DictationTone.casual.detail
        case (.prompt, _): "A clear request for an AI app: the ask first, your steps kept as steps."
        case (.asSpoken, _): CleanupLevel.verbatim.summary
        }
    }

    /// Prompt on a Mac whose writing model does not take register lines.
    public static func promptComing(_ settings: ToneSettings) -> String {
        "Coming with Hushy's larger writing model. Until then AI apps use \(settings.tone(for: .other).title)."
    }

    public static let asSpokenTitle = "As spoken"
    public static let asSpokenOnNote = "On: every app gets your words as spoken, so the tones above are paused."
    /// The switch on the As spoken card that turns it on for every app at once.
    public static let asSpokenEveryAppTitle = "Every app"
    public static let asSpokenEveryAppDetail = "Word for word everywhere, whatever tone an app or website sits in."

    /// A kind of app on the board: the chip every app and website of that kind follows until it is placed.
    public static func kindChipName(_ place: StyleContext) -> String {
        switch place {
        case .workMessages: "Other work chat"
        case .email: "Other email"
        case .personalMessages: "Other messages"
        case .other: "Other apps & sites"
        }
    }
    public static func kindChipHelp(_ place: StyleContext) -> String {
        let subject = switch place {
        case .workMessages: "Work chat apps and websites"
        case .email: "Email apps and websites"
        case .personalMessages: "Messaging apps and websites"
        case .other: "All other apps and websites"
        }
        return "\(subject) you have not placed follow this. Move it to move them all."
    }
    public static func kindChipLabel(_ place: StyleContext, in lane: ToneLane) -> String {
        "\(kindChipName(place)), \(lane.title). \(kindChipHelp(place))"
    }
    public static func noToneFootnote(_ names: [String]) -> String {
        "No tone in code editors and terminals: " + names.joined(separator: ", ") + "."
    }
    public static let seeExample = "Example"

    /// Onboarding.
    public static let onboardingTitle = "Pick a tone"
    public static func onboardingMessage(spoken: String) -> String {
        "You said: “\(spoken)”. How should that arrive? You can change this any time from the menu bar."
    }
}
