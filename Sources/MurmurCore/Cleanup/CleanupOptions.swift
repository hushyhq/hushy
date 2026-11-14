import Foundation

/// How aggressively dictated text is rewritten before insertion.
public enum CleanupLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Only explicit voice commands ("new line", "scratch that") and dictionary fixes.
    case verbatim
    /// Default: also removes fillers, resolves self-corrections and formats lists the speaker
    /// signalled (an inline series stays a sentence — see `ListStructureGuard`).
    case clean
    /// Clean plus an on-device language-model pass when available.
    case polished

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .verbatim: "As spoken"
        case .clean: "Cleaned up"
        case .polished: "Polished"
        }
    }

    /// The same spoken sentence, as each level would type it. Used to teach the choice.
    public static let exampleSpoken = "Um, so let's meet at 10, no, 9, and uh we need the deck, the budget and the demo"

    public var example: String {
        switch self {
        case .verbatim: "Um, so let's meet at 10, no, 9, and uh we need the deck, the budget and the demo."
        case .clean: "So let's meet at 9, and we need the deck, the budget and the demo."
        case .polished: "Let's meet at 9. We need the deck, the budget and the demo."
        }
    }

    public var summary: String {
        switch self {
        case .verbatim: "Word for word, including um and uh. Voice commands still work."
        case .clean: "Drops um and uh, applies “no, I mean…” corrections, makes a list when you say one."
        case .polished: "Cleaned up, then smoothed for grammar and flow by the on-device model."
        }
    }
}

public struct CleanupOptions: Sendable, Equatable {
    /// Which Clean contract the caller selected. Legacy remains the app default until a
    /// candidate clears its gates; minimal is the narrow v3 experiment, while generalMinimal
    /// adds a separately verified broad grammar candidate.
    public enum GrammarContract: String, Sendable, CaseIterable {
        case legacy
        case minimal
        case generalMinimal = "general-minimal"
    }

    public var level: CleanupLevel
    public var grammarContract: GrammarContract
    public var voiceCommandsEnabled: Bool
    /// BCP-47 code of the transcript's detected language (e.g. "es", "fr"), or `nil` when
    /// unknown/not yet detected. English (`nil` or "en"/"en-…") runs the full cleanup pipeline;
    /// any other language skips the English-only stages — see `TextCleaner.clean` and
    /// `.claude/DECISIONS.md` for which stages and why.
    public var detectedLanguage: String?
    /// True when the dictation target is a code editor/terminal (`AppCategory.code` — VS Code,
    /// Cursor, Windsurf, Xcode, Zed, terminals, JetBrains IDEs). Code apps get two things no
    /// other context does: `CasingCommands` ("camel case get user by id" -> `getUserById`) and
    /// `CodeFileTags` ("at index dot tsx" -> `@index.tsx`) run, and `Punctuation.tidy`'s sentence
    /// capitalization/auto-period stages are skipped so punctuation stays exactly as spoken —
    /// see `TextCleaner.clean` and `StyleFormatter` (which already never styles code contexts).
    public var isCodeContext: Bool
    /// True when the dictation target is a chat app (`AppCategory.personalMessages` or
    /// `.workMessages`): texting register, where the rules keep a hedge "like" and leave it to the
    /// model (see `TextingRegister`). Set by `DictationController` next to `isCodeContext`.
    public var isCasualContext: Bool = false
    /// Non-nil only for work messages and email (see `TechnicalTokenContext.make`): spoken
    /// technical tokens (paths, branch names, percentiles, regions, ticket and PR numbers) are
    /// written the way a developer types them. `nil` everywhere else, so code, terminal, AI-prompt,
    /// personal-message and document dictation behave exactly as before.
    public var technicalTokens: TechnicalTokenContext?
    /// Optional identifiers/file names scanned from the user's chosen project folder (Settings ->
    /// Coding). `nil` when no project is set, or scanning hasn't produced anything yet — callers
    /// treat that exactly like an empty vocabulary. See `ProjectVocabulary`, `CodeFileTags`.
    public var projectVocabulary: ProjectVocabulary?
    /// Names/terms a model rewrite must keep (see `ProtectedTermGuard`). `SmartCleaner.clean`
    /// adds the personalizer's Dictionary terms — user entries and active learned terms — so
    /// callers normally leave this empty.
    public var protectedTerms: [String] = []
    /// Heard spellings the Dictionary replaces after cleanup; a rewrite must keep them or their
    /// term. `SmartCleaner.clean` adds the personalizer's, like `protectedTerms`.
    public var protectedAliases: [ProtectedTermGuard.Alias] = []
    /// Names an answer may write for a word that sounds like one: the person's Dictionary terms and the names of their
    /// installed apps, set by `PipelineSettings.forDictation` (`KnownProductNames` adds the built-in ones). Never shown to
    /// the model; only the names check reads it.
    public var knownNames: [String] = []
    /// Reference shown to the intent model for this dictation.
    public var personBlock: PersonBlock?
    /// The way of writing this dictation asks for, from the tone and the kind of app (`ToneSettings.register`). It is
    /// sent to the model only when the model understands register lines (`SmartCleaner.sendsRegisterLines`); otherwise
    /// it changes nothing.
    public var register: IntentRegister?
    /// Rewrite British spellings the recognizer emits to American ones (`AmericanSpelling`) at
    /// Clean and Polished. Off by default — no UI yet; see docs/product/US-ENGLISH-ACCURACY.md for
    /// the measurement and the recommendation to turn it on for en-US locales.
    public var americanSpelling: Bool

    public init(
        level: CleanupLevel = .clean, voiceCommandsEnabled: Bool = true, detectedLanguage: String? = nil,
        isCodeContext: Bool = false, projectVocabulary: ProjectVocabulary? = nil, americanSpelling: Bool = false,
        grammarContract: GrammarContract = .legacy
    ) {
        self.level = level
        self.grammarContract = grammarContract
        self.voiceCommandsEnabled = voiceCommandsEnabled
        self.detectedLanguage = detectedLanguage
        self.isCodeContext = isCodeContext
        self.projectVocabulary = projectVocabulary
        self.americanSpelling = americanSpelling
    }

    /// True when `detectedLanguage` is English or unknown — the case where every cleanup stage
    /// (including the English-only ones) is safe to run.
    public var isEnglishOrUnknown: Bool {
        guard let detectedLanguage else { return true }
        return detectedLanguage == "en" || detectedLanguage.hasPrefix("en-")
    }
}

/// What the technical-token rules (`SpokenTechnicalTokens`) may use as evidence.
public struct TechnicalTokenContext: Sendable, Equatable {
    /// The browser tab title, when the target is a browser (the app reads no other window's title).
    /// A ticket key that appears in it ("ENG-1510 ...") is evidence that the same key is a project key.
    public var windowTitle: String?

    public init(windowTitle: String? = nil) {
        self.windowTitle = windowTitle
    }

    /// The context for a dictation target, or `nil` when the target is not a work-message or
    /// email app. The title is only used for browsers, mirroring what `FocusTarget` captures.
    public static func make(category: AppCategory, bundleID: String?, windowTitle: String?) -> TechnicalTokenContext? {
        guard category == .workMessages || category == .email else { return nil }
        return TechnicalTokenContext(windowTitle: AppCategory.isBrowser(bundleID) ? windowTitle : nil)
    }
}

/// The result of cleaning one utterance.
public struct CleanupResult: Sendable, Equatable {
    public let text: String
    /// True when the utterance ended with "press enter"; the caller should send Return after inserting.
    public let pressEnter: Bool
    /// Correction cues ("no", "I mean", …) that the rules saw but could not confidently resolve.
    /// A language-model pass can use this as a signal that it is worth running.
    public let unresolvedCues: Int

    public init(text: String, pressEnter: Bool = false, unresolvedCues: Int = 0) {
        self.text = text
        self.pressEnter = pressEnter
        self.unresolvedCues = unresolvedCues
    }
}
