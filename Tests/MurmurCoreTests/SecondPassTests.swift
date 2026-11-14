import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// A second opinion on the filler a first model left behind: a different on-device model is asked again,
/// only for a group whose first-pass text still shows what the existing disfluency detection flags, and only
/// its guarded answer replaces the text. Anything else (unavailable, slow, refused, rejected) keeps the first pass.
@Suite("Second pass on remaining filler", .timeLimit(.minutes(1)), .serialized)
struct SecondPassTests {
    private let leftover = "we could like hide the sidebar for new users and move the menu up front"
    private let clean = "we could hide the sidebar for new users and move the menu up front"

    private func cleaner(
        first: any LanguageModel, second: (any LanguageModel)?, budget: Duration = .seconds(5)
    ) -> SmartCleaner {
        SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
            model: first, health: ModelHealth(), secondOpinion: second)
    }

    private func run(_ cleaner: SmartCleaner, _ text: String, level: CleanupLevel = .polished) async -> SmartCleaner.Output {
        await cleaner.clean(text, options: CleanupOptions(level: level))
    }

    @Test("a group that still shows filler after the first pass gets a second pass, and its text is pasted")
    func secondPassReplaces() async {
        let first = ScriptedModel("first") { $0 }
        let second = ScriptedModel("second") { $0.replacingOccurrences(of: " like ", with: " ") }
        let output = await run(cleaner(first: first, second: second), leftover)
        #expect(!output.text.lowercased().contains(" like "))
        #expect(output.groups.first?.secondPass == .used)
        #expect(first.calls == 1)
        #expect(second.calls == 1)
    }

    @Test("the second pass is timed as its own step, and only when one ran (exact durations: DictationTimeSplitTests)")
    func secondPassTimeIsItsOwn() async throws {
        let slow = ScriptedModel("second", delay: .milliseconds(120)) { $0 }
        let ran = await run(cleaner(first: ScriptedModel("first") { $0 }, second: slow), leftover)
        let trace = try #require(ran.groups.first)
        #expect(trace.secondPass == .kept)
        // The model took at least its 120 ms, and that time is inside the model time too.
        let secondMs = try #require(trace.secondPassMs)
        #expect(secondMs >= 120)
        #expect((trace.modelMs ?? 0) >= secondMs)
        let line = DictationPipeline.cleanupStageLine(groups: ran.groups, cleanupMs: Double(trace.modelMs ?? 0),
            smartMs: trace.modelMs ?? 0, styleMs: 0, modeMs: 0)
        #expect(line.contains("opinionCalls=1"))
        #expect(line.contains("opinionMs=\(secondMs)"))
        let skipped = await run(cleaner(first: ScriptedModel("first") { $0 }, second: ScriptedModel("second") { $0 }), clean)
        #expect(skipped.groups.first?.secondPassMs == nil)
    }

    @Test("clean text after the first pass never reaches the second model")
    func noResidueNoSecondPass() async {
        let first = ScriptedModel("first") { $0 }
        let second = ScriptedModel("second") { $0 }
        let output = await run(cleaner(first: first, second: second), clean)
        #expect(second.calls == 0)
        #expect(output.groups.first?.secondPass == SecondPass.none)
    }

    @Test("the trigger is the existing disfluency detection, not one word")
    func triggerIsGeneral() async {
        let shapes = [
            "basically we should move the menu up front and hide the sidebar for new users",
            "we should hide the sidebar for new users you know and move the menu up front",
            "we should literally hide the sidebar for new users and move the menu up front",
            "we should actually hide the sidebar and we should actually move the menu and actually keep the logo",
        ]
        for shape in shapes {
            let second = ScriptedModel("second") { $0 }
            _ = await run(cleaner(first: ScriptedModel("first") { $0 }, second: second), shape)
            #expect(second.calls == 1, "no second pass for: \(shape.prefix(30))")
        }
    }

    @Test("by default a marker alone does not send a group to the second model; the widened trigger does")
    func markerAloneNeedsTheWidening() async {
        let spoken = "the layout is sort of confusing for new users and we should fix it before the launch"
        for (widened, expected) in [(false, 0), (true, 1)] {
            let second = ScriptedModel("second") { $0 }
            let cleaner = SmartCleaner(
                budget: .seconds(5), correctionBudget: .seconds(5), polishedBudget: .seconds(5), segmentBudget: .seconds(5),
                model: ScriptedModel("first") { $0 }, health: ModelHealth(), widenedSecondPass: widened, secondOpinion: second)
            _ = await run(cleaner, spoken)
            #expect(second.calls == expected, "widened \(widened)")
        }
    }

    @Test("by default an opening said twice does not send a group to the second model; the repeat trigger does, and only a join stands")
    func repeatedOpeningNeedsItsSwitch() async {
        let spoken = "we should cancel the tuesday sync we should cancel the friday retro and use that time for planning"
        // The first model splits the repeat into two sentences, as the fine-tune does, so no filler is left behind.
        let split: @Sendable (String) -> String = { text in
            text.replacingOccurrences(of: " we should cancel the friday", with: ". We should cancel the friday", options: .caseInsensitive)
        }
        // `nil` leaves the switch at its default, which is what the app runs with.
        func cleaner(repeatTrigger: Bool?, second: ScriptedModel) -> SmartCleaner {
            SmartCleaner(
                budget: .seconds(5), correctionBudget: .seconds(5), polishedBudget: .seconds(5), segmentBudget: .seconds(5),
                model: ScriptedModel("first", split), health: ModelHealth(),
                repeatSecondPass: repeatTrigger ?? SmartCleaner.defaultRepeatSecondPass, secondOpinion: second)
        }
        let join: @Sendable (String) -> String = { text in
            text.replacingOccurrences(of: ". We should cancel the friday retro", with: " and the friday retro", options: .caseInsensitive)
        }
        // Off: the second model is not called for a repeat alone, and the first model's text stands.
        let offSecond = ScriptedModel("second", join)
        let off = await run(cleaner(repeatTrigger: nil, second: offSecond), spoken)
        #expect(offSecond.calls == 0)
        #expect(off.text.contains("sync. We should cancel the Friday retro"))
        // On: a second answer that joins the two items is used.
        let joinSecond = ScriptedModel("second", join)
        let joined = await run(cleaner(repeatTrigger: true, second: joinSecond), spoken)
        #expect(joinSecond.calls == 1)
        #expect(joined.groups.first?.secondPass == .used)
        #expect(joined.text.lowercased().contains("tuesday sync and the friday retro"))
        // On: a second answer that only adds a comma is not the join it was asked for, so the first text stands.
        let breakSecond = ScriptedModel("second") { $0.replacingOccurrences(of: "retro and", with: "retro, and") }
        let kept = await run(cleaner(repeatTrigger: true, second: breakSecond), spoken)
        #expect(breakSecond.calls == 1)
        #expect(kept.groups.first?.secondPass == .kept)
        #expect(kept.text == off.text)
    }

    @Test("the markers the instructions ask the model to weigh trigger it, from the one vocabulary the rules own")
    func triggerUsesTheSharedVocabulary() {
        let triggers = [
            "the layout is sort of confusing for new users and we should fix it",
            "we should kind of move the menu up front for new users",
            "I mean the sidebar should go away for new users on the first day",
            "the old flow is actually fine for most teams on the first day",
        ]
        for text in triggers { #expect(SmartCleaner.hasLeftoverFiller(text), "no trigger for: \(text)") }
        let quiet = [
            "so we should move the menu up front for new users and keep the logo",
            "just move the menu and keep the sidebar for the settings page on mobile",
            "we really need to ship the fix before the review on Thursday afternoon",
            "that is right and the numbers match the ledger for the second quarter",
        ]
        for text in quiet { #expect(!SmartCleaner.hasLeftoverFiller(text), "unexpected trigger for: \(text)") }
    }

    @Test("a second answer that a guard rejects keeps the first-pass text and says so")
    func secondPassRejected() async {
        let first = ScriptedModel("first") { $0 }
        // Throws almost everything away: the guards must refuse this.
        let second = ScriptedModel("second") { _ in "Hide it." }
        let output = await run(cleaner(first: first, second: second), leftover)
        #expect(output.groups.first?.secondPass == .kept)
        #expect(output.text.lowercased().contains("move the menu up front"))
    }

    @Test("an unavailable, slow or failing second model keeps the first-pass text")
    func secondPassFails() async {
        let models: [any LanguageModel] = [
            NullLanguageModel(), HangingModel("second"), ThrowingModel("second"),
        ]
        for second in models {
            let output = await run(cleaner(first: ScriptedModel("first") { $0 }, second: second, budget: .milliseconds(400)), leftover)
            #expect(output.text.lowercased().contains("move the menu up front"))
            #expect(output.groups.first?.secondPass != .used)
        }
    }

    @Test("the same model asked twice is not a second opinion")
    func sameModelSkipped() async {
        let only = ScriptedModel("same") { $0 }
        let output = await run(cleaner(first: only, second: ScriptedModel("same") { $0 }), leftover)
        #expect(output.groups.first?.secondPass == SecondPass.none)
        #expect(only.calls == 1)
    }

    @Test("rules-only text and code never get a second pass")
    func noSecondPassForRulesOrCode() async {
        let second = ScriptedModel("second") { $0 }
        let verbatim = await cleaner(first: ScriptedModel("first") { $0 }, second: second)
            .clean(leftover, options: CleanupOptions(level: .verbatim))
        #expect(verbatim.groups.first?.secondPass ?? .none == SecondPass.none)
        var code = CleanupOptions(level: .polished)
        code.isCodeContext = true
        _ = await cleaner(first: ScriptedModel("first") { $0 }, second: second).clean(leftover, options: code)
        #expect(second.calls == 0)
    }

    @Test("a second pass is also made for a group cleaned ahead of time")
    func prewarmedGroupHasItsSecondPass() async {
        let second = ScriptedModel("second") { $0.replacingOccurrences(of: " like ", with: " ") }
        let cleaner = cleaner(first: ScriptedModel("first") { $0 }, second: second)
        let options = CleanupOptions(level: .polished)
        await cleaner.prewarmGroup(leftover, options: options)
        #expect(second.calls == 1)
    }

    @Test("History can say which pass produced the text, with a fixed category and no words")
    func summaryNamesThePass() {
        let used = GroupTrace(words: 14, outcome: .used, guardCode: nil, edited: true, modelMs: 900, secondPass: .used)
        let kept = GroupTrace(words: 14, outcome: .used, guardCode: nil, edited: true, modelMs: 900, secondPass: .kept)
        #expect(CleanupOutcomeSummary(groups: [used], level: .polished)?.code == "ran-second")
        #expect(CleanupOutcomeSummary(groups: [kept], level: .polished)?.code == "ran-second-kept")
        #expect(CleanupOutcomeSummary(code: "ran-second")?.ran == true)
        #expect(CleanupOutcomeSummary(code: "ran-second-kept")?.plainLine.contains("second") == true)
        #expect(CleanupOutcomeSummary(groups: [used], level: .polished)?.plainLine.contains("second") == true)
    }
}

/// Answers `transform(draft)` for every cleanup call, and counts the calls.
/// The measurement fields the second-pass study reads (`GroupTrace.measured`) and the eval-only time budget for the
/// second pass (`SmartCleaner(secondPassBudget:)`). Neither changes what the app does: the app never sets the budget and
/// never retains text.
@Suite("Second pass: measurement fields and the eval budget", .timeLimit(.minutes(1)), .serialized)
struct SecondPassMeasurementTests {
    private let leftover = "we could like hide the sidebar for new users and move the menu up front"

    private func cleaner(
        second: any LanguageModel, retains: Bool = false, secondPassBudget: Duration? = nil
    ) -> SmartCleaner {
        let budget: Duration = .seconds(5)
        return SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
            model: ScriptedModel("first") { $0 }, health: ModelHealth(), retainsRejectedCandidates: retains,
            secondOpinion: second, secondPassBudget: secondPassBudget)
    }

    @Test("an accepted second pass is recorded as answered, with each model's own call time")
    func acceptedSecondPassIsMeasured() async throws {
        let second = ScriptedModel("second", delay: .milliseconds(60)) { $0.replacingOccurrences(of: " like ", with: " ") }
        let output = await cleaner(second: second).clean(leftover, options: CleanupOptions(level: .polished))
        let trace = try #require(output.groups.first)
        #expect(trace.secondPass == .used)
        #expect(trace.measured.secondPassOutcome == .used)
        #expect(trace.measured.secondPassGuard == nil)
        #expect(try #require(trace.measured.secondPassCallMs) >= 60)
        #expect(trace.measured.callMs != nil)
        // The app keeps no text on the trace.
        #expect(trace.measured.firstPassText == nil)
        #expect(trace.measured.secondPassAnswer == nil)
    }

    @Test("the eval keeps both texts so the change can be read and scored")
    func evalKeepsBothTexts() async throws {
        let second = ScriptedModel("second") { $0.replacingOccurrences(of: " like ", with: " ") }
        let output = await cleaner(second: second, retains: true).clean(leftover, options: CleanupOptions(level: .polished))
        let trace = try #require(output.groups.first)
        #expect(trace.measured.firstPassText?.lowercased().contains(" like ") == true)
        #expect(trace.measured.secondPassAnswer?.lowercased().contains(" like ") == false)
        #expect(trace.measured.secondPassAnswer == output.text)
    }

    @Test("a group with no second pass carries no second-pass measurement")
    func noSecondPassNoMeasurement() async throws {
        let second = ScriptedModel("second") { $0 }
        let output = await cleaner(second: second, retains: true).clean(
            "we could hide the sidebar for new users and move the menu up front", options: CleanupOptions(level: .polished))
        let trace = try #require(output.groups.first)
        #expect(trace.secondPass == SecondPass.none)
        #expect(trace.measured.secondPassOutcome == nil)
        #expect(trace.measured.secondPassCallMs == nil)
        #expect(trace.measured.firstPassText == output.text)
    }

    @Test("with the eval budget, a second answer that comes too late is not used and the wait ends at the budget")
    func budgetCutsALateSecondPass() async throws {
        let slow = ScriptedModel("second", delay: .milliseconds(600)) { $0.replacingOccurrences(of: " like ", with: " ") }
        let cut = await cleaner(second: slow, secondPassBudget: .milliseconds(150)).clean(leftover, options: CleanupOptions(level: .polished))
        let trace = try #require(cut.groups.first)
        #expect(trace.secondPass == .kept)
        #expect(trace.measured.secondPassOutcome == .timeout)
        #expect(cut.text.lowercased().contains(" like "))
        #expect(try #require(trace.secondPassMs) < 500)
        // Without the budget (the app), the same slow answer is waited for and used.
        let waited = await cleaner(second: slow).clean(leftover, options: CleanupOptions(level: .polished))
        #expect(waited.groups.first?.secondPass == .used)
    }

    @Test("with the eval budget, an answer that arrives in time is used as before")
    func budgetKeepsAnAnswerInTime() async throws {
        let quick = ScriptedModel("second", delay: .milliseconds(20)) { $0.replacingOccurrences(of: " like ", with: " ") }
        let output = await cleaner(second: quick, secondPassBudget: .milliseconds(2_000)).clean(leftover, options: CleanupOptions(level: .polished))
        #expect(output.groups.first?.secondPass == .used)
        #expect(!output.text.lowercased().contains(" like "))
    }
}

private final class ScriptedModel: LanguageModel {
    private let name: String
    private let transform: @Sendable (String) -> String
    private let count = Mutex(0)
    private let delay: Duration
    init(_ name: String, delay: Duration = .zero, _ transform: @escaping @Sendable (String) -> String) {
        self.name = name
        self.delay = delay
        self.transform = transform
    }
    var calls: Int { count.withLock { $0 } }
    var identifier: String { name }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        count.withLock { $0 += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": transform(draft)]), as: UTF8.self)
    }
}

private final class HangingModel: LanguageModel {
    private let name: String
    init(_ name: String) { self.name = name }
    var identifier: String { name }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return ""
    }
}

private final class ThrowingModel: LanguageModel {
    private let name: String
    init(_ name: String) { self.name = name }
    var identifier: String { name }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        throw LanguageModelError.refused("scripted")
    }
}
