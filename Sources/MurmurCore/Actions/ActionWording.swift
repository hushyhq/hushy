import Foundation

/// The plain lines the pill, the card and History say about what happened to a voice action.
/// One place, so the card, the Assistant and the tests agree, and so nothing here can carry
/// more than the action's own title or a name the person said.
public enum ActionWording {
    /// Under a Shortcut's row before it runs: Hushy cannot see inside the person's Shortcut.
    public static let shortcutWarning = "This runs your shortcut. Hushy can't undo what it does."

    /// An event with no start time: asked for, never guessed.
    public static let missingStart = "Needs a time. Say it again with one."

    /// Shown while an Undo runs: neutral, neither done nor failed.
    public static let undoing = "Undoing\u{2026}"

    /// Shown once Undo has really removed it.
    public static let undone = "Undone"

    /// The item was removed but Hushy could not update its History note.
    public static let undoNotRecorded = "Removed, but History couldn't be updated."

    /// The action ran; only its History note could not be saved.
    public static let notRecorded = "Done, but Hushy couldn't record it in History"

    /// Undo ran and the item is still there.
    public static func undoFailed(for kind: ProposedAction.Kind) -> String {
        switch kind {
        case .createEvent: "Couldn't undo. The event is still in Calendar."
        case .createReminder: "Couldn't undo. The reminder is still in Reminders."
        case .runShortcut, .openLink: "Couldn't undo."
        }
    }

    /// The one line for a failed, blocked or uncertain action, in the words the card shows.
    public static func line(for error: ActionExecutionError) -> String {
        switch error {
        case .permissionDenied(let what): "\(what) access needed"
        case .notFound(let name): "Couldn't find an app called \"\(name)\""
        case .closestApps(let heard, let apps): "Couldn't find \"\(heard)\". Closest: \(apps.joined(separator: ", "))"
        case .backendFailed(let reason): reason
        case .saveFailed: "Couldn't save the item. Try again."
        case .needsInput(let what): "\(what) needs input Hushy can't provide"
        case .missingStart: missingStart
        case .targetNotFound(let target, let name): targetNotFound(target, name)
        case .mayHaveRun(let reason): mayHaveRun(reason)
        }
    }

    public static func targetNotFound(_ target: ActionExecutionError.Target, _ name: String) -> String {
        switch target {
        case .calendar: "Couldn't find a calendar called \u{201C}\(name)\u{201D}"
        case .list: "Couldn't find a Reminders list called \u{201C}\(name)\u{201D}"
        case .shortcut: "Couldn't find a shortcut called \u{201C}\(name)\u{201D}"
        }
    }

    // MARK: A list or calendar that isn't there: the default, on the person's tick

    /// The pill's one line when a named list or calendar is not there: what is missing, then the
    /// question its tick answers. The name gives way, never the question: it is shown up to
    /// `nameLimit` characters, and the row asks for fewer when the line would not fit
    /// (`ActionProblemRow.question`).
    public static func useDefaultQuestion(_ recovery: ActionRecovery, nameLimit: Int = questionNameLimit) -> String {
        switch recovery {
        case .useDefault(.calendar, let name):
            "No calendar called \u{201C}\(shortened(name, to: nameLimit))\u{201D}. Add to your default calendar?"
        case .useDefault(.list, let name):
            "No list called \u{201C}\(shortened(name, to: nameLimit))\u{201D}. Add to your default list?"
        }
    }

    /// What the tick does, for its hover hint and VoiceOver.
    public static func useDefaultTitle(_ recovery: ActionRecovery) -> String {
        switch recovery {
        case .useDefault(.calendar, _): "Add to default calendar"
        case .useDefault(.list, _): "Add to default list"
        }
    }

    /// The same offer as a button on a row of a card with several actions.
    public static let useDefaultButton = "Use default"

    /// The longest name the question shows whole, and the least of a name it keeps.
    public static let questionNameLimit = 28
    public static let questionNameFloor = 4

    static func shortened(_ name: String, to limit: Int) -> String {
        let limit = max(limit, questionNameFloor)
        guard name.count > limit else { return name }
        return name.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// A restored card for an action that was started and never recorded as finished (Hushy quit,
    /// or its storage failed, mid-run). Fixed words: never a calendar, list or Shortcut name.
    public static let mayAlreadyHaveRun = "Hushy can't tell if this ran. It may already have run."

    /// The chat could not be saved before the action would have run, so it did not run.
    public static let notStartedChatNotSaved = "Didn't run: Hushy couldn't save this chat first."

    /// Plain that it may already have run, and no Retry offered next to it.
    public static func mayHaveRun(_ reason: ActionExecutionError.UncertainReason) -> String {
        switch reason {
        case .timedOut: "Timed out. It may already have run."
        case .didNotFinish: "It stopped partway. It may have partly run."
        }
    }
}
