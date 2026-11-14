import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Task 135: a request is a request however it is phrased. Someone who held the action key and
/// said "could you ...?" is asking the assistant, not wondering aloud, and the founder's rule is
/// that no rule decides intent for an action started on purpose: the model sees every sentence.
/// A reminder or event with no time is a complete request. The utterances here are invented for
/// this task (Evals/actions-intent-dev.json holds the larger set measured with the real model).
@Suite("Action intent: requests phrased as questions or politely")
struct ActionIntentTests {
    // MARK: - No rule vetoes before the model

    /// Polite and indirect requests, bare and as Whisper writes them.
    static let politeRequests = [
        "Could you remind me to pick up the dry cleaning?",
        "Would you remind me to refill the water filter?",
        "Will you remind me to renew my passport?",
        "Could you add a birthday party to my calendar?",
        "Would you put the school pickup on my calendar tomorrow at 3 30 pm?",
        "Could you add oat milk to my groceries list?",
        "I'd like you to add lunch with Dad tomorrow at 12 30.",
        "I would like you to put a haircut on my calendar.",
        "Do you mind adding sunscreen to the packing list?",
        "Would you mind putting the book club on my calendar?",
        "Is there any chance you could remind me to stretch?",
        "um could you just put the book club on my calendar",
        "uh will you please add batteries to the hardware store list",
    ]

    /// Sentences a rule used to decide were not commands. The model now decides every one.
    static let notRequests = [
        "Does this app let you set a reminder for the weekend?",
        "Why didn't my reminder go off yesterday?",
        "Would it be better to schedule the call after lunch?",
        "Can you believe how late the train was?",
        "did you add the meeting to the calendar yesterday",
        "She asked if you could add the invoice to the calendar.",
        "He said could you remind him about the form tomorrow.",
        "she said please add it to the calendar",
        "I told him you could run that shortcut yourself.",
        "Should I put the dentist on my calendar or just remember it?",
        "I should really call the dentist at some point",
        "my mom always reminds me to call her",
    ]

    @Test("the model is asked about every sentence: no rule drops one first", arguments: politeRequests + notRequests)
    func everySentenceReachesTheModel(_ utterance: String) async {
        let (output, model) = await extract(utterance, json: #"{"actions": []}"#)
        #expect(model.callCount == 1, "a rule decided before the model was asked: \(utterance)")
        #expect(output.result == .notAnAction)
    }

    // MARK: - Surviving validation

    private func extract(
        _ utterance: String, json: String, library: [String] = []
    ) async -> (ActionExtractor.Output, StubActionModel) {
        let model = StubActionModel(json: json)
        let extractor = ActionExtractor(model: model, shortcutLibrary: { library }, health: ModelHealth())
        let context = DateContext(now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)
        return (await extractor.extract(utterance, context: context), model)
    }

    static func envelope(kind: String, title: String, when: String = "", list: String = "") -> String {
        """
        {"speech": "askingYou", "actions": [{"kind": "\(kind)", "title": "\(title)", "when": "\(when)", "durationMinutes": 0, \
        "listOrCalendarName": "\(list)", "location": "", "shortcutInput": ""}]}
        """
    }

    @Test("a polite question reaches the model and its reminder comes back", arguments: [
        "Could you remind me to pick up the dry cleaning?",
        "Would you remind me to refill the water filter?",
        "Will you remind me to renew my passport?",
        "I'd like you to remind me to stretch my back.",
    ])
    func politeReminderReachesTheModel(_ utterance: String) async {
        let (output, model) = await extract(utterance, json: Self.envelope(kind: "createReminder", title: "Call"))
        #expect(model.callCount == 1, "the gate dropped it before the model: \(utterance)")
        #expect(output.usedModel)
        guard case .actions(let actions) = output.result else {
            Issue.record("expected an action, got \(output.result)")
            return
        }
        #expect(actions.map(\.kind) == [.createReminder])
    }

    @Test("a reminder with no time is a whole action: validation and the safety screen keep it")
    func reminderWithoutATimeSurvives() async {
        let (output, _) = await extract(
            "Can you remind me to bring the charger?", json: Self.envelope(kind: "createReminder", title: "Bring the charger"))
        guard case .actions(let actions) = output.result else {
            Issue.record("expected an action, got \(output.result)")
            return
        }
        #expect(actions.first?.title == "Bring the charger")
        #expect(actions.first?.start == nil)
    }

    @Test("an event with no time is kept too, for the card to fill in")
    func eventWithoutATimeSurvives() async {
        let (output, _) = await extract(
            "Could you add a birthday party to my calendar?", json: Self.envelope(kind: "createEvent", title: "Birthday party"))
        guard case .actions(let actions) = output.result else {
            Issue.record("expected an action, got \(output.result)")
            return
        }
        #expect(actions.map(\.kind) == [.createEvent])
        #expect(actions.first?.start == nil)
    }

    @Test("a polite request for a Shortcut that is installed runs through the library check")
    func politeShortcutRequest() async {
        let (output, model) = await extract(
            "Could you run my night mode shortcut?", json: Self.envelope(kind: "runShortcut", title: "night mode"),
            library: ["Night Mode", "Text Last Image"])
        #expect(model.callCount == 1)
        guard case .actions(let actions) = output.result else {
            Issue.record("expected an action, got \(output.result)")
            return
        }
        #expect(actions.first?.shortcutName == "Night Mode")
    }

    @Test("a polite request to change something that exists is still refused before the model")
    func politeEditStillRefused() async {
        let (output, model) = await extract("Could you cancel my 3 pm meeting?", json: Self.envelope(kind: "createEvent", title: "x"))
        #expect(model.callCount == 0)
        guard case .refused = output.result else {
            Issue.record("expected a refusal, got \(output.result)")
            return
        }
    }

    @Test("when the model says it is not a request, the result is not an action, even if it lists one")
    func modelDeclines() async {
        // Not an empty list: the model lists an event for a sentence it calls thinking aloud.
        let json = """
            {"speech": "thinkingAloud", "actions": [{"kind": "createEvent", "title": "Forty meetings", "when": "", \
            "durationMinutes": 0, "listOrCalendarName": "", "location": "", "shortcutInput": ""}]}
            """
        let (output, model) = await extract("Could you imagine scheduling forty meetings in one week", json: json)
        #expect(model.callCount == 1)
        #expect(output.result == .notAnAction)
    }

    @Test("an answer that lists actions but does not say what the person was doing is not a request")
    func missingSpeechIsNotARequest() async {
        let json = """
            {"actions": [{"kind": "createEvent", "title": "Party", "when": "saturday", "durationMinutes": 0, \
            "listOrCalendarName": "", "location": "", "shortcutInput": ""}]}
            """
        let (output, model) = await extract("put the party on saturday on my calendar", json: json)
        #expect(model.callCount == 1)
        #expect(output.result == .notAnAction)
    }

    @Test("a sentence the model calls anything but a request to it has no actions, whatever else it wrote")
    func speechDecidesBeforeActions() async {
        for speech in ["tellingSomeone", "thinkingAloud", "reporting", "smallTalk"] {
            let json = """
                {"speech": "\(speech)", "actions": [{"kind": "createEvent", "title": "Party", "when": "saturday", \
                "durationMinutes": 0, "listOrCalendarName": "", "location": "", "shortcutInput": ""}]}
                """
            let (output, _) = await extract("the party is on saturday", json: json)
            #expect(output.result == .notAnAction, "\(speech)")
        }
        let asking = """
            {"speech": "askingYou", "actions": [{"kind": "createEvent", "title": "Party", "when": "saturday", \
            "durationMinutes": 0, "listOrCalendarName": "", "location": "", "shortcutInput": ""}]}
            """
        let (output, _) = await extract("put the party on saturday on my calendar", json: asking)
        guard case .actions(let actions) = output.result else {
            Issue.record("expected an action, got \(output.result)")
            return
        }
        #expect(actions.map(\.kind) == [.createEvent])
    }

    // MARK: - What the model is told

    @Test("the instructions treat the key press as deliberate and a question-shaped request as a request")
    func instructionsFrameTheRequest() {
        let text = ActionExtractor.instructions
        #expect(!text.contains("by mistake"), "the trigger is deliberate now")
        #expect(!text.localizedCaseInsensitiveContains("when in doubt"))
        #expect(text.contains("deliberately"))
        #expect(text.contains("polite"))
        #expect(text.contains("no time"), "a reminder with no time is complete")
        #expect(text.contains("Undo"), "what makes acting safe is Undo and the Shortcut card, not a rule")
    }

    @Test("where an item goes is the person's to say: the instructions leave it empty, say why, and show it empty more often than named")
    func instructionsLeaveThePlaceEmpty() {
        let text = ActionExtractor.instructions
        #expect(text.contains("When they name none, leave it empty"))
        #expect(text.contains("nothing is saved"), "the reason is given: a place that isn't there stops the save")
        let shownEmpty = text.components(separatedBy: "\"listOrCalendarName\" empty").count - 1
        let shownNamed = text.components(separatedBy: "\"listOrCalendarName\" \"").count - 1
        #expect(shownNamed == 1, "one worked example names a list, so the model sees how")
        #expect(shownEmpty > shownNamed, "no example can be read as the usual answer")
        #expect(text.contains("Keep the verb"), "a title says what to do, not only what with")
    }

    @Test("the schema's kind description no longer files every question under 'none'")
    func schemaDescriptionAgrees() {
        let json = GeneratedActionEnvelope.generationSchema.json
        #expect(!json.contains("a question, or a statement"))
        #expect(json.contains("polite"))
    }
}

/// A model that answers every call with one JSON string and counts the calls.
private final class StubActionModel: LanguageModel {
    private let json: String
    private let calls = Mutex(0)

    init(json: String) { self.json = json }

    var callCount: Int { calls.withLock { $0 } }
    var identifier: String { "stub-action" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        calls.withLock { $0 += 1 }
        return json
    }
}
