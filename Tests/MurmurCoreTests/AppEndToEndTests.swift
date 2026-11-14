import Foundation
import Testing
@testable import MurmurCore

private struct AppE2EFixture: Decodable {
    struct Scenario: Decodable {
        let id: String
        let spoken: String
        let mustContain: [String]
        let mustNotContain: [String]
        /// The scenario's "must not contain" needs the real model (a spoken correction); the echo model here cannot show it.
        let needsModel: Bool?
    }
    let version: Int
    let scenarios: [Scenario]

    static func load() throws -> Self {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/app-e2e.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

/// A deterministic cleanup reply. It implements the production model protocol, but does not
/// claim to predict the on-device model's wording. The production rules and guards still run.
private struct EchoCleanupModel: LanguageModel {
    let identifier = "scripted-e2e-echo"
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec,
                 options: LanguageModelOptions) async throws -> String {
        guard let start = prompt.range(of: "Transcript: ")?.upperBound,
              let end = prompt.range(of: "\nOutput:", range: start..<prompt.endIndex)?.lowerBound else {
            throw LanguageModelError.malformedOutput("scripted fixture has no transcript")
        }
        return CompactCleanupPrompt.answerJSON(String(prompt[start..<end]))
    }
}

private struct NoAudioTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// One private clipboard and one simulated target. No global pasteboard or keyboard event exists.
@MainActor
private final class SimulatedTarget: DeliveryPaster {
    enum Route: String, CaseIterable { case acceptsInsert, pasteOnly, refuses, noField, moved }
    let route: Route
    private(set) var landed = ""
    private(set) var clipboard = "private original"
    private var staged = false
    private var held: PasteLanding?
    init(_ route: Route) { self.route = route }

    func paste(_ text: String, pressReturn: Bool, awaitLanding: PasteLanding?, hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome {
        await BoundDelivery.perform(pressReturn: pressReturn, isCurrent: { true }, hasFocus: hasFocus,
            prepareClipboard: { self.clipboard = text; self.staged = true; self.held = awaitLanding; return true },
            clipboardIsOwned: { self.staged && self.clipboard == text },
            paste: {
                guard self.route != .refuses else { return false }
                self.landed += self.clipboard
                return true
            }, waitBeforeReturn: {}, sendReturn: { true })
    }
    func finishLanding(_ landing: PasteLanding, as settlement: LandingSettlement) {
        guard landing == held else { return }
        held = nil
        if settlement == .unconfirmed { staged = false }
    }
    func sendReturn(hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome { .dispatchFailed }
    func copyForManualPaste(_ text: String) { clipboard = text; staged = false }
    func settle() { if staged { clipboard = "private original"; staged = false } }
}

@Suite("App end to end: recogniser output through target")
struct AppEndToEndTests {
    @Test("uncertain delivery keeps the already staged text unless the landing count confirms")
    @MainActor func uncertainClipboardOutcome() async {
        let words = "Vela folds the amber sail."
        let unconfirmed = SimulatedTarget(.pasteOnly)
        let unknown = await TargetedDelivery.deliver(
            text: words, pressReturn: false, answer: .unknown, check: { .unchanged },
            landing: { LandingProbe(characterCount: 2, selectedLength: 0) }, paster: unconfirmed)
        unconfirmed.settle()
        #expect(unknown == .unknownNotLanded)
        #expect(unconfirmed.clipboard == words)

        let confirmed = SimulatedTarget(.pasteOnly)
        var count = 2
        let landed = await TargetedDelivery.deliver(
            text: words, pressReturn: false, answer: .unknown, check: { .unchanged },
            landing: {
                defer { count = 3 }
                return LandingProbe(characterCount: count, selectedLength: 0)
            }, paster: confirmed)
        confirmed.settle()
        #expect(landed == .unknownConfirmed)
        #expect(confirmed.clipboard == "private original")

        let secure = SimulatedTarget(.pasteOnly)
        let held = await TargetedDelivery.deliver(
            text: words, pressReturn: false, answer: .unknown, check: { .secureField(change: .field) },
            landing: { nil }, paster: secure)
        #expect(held == .heldForSecureField(.field))
        #expect(secure.clipboard == "private original")
        #expect(secure.landed.isEmpty)
    }

    private func output(_ spoken: String, category: AppCategory, bundleID: String,
                        tones: ToneSettings, taught: Bool = false) async -> String {
        let plan = tones.plan(for: category, bundleID: bundleID)
        let personalizer = taught ? Personalizer(dictionary: [DictionaryEntry(term: "Zindle", soundsLike: ["zindel"])]) : Personalizer()
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: plan.level),
                                        personalizer: personalizer, style: plan.style, tone: plan.tone)
        let pipeline = DictationPipeline(transcriber: NoAudioTranscriber(),
                                         cleaner: SmartCleaner(model: EchoCleanupModel()))
        return await pipeline.clean(spoken, settings: settings, strategy: .model).text
    }

    @Test("fixture scenarios and simulated delivery routes")
    @MainActor func scenarios() async throws {
        let fixture = try AppE2EFixture.load()
        #expect(fixture.version == 1)
        #expect(fixture.scenarios.count >= 10)
        for scenario in fixture.scenarios {
            let asSpoken = scenario.id == "as-spoken"
            var tones = ToneSettings.standard
            if asSpoken { tones.choice = .asSpoken }
            let text = await output(scenario.spoken, category: .workMessages,
                                    bundleID: "test.work.messages", tones: tones,
                                    taught: scenario.id == "taught-word")
            for phrase in scenario.mustContain { #expect(text.localizedCaseInsensitiveContains(phrase), "\(scenario.id): \(phrase)") }
            for phrase in scenario.mustNotContain where scenario.needsModel != true { #expect(!text.localizedCaseInsensitiveContains(phrase), "\(scenario.id): \(phrase)") }
            for route in SimulatedTarget.Route.allCases {
                let target = SimulatedTarget(route)
                let result = await TargetedDelivery.deliver(text: text, pressReturn: false,
                    hasTextInput: route != .noField,
                    check: { route == .moved ? .changed(.field) : .unchanged },
                    paster: target)
                target.settle()
                if route == .acceptsInsert || route == .pasteOnly {
                    #expect(result.reachedTarget, "\(scenario.id) \(route)")
                    #expect(target.landed == text)
                    #expect(target.clipboard == "private original")
                } else {
                    #expect(!result.reachedTarget, "\(scenario.id) \(route)")
                    #expect(target.landed.isEmpty)
                    #expect(target.clipboard == text)
                }
            }
        }
    }

    @Test("kind, tone, and per-app precedence on the same invented sentence")
    @MainActor func toneMatrix() async throws {
        let fixture = try AppE2EFixture.load()
        let spoken = try #require(fixture.scenarios.first(where: { $0.id == "tones" })?.spoken)
        var table = ["| App kind | Tone | Route | Result | Reason |", "|---|---|---|---|---|"]
        let kinds: [(String, AppCategory)] = [
            ("test.work.messages", .workMessages), ("test.email", .email),
            ("test.personal.messages", .personalMessages), ("test.ai.tool", .aiPrompts),
            ("test.other", .other), ("test.overridden", .workMessages)
        ]
        for (id, category) in kinds {
            for tone in DictationTone.allCases {
                var settings = ToneSettings.standard.settingTone(tone, for: StyleContext.from(category)!)
                if id == "test.overridden" { settings = settings.settingApp(.tone(.casual), bundleIDs: [id]) }
                let text = await output(spoken, category: category, bundleID: id, tones: settings)
                #expect(text.localizedCaseInsensitiveContains("paper kite"), "\(id)")
                #expect(text.localizedCaseInsensitiveContains("bell"), "\(id)")
                let effective = settings.plan(for: category, bundleID: id).tone
                if effective == .professional { #expect(text.contains("do not"), "\(id)") }
                if effective == .casual { #expect(text.contains("don't"), "\(id)") }
                for route in SimulatedTarget.Route.allCases {
                    let target = SimulatedTarget(route)
                    let result = await TargetedDelivery.deliver(text: text, pressReturn: false,
                        hasTextInput: route != .noField,
                        check: { route == .moved ? .changed(.field) : .unchanged }, paster: target)
                    target.settle()
                    let shouldLand = route == .acceptsInsert || route == .pasteOnly
                    let correct = shouldLand
                        ? result.reachedTarget && target.landed == text && target.clipboard == "private original"
                        : !result.reachedTarget && target.landed.isEmpty && target.clipboard == text
                    #expect(correct, "\(id) \(tone) \(route)")
                    print("app-e2e | \(id) | \(tone.rawValue) | \(route.rawValue) | \(correct ? "PASS" : "FAIL") | \(result.logSummary)")
                    table.append("| \(id) | \(tone.rawValue) | \(route.rawValue) | \(correct ? "PASS" : "FAIL") | \(result.logSummary) |")
                }
            }
        }
        let report = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/app-e2e-headless.md")
        try (table.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        let moved = ToneSettings.standard.settingTone(.professional, for: .personalMessages)
        let movedText = await output(spoken, category: .personalMessages, bundleID: "test.work.messages", tones: moved)
        #expect(movedText.contains("do not"))
    }
}
