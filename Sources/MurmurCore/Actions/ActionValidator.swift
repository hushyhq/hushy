import Foundation

/// Validates and normalizes one model-generated action into a `ProposedAction`, or drops it.
/// Kept separate from `ActionExtractor` so slot-validation rules (what makes a title acceptable,
/// how a spoken "when" phrase is re-anchored) are unit-testable without a model round trip —
/// tests construct a `GeneratedAction` directly (see `ActionValidatorTests`).
enum ActionValidator {
    static func validate(
        _ generated: GeneratedAction, utterance: String, fallbackAnchor: AnchoredDate?, context: DateContext
    ) -> ProposedAction? {
        guard let kind = ProposedAction.Kind(from: generated.kind) else { return nil }
        let title = generated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        switch kind {
        case .createEvent:
            return event(from: generated, title: title, utterance: utterance, fallbackAnchor: fallbackAnchor, context: context)
        case .createReminder:
            return reminder(from: generated, title: title, utterance: utterance, fallbackAnchor: fallbackAnchor, context: context)
        case .runShortcut:
            return ProposedAction(
                kind: .runShortcut, title: title,
                shortcutName: title,
                shortcutInput: generated.shortcutInput.isEmpty ? nil : generated.shortcutInput,
                sourceText: utterance)
        case .openLink:
            // The model's envelope has no open kind; links come from `OpenCommandParser`.
            return nil
        }
    }

    private static func event(
        from generated: GeneratedAction, title: String, utterance: String, fallbackAnchor: AnchoredDate?,
        context: DateContext
    ) -> ProposedAction? {
        let anchor = resolvedAnchor(for: generated.when, fallback: fallbackAnchor, context: context)
        // A calendar event with no resolvable date at all is not confidently actionable — the
        // research doc's error-case table (§4.2) treats a missing required slot as "show the
        // best partial parse with the ambiguous slot highlighted", which for MVP means: still
        // propose the action (so Edit can fill in the date) rather than silently dropping it,
        // as long as a title was clearly stated.
        let start = anchor?.start
        // A spoken duration wins; else the anchor's end (a spoken range like "2 to 3 pm", or the
        // default length).
        let end = start.map { start in
            if generated.durationMinutes > 0 { return start.addingTimeInterval(TimeInterval(generated.durationMinutes * 60)) }
            if let anchorEnd = anchor?.end, anchorEnd > start { return anchorEnd }
            return start.addingTimeInterval(DateAnchor.defaultDurationSeconds)
        }
        return ProposedAction(
            kind: .createEvent, title: title, start: start, end: end,
            calendarName: generated.listOrCalendarName.isEmpty ? nil : generated.listOrCalendarName,
            location: generated.location.isEmpty ? nil : generated.location,
            dateSourcePhrase: anchor?.sourcePhrase, sourceText: utterance)
    }

    private static func reminder(
        from generated: GeneratedAction, title: String, utterance: String, fallbackAnchor: AnchoredDate?,
        context: DateContext
    ) -> ProposedAction {
        let anchor = resolvedAnchor(for: generated.when, fallback: fallbackAnchor, context: context)
        return ProposedAction(
            kind: .createReminder, title: title, start: anchor?.start,
            listName: generated.listOrCalendarName.isEmpty ? nil : generated.listOrCalendarName,
            dateSourcePhrase: anchor?.sourcePhrase, sourceText: utterance)
    }

    /// Re-resolves the spoken "when" phrase via `DateAnchor` rather than trusting the model's
    /// own idea of the date (voice-actions.md §4.3: the parser is the deterministic anchor,
    /// the model only reports the phrase). Falls back to the utterance-level anchor computed
    /// before the model call when the per-action phrase doesn't parse (e.g. the model normalized
    /// wording slightly) or is empty.
    private static func resolvedAnchor(for phrase: String, fallback: AnchoredDate?, context: DateContext) -> AnchoredDate? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return DateAnchor.firstDate(in: trimmed, context: context) ?? fallback
    }
}

extension ProposedAction.Kind {
    init?(from generable: ActionKindGenerable) {
        switch generable {
        case .createEvent: self = .createEvent
        case .createReminder: self = .createReminder
        case .runShortcut: self = .runShortcut
        case .none: return nil
        }
    }
}
