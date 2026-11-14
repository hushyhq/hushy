import Foundation
import Synchronization
import Testing
@testable import MurmurCore

private final class CapturingIntentModel: LanguageModel {
    let identifier = "capturing-intent"
    let prompts = Mutex<[String]>([])
    let scriptedAnswer: String?
    init(answer: String? = nil) { scriptedAnswer = answer }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec,
                 options: LanguageModelOptions) async throws -> String {
        prompts.withLock { $0.append(prompt) }
        let transcript = String(prompt.dropFirst("Transcript: ".count).dropLast("\nOutput:".count))
        let data = try JSONSerialization.data(withJSONObject: ["text": scriptedAnswer ?? transcript])
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Intent cleanup routing")
struct IntentCleanerTests {
    private func run(_ raw: String, answer: String, voiceCommands: Bool = true) async -> (String, [String]) {
        let model = CapturingIntentModel(answer: answer)
        let cleaner = SmartCleaner(model: model, wholeTranscript: { true })
        let options = CleanupOptions(level: .clean, voiceCommandsEnabled: voiceCommands)
        let output = await cleaner.clean(raw, options: options, strategy: .model)
        #expect(output.usedModel)
        return (output.text, model.prompts.withLock { $0 })
    }

    @Test("the whole transcript reaches one model call and still produces a guarded output")
    func oneCall() async {
        let model = CapturingIntentModel()
        let cleaner = SmartCleaner(model: model, wholeTranscript: { true })
        let raw = "We need to send the draft to the team on Monday. Then we should review their notes on Tuesday. "
            + "If anyone needs more time, they can say so before the meeting. I will bring the revised list and the budget."
        let output = await cleaner.clean(raw, options: CleanupOptions(level: .clean), strategy: .model)
        #expect(model.prompts.withLock { $0 } == [IntentCleanupPrompt.user(transcript: raw)])
        #expect(!output.text.isEmpty)
        #expect(output.groups.count == 1)
    }

    @Test("spoken layout reaches the model as breaks and survives a flattened answer")
    func spokenLayout() async {
        let (line, linePrompts) = await run("Hi Sam, new line, thanks for the update.",
            answer: "Hi Sam, thanks for the update.")
        #expect(line.contains("\n"))
        #expect(linePrompts == [IntentCleanupPrompt.user(transcript: "Hi Sam\nthanks for the update.")])

        let (paragraph, paragraphPrompts) = await run("That covers the intro. New paragraph. Now the pricing.",
            answer: "That covers the intro. Now the pricing.")
        #expect(paragraph.contains("\n\n"))
        #expect(paragraphPrompts == [IntentCleanupPrompt.user(transcript: "That covers the intro.\n\nNow the pricing.")])
    }

    @Test("disabled voice commands remain literal")
    func disabledVoiceCommands() async {
        let raw = "Hi Sam, new line, thanks for the update."
        let (text, prompts) = await run(raw, answer: raw, voiceCommands: false)
        #expect(!text.contains("\n"))
        #expect(text.contains("new line"))
        #expect(prompts == [IntentCleanupPrompt.user(transcript: raw)])
    }

    @Test("spoken lists are formatted after the model")
    func lists() async {
        let (bullets, _) = await run("Create a to-do list, tomatoes, onions, beans, ketchup, and Roma tomatoes.",
            answer: "Create a to-do list, tomatoes, onions, beans, ketchup, and Roma tomatoes.")
        #expect(bullets.contains("\n- Tomatoes\n- Onions\n- Beans\n- Ketchup\n- Roma tomatoes"))
        let (numbered, _) = await run("My plan is first, fix the bug. Second, write tests. Third, ship it.",
            answer: "My plan is first, fix the bug. Second, write tests. Third, ship it.")
        #expect(numbered.contains("\n1. Fix the bug\n2. Write tests\n3. Ship it"))
    }

    @Test("intent model may choose list layout when the speaker sets one up")
    func modelListLayout() async {
        let raw = "My to do list is call the bank pay the electricity bill and book the dentist."
        let answer = "My to do list:\n- Call the bank\n- Pay the electricity bill\n- Book the dentist"
        let (text, _) = await run(raw, answer: answer)
        #expect(text.contains("- Call the bank\n- Pay the electricity bill\n- Book the dentist"))
    }

    @Test("an ordinary series remains prose when the model chooses prose")
    func ordinarySeries() async {
        let raw = "I bought apples and oranges at the store."
        let (text, _) = await run(raw, answer: raw)
        #expect(!text.contains("\n- "))
    }

    @Test("spoken numbers, times and dates are written after the model")
    func typedValues() async {
        let raw = "It took twenty-five minutes for thirty people on April the first at ten PM."
        let (text, _) = await run(raw, answer: raw)
        #expect(text.contains("25 minutes"))
        #expect(text.contains("30 people"))
        #expect(text.contains("April 1"))
        #expect(text.contains("10:00pm"))
        let (otherDate, _) = await run("The meeting is the twenty third of March.",
            answer: "The meeting is the twenty third of March.")
        #expect(otherDate.contains("March 23"))
    }

    @Test("formatting does not put back a retracted phrase")
    func retraction() async {
        let (text, _) = await run("Bring apples, no, bring oranges and thirty pears.",
            answer: "Bring oranges and thirty pears.")
        #expect(text.contains("30 pears"))
        #expect(!text.lowercased().contains("apples"))
    }
}
