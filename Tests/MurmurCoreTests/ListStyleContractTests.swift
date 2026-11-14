import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// The list style contract (DECISIONS 2026-09-27 "List style contract"): an inline series stays a
/// sentence at Clean and Polished whatever the item count, backend, or whether the model was
/// asked; ordinals, "bullet" and an introduced list ("shopping list,", "three things:") become a
/// list. The prompt carries the contract; `ListStructureGuard` is the safety net.
@Suite("List style contract")
struct ListStyleContractTests {
    // MARK: Inputs

    static let items = ["bread", "cheese", "grapes", "napkins", "cups", "plates", "a blanket", "ice"]

    /// Every inline series shape: 2–8 items; "and" with or without the Oxford comma; no "and".
    static var inlineSeries: [String] {
        var sentences: [String] = []
        for count in 2...8 {
            let chosen = Array(items.prefix(count))
            let head = chosen.dropLast().joined(separator: ", ")
            let last = chosen[count - 1]
            sentences.append("For the picnic we need \(head) and \(last).")
            if count > 2 {
                sentences.append("For the picnic we need \(head), and \(last).")
                sentences.append("For the picnic we need \(chosen.joined(separator: ", ")).")
            }
        }
        return sentences
    }

    static let founder = [
        "I need to get banana, orange and grape.",
        "I need to get banana, orange, grape, mushroom and mango.",
        "i need to get banana orange grape mushroom and mango",
    ]

    static let signalled: [(spoken: String, list: String)] = [
        ("Make a shopping list, 4 apples, 1 orange and 1 Bloody Mary.", "Make a shopping list:\n- 4 apples\n- 1 orange\n- 1 Bloody Mary"),
        ("My to-do list, call the bank, book flights and renew my passport.", "My to-do list:\n- Call the bank\n- Book flights\n- Renew my passport"),
        ("The list is: tomatoes, onions, garlic and basil.", "The list:\n- Tomatoes\n- Onions\n- Garlic\n- Basil"),
        ("Three things: update the deck, email Sarah and book the room.", "Three things:\n- Update the deck\n- Email Sarah\n- Book the room"),
        ("Packing list, tent, stove, lantern, tarp, rope, matches and water.", "Packing list:\n- Tent\n- Stove\n- Lantern\n- Tarp\n- Rope\n- Matches\n- Water"),
        ("My plan is first, fix the bug. Second, write tests. Third, ship it.", "My plan is:\n1. Fix the bug\n2. Write tests\n3. Ship it"),
        ("Groceries bullet milk bullet eggs bullet bread", "Groceries:\n- Milk\n- Eggs\n- Bread"),
    ]

    // MARK: Rules

    @Test("rules keep every inline series a sentence (2–8 items, and/Oxford/none)", arguments: inlineSeries + founder)
    func rulesKeepInlineSeries(_ spoken: String) {
        for level in [CleanupLevel.clean, .polished] {
            let text = TextCleaner(options: CleanupOptions(level: level)).clean(spoken).text
            #expect(!text.contains("\n"), "\(level): \(text)")
        }
    }

    @Test("rules format signalled lists: intros, ordinals, bullet")
    func rulesFormatSignalledLists() {
        for (spoken, list) in Self.signalled {
            #expect(TextCleaner(options: CleanupOptions(level: .clean)).clean(spoken).text == list)
        }
    }

    @Test("an unresolved correction inside an introduced series is left for the model; to-do verbs are not cues")
    func introWithCorrection() {
        let cleaner = TextCleaner(options: CleanupOptions(level: .clean))
        let corrected = cleaner.clean("We need three things, uh, a logo, a landing page, no, actually two things, a logo and a landing page.").text
        #expect(!corrected.contains("\n"), "\(corrected)")
        #expect(cleaner.clean("My to-do list, cancel the gym, call mom and pay rent.").text
            == "My to-do list:\n- Cancel the gym\n- Call mom\n- Pay rent")
    }

    // MARK: Guard

    @Test("the guard fires only when list structure is added to an unstructured draft")
    func guardScope() {
        let draft = "I need to get banana, orange, grape, mushroom and mango."
        let listed = "I need to get:\n- Banana\n- Orange\n- Grape\n- Mushroom\n- Mango"
        #expect(ListStructureGuard.violation(answer: listed, draft: draft) == "list-without-signal")
        #expect(ListStructureGuard.violation(answer: "I need to get:\n1. Banana\n2. Orange", draft: draft) != nil)
        #expect(ListStructureGuard.violation(answer: "I need to get:\nBanana\nOrange", draft: draft) != nil)
        #expect(ListStructureGuard.violation(answer: draft, draft: draft) == nil)
        #expect(ListStructureGuard.violation(answer: "I need banana, orange and mango.", draft: draft) == nil)
        // A signalled list (the rules already laid it out) is never judged by this guard.
        let groceries = "Groceries:\n- Milk\n- Eggs\n- Bread"
        #expect(ListStructureGuard.violation(answer: groceries, draft: groceries) == nil)
        #expect(ListStructureGuard.violation(answer: "Groceries: milk, eggs and bread.", draft: groceries) == nil)
        #expect(ListStructureGuard.violation(answer: "First line\nsecond line", draft: "First line\nsecond line") == nil)
    }

    @Test("a guard rejection logs why=rejected-by-guard(list-without-signal)")
    func logLabel() {
        #expect(ModelOutcome.logLabel(usedModel: false, rejection: ListStructureGuard.reason)
            == "rejected-by-guard(list-without-signal)")
    }

    // MARK: Same outcome whatever the backend

    /// Clean with the model asked only when the hints fire, Clean with the model always asked,
    /// and Polished (always asked).
    static let configurations: [(CleanupLevel, SmartCleaner.CleanGate)] = [(.clean, .heuristic), (.clean, .always), (.polished, .heuristic)]

    @Test("inline series: rules-only, a listing model and an obedient model paste the same text", arguments: inlineSeries + founder)
    func inlineSeriesSameEverywhere(_ spoken: String) async {
        for (level, gate) in Self.configurations {
            let options = CleanupOptions(level: level)
            let rules = await SmartCleaner(cleanGate: gate, model: NullLanguageModel(), health: ModelHealth()).clean(spoken, options: options)
            let lister = ScriptedCleanupModel(answer: ScriptedCleanupModel.bulletEverySeries)
            let listed = await SmartCleaner(cleanGate: gate, model: lister, health: ModelHealth()).clean(spoken, options: options)
            let obedient = await SmartCleaner(cleanGate: gate, model: ScriptedCleanupModel(answer: { $0 }), health: ModelHealth())
                .clean(spoken, options: options)
            #expect(!rules.text.contains("\n"))
            #expect(listed.text == rules.text, "\(level)/\(gate): \(listed.text)")
            #expect(obedient.text == rules.text, "\(level)/\(gate): \(obedient.text)")
            if lister.answeredWithList {
                #expect(listed.rejection == ListStructureGuard.reason)
                #expect(!listed.usedModel)
            }
        }
    }

    @Test("the founder's five items: the model is asked, bullets it, and the sentence is pasted")
    func founderCase() async {
        let spoken = "I need to get banana, orange, grape, mushroom and mango."
        let lister = ScriptedCleanupModel(answer: ScriptedCleanupModel.bulletEverySeries)
        let output = await SmartCleaner(model: lister, health: ModelHealth()).clean(spoken, options: CleanupOptions(level: .clean))
        #expect(lister.callCount == 1)
        #expect(output.text == spoken)
        #expect(ModelOutcome.logLabel(usedModel: output.usedModel, rejection: output.rejection) == "rejected-by-guard(list-without-signal)")
    }

    @Test("signalled lists stay lists whatever the backend")
    func signalledListsSameEverywhere() async {
        for (spoken, list) in Self.signalled {
            for (level, gate) in Self.configurations {
                let options = CleanupOptions(level: level)
                let rules = await SmartCleaner(cleanGate: gate, model: NullLanguageModel(), health: ModelHealth()).clean(spoken, options: options)
                let model = await SmartCleaner(cleanGate: gate, model: ScriptedCleanupModel(answer: { $0 }), health: ModelHealth())
                    .clean(spoken, options: options)
                #expect(rules.text == list, "\(level)/\(gate): \(rules.text)")
                #expect(model.text == list, "\(level)/\(gate): \(model.text)")
                #expect(model.rejection != ListStructureGuard.reason)
            }
        }
    }

    // MARK: Prompts and training data

    @Test("every Clean/Polished prompt states the contract")
    func promptsStateContract() {
        let prompts = [
            SmartCleaner.cleanupInstructions(confidenceGuided: false),
            SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true),
        ]
        for prompt in prompts {
            #expect(prompt.contains("A series inside a sentence stays in that sentence"))
            #expect(prompt.contains("Never add line breaks, bullets or numbering"))
            #expect(prompt.contains("Output: For the party we need cups, plates, napkins and ice."))
        }
        for level in [CleanupLevel.clean, .polished] {
            #expect(CompactCleanupPrompt.systemText(level: level).contains("never add line breaks, bullets or numbering"))
        }
        #expect(CompactCleanupPrompt.version == "compact-v2")
    }

    @Test("training pairs that bullet an unsignalled series are rejected; signalled lists pass")
    func trainingPairs() {
        let inline = TrainingPairCheck.check(
            raw: "for the trip we need the tent sleeping bags and a lantern",
            target: "For the trip we need:\n- The tent\n- Sleeping bags\n- A lantern", level: .clean)
        #expect(inline.rejection == ListStructureGuard.reason)
        let prose = TrainingPairCheck.check(
            raw: "for the trip we need the tent, sleeping bags and a lantern",
            target: "For the trip we need the tent, sleeping bags and a lantern.", level: .clean)
        #expect(prose.rejection == nil)
        let signalled = TrainingPairCheck.check(
            raw: "packing list, the tent, sleeping bags and a lantern",
            target: "Packing list:\n- The tent\n- Sleeping bags\n- A lantern", level: .clean)
        #expect(signalled.rejection == nil)
    }
}

/// A cleanup model that answers `answer(draft)` for the `Cleaned` schema and fails anything
/// else (so a rerank call never decides a test).
final class ScriptedCleanupModel: LanguageModel {
    private let answer: @Sendable (String) -> String
    private let calls = Mutex(0)
    private let listed = Mutex(false)

    init(answer: @escaping @Sendable (String) -> String) {
        self.answer = answer
    }

    var callCount: Int { calls.withLock { $0 } }
    /// Whether any answer so far had a line break.
    var answeredWithList: Bool { listed.withLock { $0 } }
    var identifier: String { "scripted" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.cleanedSchema.name else { throw LanguageModelError.unavailable("scripted") }
        calls.withLock { $0 += 1 }
        let draft = prompt.replacingOccurrences(of: "^Transcript: ", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\nOutput:$", with: "", options: .regularExpression)
        let text = answer(draft)
        if text.contains("\n") { listed.withLock { $0 = true } }
        return CompactCleanupPrompt.answerJSON(text)
    }

    /// The failure the founder saw: every comma series (≥ 2 commas, or "A, B and C") becomes
    /// "lead:\n- A\n- B…", capitalised; anything else is returned unchanged.
    static let bulletEverySeries: @Sendable (String) -> String = { draft in
        let body = draft.trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
        guard let comma = body.firstIndex(of: ",") else { return draft }
        let beforeFirst = body[..<comma]
        guard let split = beforeFirst.range(of: " ", options: .backwards) else { return draft }
        let lead = String(beforeFirst[..<split.lowerBound])
        let series = String(body[split.upperBound...])
        let parts = series.replacingOccurrences(of: ", and ", with: ", ").replacingOccurrences(of: " and ", with: ", ")
            .components(separatedBy: ", ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return draft }
        return lead + ":\n" + parts.map { "- " + $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "\n")
    }
}
