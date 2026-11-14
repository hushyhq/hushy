import Foundation

/// The one trust policy for everything a voice action can do (founder decisions, 2026-09-28):
///
/// - **Tiers.** Safe, local, reversible things that affect only the user act at once and show
///   "Done · Undo" (`.actFirst`): reminders, timers, own-calendar events with no attendees,
///   Hushy notes, adding to a list, opening an app / link / search, an AI hand-off. Everything
///   that reaches other people, deletes or overwrites, runs arbitrary automation (a Shortcut) or
///   goes through the user's own agent keeps the confirm card (`.confirmFirst`). A Tier-1 action
///   whose parse is uncertain (an ambiguous date, name or list; a validator warning) falls back
///   to the card. A Shortcut always gets the card, under every setting: Hushy cannot see what the
///   person's own Shortcut does, so it cannot promise what it will not do, and cannot undo it.
/// - **The submit rule.** After the user's ✓ (or an act-first execution): read-only lookups and
///   "ask an AI" may submit by themselves when that service's hand-off URL is verified
///   (`AIHandoffLink.Service.linkSubmitsAutomatically`); otherwise the link only fills the box
///   (`.draftOnly`). Other lookups submit by themselves (`.autoSubmit`: a URL that runs the query,
///   or ⏎ in an app's own search box); anything that sends to people is only ever filled in as a draft, never
///   with ⏎ (`.draftOnly`); plain dictation never presses ⏎ (`.never`).
/// - **The "Ask before doing" setting.** `always` puts every action on the card; `risky` (the
///   default) is the tiering above; `never` skips the card for everything Hushy can do itself,
///   but keeps Tier 2's no-send rule for what Hushy itself does: drafts stay drafts, and connected
///   actions and Shortcuts still need the tap because the user's agent or the user's own
///   automation, not Hushy, carries them out.
///
/// Pure and total: every `ActionClass` gets exactly one tier and one submit verdict, so the UI
/// never has to decide. Tested in `ActionPolicyTests`.
public enum ActionPolicy {
    /// Settings → General → "Ask before doing".
    public enum AskBeforeDoing: String, CaseIterable, Sendable, Codable {
        case always
        case risky
        case never

        public var title: String {
            switch self {
            case .always: "Always"
            case .risky: "Only for risky actions"
            case .never: "Never"
            }
        }
    }

    /// What kind of thing an action is, for the policy's purposes. Not the tool name: the
    /// same tool can be two classes (an event with attendees is `.invite`).
    public enum ActionClass: Sendable, Equatable, Hashable {
        // Tier 1 candidates: local, reversible, only the user's own data.
        case reminder
        case timer
        case ownEvent
        case note
        case addToList
        case openApp
        case openLink
        case webSearch
        case aiHandoff
        // Read-only answers (the answer card). Never a card.
        case askOwn
        case summarizeScreen
        // Tier 2: reaches other people, arbitrary automation, or someone else executes.
        case draftEmail
        case draftMessage
        case post
        case invite
        case deleteOrOverwrite
        case connected
        case shortcut
        // Plain dictation: not an action at all.
        case dictation
    }

    /// How sure the parser is. Anything short of `.certain` puts a Tier-1 action on the card.
    public enum Confidence: Sendable, Equatable {
        case certain
        case uncertain(String)
    }

    public enum Tier: Sendable, Equatable {
        /// Do it now, show "Done · Undo", log it with undo.
        case actFirst
        /// Show the confirm card; nothing happens until ✓.
        case confirmFirst
    }

    public enum Submit: Sendable, Equatable {
        /// The lookup runs by itself: a URL that submits the query, or ⏎ in the app's search box.
        case autoSubmit
        /// Filled in as a draft only. Hushy never presses ⏎ for it.
        case draftOnly
        /// Nothing to submit (dictation, on-device creates, read-only answers).
        case never
    }

    /// Classes that may act first when the parse is certain.
    public static let tierOne: Set<ActionClass> = [
        .reminder, .timer, .ownEvent, .note, .addToList, .openApp, .openLink, .webSearch, .aiHandoff,
    ]

    /// Classes that stay on the card even under "Ask before doing: Never", because someone other
    /// than Hushy executes them after the tap: the user's agent, or the user's own Shortcut.
    public static let alwaysConfirm: Set<ActionClass> = [.connected, .shortcut]

    /// Read-only answers: neither a card nor an act; the answer card shows them.
    public static let readOnly: Set<ActionClass> = [.askOwn, .summarizeScreen, .dictation]

    public static func tier(
        for actionClass: ActionClass, confidence: Confidence = .certain, setting: AskBeforeDoing = .risky
    ) -> Tier {
        if readOnly.contains(actionClass) { return .actFirst }
        if alwaysConfirm.contains(actionClass) { return .confirmFirst }
        switch setting {
        case .always:
            return .confirmFirst
        case .never:
            return .actFirst
        case .risky:
            guard tierOne.contains(actionClass), confidence == .certain else { return .confirmFirst }
            return .actFirst
        }
    }

    /// The submit rule. Independent of the setting: "Never" still keeps drafts as drafts, so Hushy
    /// itself never presses send. A Shortcut is the person's own automation, which Hushy can't
    /// see into: it always asks first (`alwaysConfirm`) and its submit verdict says nothing about it.
    public static func submit(for actionClass: ActionClass) -> Submit {
        switch actionClass {
        case .openLink, .webSearch, .openApp:
            return .autoSubmit
        case .aiHandoff:
            return .draftOnly
        case .draftEmail, .draftMessage, .post, .invite, .connected:
            return .draftOnly
        case .reminder, .timer, .ownEvent, .note, .addToList, .askOwn, .summarizeScreen, .deleteOrOverwrite,
             .shortcut, .dictation:
            return .never
        }
    }

    /// The submit rule for one proposed action. AI hand-offs follow each service's verified flag.
    public static func submit(for action: ProposedAction) -> Submit {
        if actionClass(of: action) == .aiHandoff,
           let service = AIHandoffLink.service(for: action.url),
           service.linkSubmitsAutomatically {
            return .autoSubmit
        }
        return submit(for: actionClass(of: action))
    }

    /// Whether Hushy may press ⏎ after filling something in. Only the auto-submit lookups.
    public static func mayPressReturn(for actionClass: ActionClass) -> Bool {
        submit(for: actionClass) == .autoSubmit
    }

    public static func mayPressReturn(for action: ProposedAction) -> Bool {
        submit(for: action) == .autoSubmit
    }

    /// The class of a proposed on-device action. Attendees turn an event into an invite.
    public static func actionClass(of action: ProposedAction) -> ActionClass {
        switch action.kind {
        case .createReminder: action.listName == nil ? .reminder : .addToList
        case .createEvent: .ownEvent
        case .runShortcut: .shortcut
        case .openLink: action.url.map { Self.isAIHandoff($0) ? .aiHandoff : .openLink } ?? .openApp
        }
    }

    static func isAIHandoff(_ url: String) -> Bool {
        AIHandoffLink.Service.allCases.contains { url.hasPrefix($0.urlPrefix) }
    }
}

/// How sure the extractor's parse of one action is: an unresolvable or ambiguous date, an
/// empty or one-word title where a name was expected, or a list that wasn't named puts the
/// action on the card instead of acting.
public enum ActionConfidence {
    /// Date words the anchor resolves, but which name a range rather than a moment.
    static let vaguePhrases = [
        "sometime", "some time", "at some point", "eventually", "later this", "next week", "this week", "or",
        "maybe", "around", "ish",
    ]

    public static func assess(_ action: ProposedAction, utterance: String) -> ActionPolicy.Confidence {
        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count < 2 { return .uncertain("no title") }
        switch action.kind {
        case .createEvent:
            guard action.start != nil else { return .uncertain("no date") }
            return dateConfidence(action)
        case .createReminder:
            if action.start == nil, mentionsTime(utterance) { return .uncertain("date not understood") }
            return dateConfidence(action)
        case .runShortcut, .openLink:
            return .certain
        }
    }

    private static func dateConfidence(_ action: ProposedAction) -> ActionPolicy.Confidence {
        guard let phrase = action.dateSourcePhrase?.lowercased() else { return .certain }
        let padded = " \(phrase) "
        for vague in vaguePhrases where padded.contains(" \(vague) ") {
            return .uncertain("vague date \"\(phrase)\"")
        }
        return .certain
    }

    /// The utterance names a time the anchor couldn't resolve.
    static func mentionsTime(_ utterance: String) -> Bool {
        let words = Set(utterance.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let timeWords: Set<String> = [
            "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "noon", "midnight", "am", "pm", "oclock", "week", "month",
        ]
        return !words.isDisjoint(with: timeWords)
    }
}
