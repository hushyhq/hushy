import Foundation

/// One resolved slot value the model or `DateAnchor` filled in for a proposed action.
///
/// A plain mirror of the model-facing action envelope below, so the confirmation UI, History,
/// backends and tests all work with one Sendable, Codable type whatever the model backend —
/// the same pattern `SmartCleaner.RerankPreference` uses for `RerankChoice`.
public struct ProposedAction: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case createEvent
        case createReminder
        case runShortcut
        /// Open an app, a service link, a screened web address or an AI hand-off (`url`).
        /// Navigation only; nothing on the page is read or clicked.
        case openLink
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    /// ISO-8601 with time zone; nil when the action has no date (rare for MVP intents).
    public var start: Date?
    public var end: Date?
    public var calendarName: String?
    public var location: String?
    public var listName: String?
    public var shortcutName: String?
    public var shortcutInput: String?
    /// The raw phrase the date was anchored from ("tomorrow"), shown on hover in the
    /// confirmation card for trust (research doc §4.1's "show the diff" pattern).
    public var dateSourcePhrase: String?
    /// Free-text notes for the event/reminder body. Only the Assistant's `propose_action` path
    /// fills this in today; voice actions leave it nil. Optional, so previously encoded values
    /// still decode.
    public var notes: String?
    /// For `.openLink`: the https (or app) URL to open, built by `DeepLinkBuilder` /
    /// `AIHandoffLink` or screened by `SafeURLPolicy`; nil means "open the app named `title`".
    /// Optional, so previously encoded values still decode.
    public var url: String?
    /// For `.openLink`: the Mac app to open or activate ("Chrome"), as the user said it — never
    /// the row's title ("Open Chrome"), which carries the verb. With a `url` as well (an AI
    /// service), the app is tried first and the site opens when it isn't installed. Optional, so
    /// previously encoded values still decode.
    public var appName: String?
    /// The exact utterance segment this action was extracted from, for multi-intent display.
    public var sourceText: String

    public init(
        id: UUID = UUID(), kind: Kind, title: String, start: Date? = nil, end: Date? = nil,
        calendarName: String? = nil, location: String? = nil, listName: String? = nil,
        shortcutName: String? = nil, shortcutInput: String? = nil, dateSourcePhrase: String? = nil,
        notes: String? = nil, appName: String? = nil, url: String? = nil, sourceText: String
    ) {
        self.url = url
        self.appName = appName
        self.id = id
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.location = location
        self.listName = listName
        self.shortcutName = shortcutName
        self.shortcutInput = shortcutInput
        self.dateSourcePhrase = dateSourcePhrase
        self.notes = notes
        self.sourceText = sourceText
    }
}

/// The outcome of one slot-filling pass over an utterance: zero or more actions (the model
/// decides — one utterance may yield 1–3, e.g. "add a dentist appointment tomorrow at 3 and
/// remind me to buy flowers"), or none at all, meaning "this isn't an action" and the caller
/// should fall back to plain dictation. Never a hard failure by itself — model unavailability
/// and refusals are represented as `.modelUnavailable`/`.rejected` so the caller always has a
/// safe, explicit fallback path (see `docs/research/voice-actions.md` §2.3, §4.2).
public enum ActionExtractionResult: Sendable, Equatable {
    /// One or more actions the model proposed, each independently confirmable.
    case actions([ProposedAction])
    /// The model considered the utterance and decided it is not a command (the common case
    /// even under the trigger — the product-owner brief and research doc §6.1 both call out
    /// "held the action key by mistake" as a first-class case to degrade gracefully from).
    case notAnAction
    /// Apple Intelligence / Foundation Models is not available on this Mac or is disabled.
    case modelUnavailable
    /// The model's answer was rejected (timeout, refusal, malformed output) — never treated as
    /// a silent no-op; the caller must fall back to plain dictation of the utterance, exactly
    /// like `SmartCleaner`'s `OutputGuard` fallback for cleanup.
    case rejected(String)
    /// A command Hushy understood but won't turn into an action: editing or cancelling an
    /// existing event ("prepone the standup"), a Shortcut that isn't installed, or one that would
    /// erase data or came wrapped in injected instructions (`ActionSafetyScreen`). The pill shows
    /// the message; the transcript is not pasted, since it was a command, not dictation.
    case refused(ActionRefusal)
}

/// Why a command was refused, and what to tell the user.
public struct ActionRefusal: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// Reschedule, move, cancel or delete: voice actions only create things.
        case unsupported
        /// A Shortcut that erases, wipes or resets, or a shell command.
        case destructive
        /// Instruction-shaped text ("ignore previous instructions…") around a Shortcut run.
        case injection
        /// The spoken Shortcut name matches nothing in the user's Shortcuts library.
        case shortcutNotInstalled
    }

    public let reason: Reason
    /// A short line for the pill (it shows one line).
    public let message: String
    /// Closest installed Shortcut names, for `.shortcutNotInstalled`.
    public let suggestions: [String]

    public init(reason: Reason, message: String, suggestions: [String] = []) {
        self.reason = reason
        self.message = message
        self.suggestions = suggestions
    }
}

/// What the model answers for one utterance (guided generation against
/// `GeneratedActionEnvelope.generationSchema`). The schema's descriptions are prompt text: they
/// are pinned to the `@Generable` types they replaced by `HushyModelsAppleTests`.
enum ActionKindGenerable: String, Sendable, Decodable {
    case createEvent
    case createReminder
    case runShortcut
    /// Not a command — an ordinary dictation sentence that merely mentions a calendar/reminder/
    /// shortcut word ("I'll add it to my calendar later"). See voice-actions.md §2.1.
    case none
}

/// One action the model extracted from the utterance, with typed slots. `when`/`untilWhen` are
/// raw phrases ("tomorrow at 3", "in 30 minutes") resolved separately by `DateAnchor` — per
/// voice-actions.md §4.3's "deterministic parser first, model only copies the phrase" division
/// of labor, the model is given `DateAnchor`'s result as a pre-filled hint
/// (see `ActionPrompt`) rather than asked to compute an absolute date itself, which both cuts
/// latency (less to generate) and cuts hallucination risk.
struct GeneratedAction: Sendable, Decodable {
    var kind: ActionKindGenerable
    var title: String
    var when: String
    var durationMinutes: Int
    var listOrCalendarName: String
    var location: String
    var shortcutInput: String
}

/// What the person is doing with the sentence, decided by the model before it lists actions.
/// Naming it first is guidance: a small model that has said "thinkingAloud" has already
/// decided not to create anything. Only `askingYou` can produce actions.
enum SpeechActGenerable: String, Sendable, Decodable {
    case askingYou
    case tellingSomeone
    case thinkingAloud
    case reporting
    case smallTalk
}

/// The full envelope: the model may return 0–3 actions for one utterance (the product-owner
/// decision: "let the model decide — one utterance may yield 1–3 actions"). An utterance that
/// is plain dictation returns an empty list.
struct GeneratedActionEnvelope: StructuredOutput {
    /// Required by the schema. Optional here only so that an answer without it decodes: it then
    /// counts as "not a request" (`ActionExtractor`), never as a request. The app's only backend
    /// for actions is Apple Foundation Models, which is given this schema and must produce the field.
    var speech: SpeechActGenerable?
    var actions: [GeneratedAction]

    static let generationSchema = GenerationSchemaSpec(name: "GeneratedActionEnvelope", json: #"""
        {"$defs":{"GeneratedAction":{"additionalProperties":false,"properties":{"durationMinutes":{"description":"Duration in minutes for a calendar event; 0 if not specified (defaults to 30)","type":"integer"},"kind":{"description":"Which kind of action this is. Use a real kind when the speaker asks you to create a calendar event, create a reminder or run a Shortcut, with or without a time: as an instruction ('add...', 'remind me to...', 'schedule...', 'run my ... shortcut'), as a polite or indirect question ('can you remind me to...?', 'could you put ... on my calendar?'), or as a statement of what they want ('I need you to...', 'please...'). Use 'none' when the speaker is not asking you to do one of those things: reported speech ('she said she would schedule...', 'he told me to remind him...'), a hedge or vague future intent ('I should call the dentist at some point'), a third person's habits ('my mom always reminds me to...'), or a question about something else that only mentions a calendar, reminder or shortcut ('why didn't my reminder go off?').","enum":["createEvent","createReminder","runShortcut","none"],"type":"string"},"listOrCalendarName":{"description":"Named calendar or reminder list if one was spoken, else empty","type":"string"},"location":{"description":"Location for a calendar event if one was spoken, else empty","type":"string"},"shortcutInput":{"description":"Input to pass a Shortcut if one was spoken, else empty","type":"string"},"title":{"description":"Short title for the event/reminder, or the exact Shortcut name to run","type":"string"},"when":{"description":"The date/time phrase as spoken, e.g. 'tomorrow at 3pm', or empty if none was said","type":"string"}},"required":["kind","title","when","durationMinutes","listOrCalendarName","location","shortcutInput"],"title":"GeneratedAction","type":"object","x-order":["kind","title","when","durationMinutes","listOrCalendarName","location","shortcutInput"]}},"additionalProperties":false,"properties":{"actions":{"description":"0 to 3 actions extracted from the utterance; empty unless speech is askingYou","items":{"$ref":"#/$defs/GeneratedAction"},"type":"array"},"speech":{"description":"What the person is doing with this sentence. askingYou: they ask YOU to create a calendar event, create a reminder for themselves or run a Shortcut, as an instruction ('add...', 'remind me to...'), a polite question ('can you...?', 'could you...?') or a statement of what they want from you ('I need you to...'); asking you to invite people to an event is also askingYou. tellingSomeone: a fact or an arrangement, an invitation put to another person ('shall we meet?'), or an instruction to another person, including asking someone else to be reminded. thinkingAloud: a plan, hope or hedge about what they or someone will do or should do. reporting: what someone else said, asked or wants. smallTalk: chat, a status message, a question about the world or how something works, or checking that you can hear them.","enum":["askingYou","tellingSomeone","thinkingAloud","reporting","smallTalk"],"type":"string"}},"required":["speech","actions"],"title":"GeneratedActionEnvelope","type":"object","x-order":["speech","actions"]}
        """#)
}
