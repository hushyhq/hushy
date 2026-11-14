import Foundation

/// Restyle selection: the person selects text anywhere on the Mac and asks for a tone, from the right-click
/// Services menu (`RestyleService`) or from Hushy's shortcut. Nothing is spoken and nothing runs until they ask:
/// Hushy never reads the selection or the clipboard on its own.
///
/// The rewrite is a voice edit with a fixed instruction. It runs on the same model, through the same guard
/// (`VoiceEditGuard`: a changed number, a dropped name or a dropped "not" keeps the original text), and the model's
/// extra line about the way of writing is the cleanup path's own (`IntentRegister`).

/// A way of writing the selection. Refined has no register line, as in dictation.
public enum RestyleStyle: String, Sendable, Equatable, CaseIterable {
    case professional, casual, refined, prompt

    /// What a person would have said to ask for it. The guard reads this, so it holds no word that loosens a check
    /// ("not", "remove", "number", "case"): a rewrite may never drop a negation, a name or a number.
    public var instruction: String {
        switch self {
        case .professional: "make this more professional"
        case .casual: "make this more casual"
        case .refined: "clean this up: fix the grammar, spelling and punctuation"
        case .prompt: "rewrite this as a clear prompt for an AI assistant"
        }
    }

    /// The register line the cleanup model was trained on for this way of writing, if it has one.
    public var register: IntentRegister? {
        switch self {
        case .professional: .professional
        case .casual: .casual
        case .prompt: .prompt
        case .refined: nil
        }
    }
}

/// What a Services item does with its result.
public enum RestyleDelivery: Sendable, Equatable {
    /// The app takes the result back and replaces the selection where it allows.
    case replaceSelection
    /// The result goes on the clipboard and the selection stays as it was.
    case copyToClipboard
}

/// The Services menu entries. The raw value is the Objective-C message `Info.plist` (`NSServices`) names, so the
/// provider's method of that name is what the system calls. A test keeps the plist and this table the same.
public enum RestyleService: String, Sendable, Equatable, CaseIterable {
    case makeProfessional, makeCasual, cleanUp
    case copyAsProfessional, copyAsPrompt

    public var style: RestyleStyle {
        switch self {
        case .makeProfessional, .copyAsProfessional: .professional
        case .makeCasual: .casual
        case .cleanUp: .refined
        case .copyAsPrompt: .prompt
        }
    }

    public var delivery: RestyleDelivery {
        switch self {
        case .makeProfessional, .makeCasual, .cleanUp: .replaceSelection
        case .copyAsProfessional, .copyAsPrompt: .copyToClipboard
        }
    }

    /// The `NSMessage` in `Info.plist`.
    public var message: String { rawValue }

    /// The menu item's title. A slash makes the Hushy submenu. Placeholder copy until the founder writes it.
    public var menuTitle: String {
        "\(RestyleCopy.serviceMenu)/\(RestyleCopy.serviceItem(self))"
    }
}

/// How a restyle ended.
public enum RestyleOutcome: Sendable, Equatable {
    case rewritten(String)
    /// The text stays as it was; the pill says why (`VoiceEditDecline.line`).
    case kept(VoiceEditDecline)
}

public enum SelectionRestyler {
    /// The most characters restyled at once: the voice edit's own limit.
    public static let maxCharacters = SelectedText.maxCharacters

    /// Rewrites `text` in `style` on `model` and checks the answer. Anything the guard or the model refuses, and
    /// a model that is missing or late, keeps the text.
    public static func restyle(
        _ text: String, as style: RestyleStyle, model: any LanguageModel, budget: Duration? = nil
    ) async -> RestyleOutcome {
        let request = VoiceEditRequest(selection: text, instruction: style.instruction, guidance: style.register?.line)
        switch await VoiceEditor.editTraced(request, model: model, budget: budget).outcome {
        case .edited(let rewritten): return .rewritten(rewritten)
        case .declined(let why): return .kept(why)
        // The words are ours and are always an instruction; a model that read the selection as new text did not edit it.
        case .dictation: return .kept(.noAnswer)
        }
    }
}

/// Every string the restyle entries show. Placeholders in square brackets until the founder writes the copy.
public enum RestyleCopy {
    public static let serviceMenu = "Hushy"

    public static func serviceItem(_ service: RestyleService) -> String {
        switch service {
        case .makeProfessional: "[Make professional]"
        case .makeCasual: "[Make casual]"
        case .cleanUp: "[Clean up]"
        case .copyAsProfessional: "[Copy as professional]"
        case .copyAsPrompt: "[Copy as prompt]"
        }
    }

    public static func chip(_ style: RestyleStyle) -> String {
        switch style {
        case .professional: "[Professional]"
        case .casual: "[Casual]"
        case .refined: "[Refined]"
        case .prompt: "[Prompt]"
        }
    }

    public static let copyToggle = "[Copy]"
    public static let close = "[Close]"
    public static let on = "[On]"
    public static let off = "[Off]"
    public static let chooserAccessibility = "[Pick a way of writing the selected text.]"
    public static let copied = "[Copied]"
    public static let nothingSelected = "[Select some text first]"
    public static let tooLong = "[Select less text]"
    public static let notHere = "[Not available in this app]"

    public static let shortcutSettingTitle = "[Restyle shortcut]"
    public static let shortcutSettingDetail = "[Select text, press this, pick a tone.]"
}
