import FoundationModels

/// Verbatim copies of the `@Generable` types MurmurCore used before the `LanguageModel` seam
/// (commit 7098334: `SmartCleaner.Cleaned/RerankChoice/RerankAnswer/NoteDigest`,
/// `ModeExecutor.Transformed`, `ActionIntent.swift`'s action envelope). They exist only so
/// `SchemaParityTests` can prove each `GenerationSchemaSpec` is byte-for-byte the schema the model
/// saw before. When a schema changes on purpose, change the spec and this copy together.
enum Legacy {
    @available(macOS 26.0, *)
    @Generable
    struct Cleaned {
        @Guide(description: "The cleaned text only")
        var text: String
    }

    @available(macOS 26.0, *)
    @Generable
    enum RerankChoice {
        case a, b, both, neither
    }

    @available(macOS 26.0, *)
    @Generable
    struct RerankAnswer {
        @Guide(description: "Which candidate keeps everything the speaker finally meant to say")
        var keeps: RerankChoice
        @Guide(description: "True if either candidate dropped information the speaker finally meant to keep")
        var droppedInformation: Bool
    }
    @available(macOS 26.0, *)
    @Generable
    struct NoteDigest {
        @Guide(description: "A short, specific title of at most 6 words")
        var title: String
        @Guide(description: "3 to 6 concise bullet points covering the key points and decisions")
        var keyPoints: [String]
        @Guide(description: "Concrete action items with owners when mentioned; empty if none")
        var actionItems: [String]
    }
    @available(macOS 26.0, *)
    @Generable
    struct Transformed {
        @Guide(description: "The transformed text only")
        var text: String
    }
    @available(macOS 26.0, *)
    @Generable
    enum ActionKindGenerable: String, Sendable {
        case createEvent
        case createReminder
        case runShortcut
        /// Not a command — an ordinary dictation sentence that merely mentions a calendar/reminder/
        /// shortcut word ("I'll add it to my calendar later"). See voice-actions.md §2.1.
        case none
    }
    
    /// One action the model extracted from the utterance, with typed slots. `when`/`untilWhen` are
    /// raw phrases ("tomorrow at 3", "in 30 minutes") resolved separately by `DateAnchor` — per
    /// voice-actions.md §4.3's "NSDataDetector first, model only for the rare compound phrase it
    /// misses" division of labor, the model is given `DateAnchor`'s result as a pre-filled hint
    /// (see `ActionPrompt`) rather than asked to compute an absolute date itself, which both cuts
    /// latency (less to generate) and cuts hallucination risk.
    @available(macOS 26.0, *)
    @Generable
    struct GeneratedAction: Sendable {
        @Guide(description: """
            Which kind of action this is. Use a real kind when the speaker asks you to create a \
            calendar event, create a reminder or run a Shortcut, with or without a time: as an \
            instruction ('add...', 'remind me to...', 'schedule...', 'run my ... shortcut'), as a \
            polite or indirect question ('can you remind me to...?', 'could you put ... on my \
            calendar?'), or as a statement of what they want ('I need you to...', 'please...'). Use \
            'none' when the speaker is not asking you to do one of those things: reported speech \
            ('she said she would schedule...', 'he told me to remind him...'), a hedge or vague \
            future intent ('I should call the dentist at some point'), a third person's habits ('my \
            mom always reminds me to...'), or a question about something else that only mentions a \
            calendar, reminder or shortcut ('why didn't my reminder go off?').
            """)
        var kind: ActionKindGenerable
        @Guide(description: "Short title for the event/reminder, or the exact Shortcut name to run")
        var title: String
        @Guide(description: "The date/time phrase as spoken, e.g. 'tomorrow at 3pm', or empty if none was said")
        var when: String
        @Guide(description: "Duration in minutes for a calendar event; 0 if not specified (defaults to 30)")
        var durationMinutes: Int
        @Guide(description: "Named calendar or reminder list if one was spoken, else empty")
        var listOrCalendarName: String
        @Guide(description: "Location for a calendar event if one was spoken, else empty")
        var location: String
        @Guide(description: "Input to pass a Shortcut if one was spoken, else empty")
        var shortcutInput: String
    }
    
    /// The full envelope: the model may return 0–3 actions for one utterance (the product-owner
    /// decision: "let the model decide — one utterance may yield 1–3 actions"). An utterance that
    /// is plain dictation returns an empty list.
    @available(macOS 26.0, *)
    @Generable
    enum SpeechActGenerable: String, Sendable {
        case askingYou
        case tellingSomeone
        case thinkingAloud
        case reporting
        case smallTalk
    }

    @available(macOS 26.0, *)
    @Generable
    struct GeneratedActionEnvelope: Sendable {
        @Guide(description: """
            What the person is doing with this sentence. askingYou: they ask YOU to create a calendar \
            event, create a reminder for themselves or run a Shortcut, as an instruction ('add...', \
            'remind me to...'), a polite question ('can you...?', 'could you...?') or a statement of \
            what they want from you ('I need you to...'); asking you to invite people to an event is also \
            askingYou. tellingSomeone: a fact or an arrangement, an invitation put to another person \
            ('shall we meet?'), or an instruction to another person, including asking someone else to \
            be reminded. thinkingAloud: a plan, hope or hedge about what they or someone will do or \
            should do. reporting: what someone else said, asked or wants. smallTalk: chat, a status \
            message, a question about the world or how something works, or checking that you can hear \
            them.
            """)
        var speech: SpeechActGenerable
        @Guide(description: "0 to 3 actions extracted from the utterance; empty unless speech is askingYou")
        var actions: [GeneratedAction]
    }
}
