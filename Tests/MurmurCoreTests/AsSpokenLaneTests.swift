import Foundation
import Synchronization
import Testing

@testable import MurmurCore

private struct LaneApps: InstalledApps {
    let ids: Set<String>
    func isInstalled(_ bundleID: String) -> Bool { ids.contains(bundleID) }
    func displayName(_ bundleID: String) -> String? { ids.contains(bundleID) ? bundleID : nil }
}

/// A model that must never be asked: an As spoken dictation runs on the rules only.
private final class RefusingModel: LanguageModel, @unchecked Sendable {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    var identifier: String { "as-spoken-lane-test" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        count.withLock { $0 += 1 }
        throw LanguageModelError.malformedOutput("an As spoken dictation asked the model")
    }
}

private struct NoSpeech: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// TRY-93 follow-up (founder, 2026-10-28: "We need 'as spoken' so that someone can have it as spoken in a tool such as
/// notes or Google Docs"): As spoken is a lane. An app placed there is dictated word for word, at the level the
/// dictation decides at key-down; every other app keeps its tone; "every app" stays as one switch on top.
@Suite("As spoken lane")
struct AsSpokenLaneTests {
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let notes = "com.apple.Notes"
    private static let mail = "com.apple.mail"
    private let mac = LaneApps(ids: [slack, notes, mail, "com.apple.MobileSMS", "com.anthropic.claudefordesktop"])

    private func board(_ settings: ToneSettings, prompt: Bool = true) -> ToneBoard {
        ToneBoard.make(settings: settings, installed: mac, promptAvailable: prompt)
    }

    private func onAsSpoken(_ id: String) throws -> ToneSettings {
        let app = try #require(board(.standard).app(id: id))
        return ToneBoard.moving(app, to: .asSpoken, in: .standard, promptAvailable: true)
    }

    @Test("an app moved to As spoken is word for word; every other app keeps its tone")
    func placedAppIsVerbatim() throws {
        let settings = try onAsSpoken(Self.notes)
        #expect(settings.appChoices == [Self.notes: .asSpoken])
        let plan = settings.plan(for: .documents, bundleID: Self.notes)
        #expect(plan.level == .verbatim && plan.tone == nil && plan.style == nil)
        #expect(settings.register(for: .documents, bundleID: Self.notes) == nil)
        #expect(settings.dictationLevel(for: Self.notes) == .verbatim)
        // Nothing else moved: Mail is still Professional and polished, Slack still Refined.
        #expect(settings.dictationLevel(for: Self.mail) == .polished)
        #expect(settings.plan(for: .email, bundleID: Self.mail).tone == .professional)
        #expect(settings.register(for: .workMessages, bundleID: Self.slack) == nil)
        #expect(settings.dictationLevel(for: nil) == .polished && settings.dictationLevel == .polished)
    }

    @Test("the stock Default mode takes the app's level at key-down; a mode picked for one dictation keeps its own")
    func modeResolution() throws {
        let settings = try onAsSpoken(Self.notes)
        let modes = Mode.builtIns(userName: "")
        let stock = modes[0].resolvingAppCleanupLevel(settings.dictationLevel(for: Self.notes))
        #expect(stock.cleanupLevel == .verbatim)
        let picked = modes[1].resolvingAppCleanupLevel(settings.dictationLevel(for: Self.notes))
        #expect(picked.cleanupLevel == .clean && picked.isTransform)
        // The pipeline runs at the resolved mode's level, with no tone, layout or register.
        let run = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: stock.cleanupLevel), tone: settings, mode: stock, category: .documents,
            bundleID: Self.notes, windowTitle: nil)
        #expect(run.cleanupOptions.level == .verbatim && run.tone == nil && run.style == nil)
        #expect(run.cleanupOptions.register == nil)
        let manual = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: picked.cleanupLevel), tone: settings, mode: picked, category: .documents,
            bundleID: Self.notes, windowTitle: nil)
        #expect(manual.cleanupOptions.level == .clean)
    }

    @Test("an As spoken app's dictation keeps every word and never asks the model")
    func verbatimReachesOutput() async throws {
        let settings = try onAsSpoken(Self.notes)
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(settings.dictationLevel(for: Self.notes))
        let run = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: mode.cleanupLevel), tone: settings, mode: mode, category: .documents,
            bundleID: Self.notes, windowTitle: nil)
        let model = RefusingModel()
        let pipeline = DictationPipeline(transcriber: NoSpeech(), cleaner: SmartCleaner(model: model))
        let spoken = ToneLaneExample.asSpoken.spoken
        let output = await pipeline.clean(spoken, settings: run, strategy: nil)
        #expect(output.text == ToneLaneExample.asSpoken.written)
        #expect(model.calls == 0 && !output.usedModel)
    }

    @Test("the board shows a placed app in As spoken, and moving it back clears its choice")
    func boardRoundTrip() throws {
        let settings = try onAsSpoken(Self.notes)
        let placed = try #require(board(settings).app(id: Self.notes))
        #expect(placed.lane == .asSpoken && placed.isPlaced && placed.naturalLane == .refined)
        #expect(board(settings).lane(.asSpoken)?.apps.map(\.id) == [Self.notes])
        #expect(board(settings).destinations(for: placed).contains(.refined))
        #expect(ToneBoard.moving(placed, to: .refined, in: settings, promptAvailable: true) == .standard)
        // Every lane takes it, Prompt included, and an AI app can be moved there too.
        let claude = try #require(board(.standard).app(id: "com.anthropic.claudefordesktop"))
        let quiet = ToneBoard.moving(claude, to: .asSpoken, in: .standard, promptAvailable: true)
        #expect(quiet.register(for: .aiPrompts, bundleID: "com.anthropic.claudefordesktop") == nil)
        #expect(quiet.dictationLevel(for: "com.anthropic.claudefordesktop") == .verbatim)
    }

    @Test("without register lines As spoken is still a lane an app can be moved to")
    func availableOnEveryModel() throws {
        let lane = try #require(board(.standard, prompt: false).lane(.asSpoken))
        #expect(lane.isAvailable && lane.apps.isEmpty)
        let slack = try #require(board(.standard, prompt: false).app(id: Self.slack))
        #expect(board(.standard, prompt: false).destinations(for: slack).contains(.asSpoken))
        let moved = ToneBoard.moving(slack, to: .asSpoken, in: .standard, promptAvailable: false)
        #expect(moved.dictationLevel(for: Self.slack) == .verbatim)
    }

    @Test("the every-app switch still wins over every lane, and marks As spoken as the default")
    func everyAppSwitch() throws {
        var settings = ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: [Self.slack])
        settings.isAsSpoken = true
        for id in [Self.slack, Self.mail, Self.notes] {
            #expect(settings.dictationLevel(for: id) == .verbatim)
            #expect(settings.plan(for: .workMessages, bundleID: id).level == .verbatim)
        }
        let board = board(settings)
        #expect(board.lanes.filter(\.isDefault).map(\.lane) == [.asSpoken])
        // Apps still show where they go back to when it is switched off.
        #expect(board.app(id: Self.slack)?.lane == .casual)
    }

    @Test("an As spoken choice survives a relaunch; older settings and unknown values decode fine")
    func storage() throws {
        let settings = try onAsSpoken(Self.notes)
        let data = try JSONEncoder().encode(settings)
        #expect(String(decoding: data, as: UTF8.self).contains("\"asSpoken\""))
        #expect(try JSONDecoder().decode(ToneSettings.self, from: data) == settings)
        #expect(settings.fingerprint != ToneSettings.standard.fingerprint)
        // Written before As spoken was a lane: no sites, no added sites, the old global switch.
        let old = Data(#"{"isAsSpoken":true,"defaultTone":"refined","overrides":{},"keptLayouts":{},"apps":{"a.b":"casual"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ToneSettings.self, from: old)
        #expect(decoded.isAsSpoken && decoded.appChoices == ["a.b": .tone(.casual)])
        #expect(decoded.siteChoices.isEmpty && decoded.addedSites.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("sites"))
        let unknown = Data(#"{"isAsSpoken":false,"defaultTone":"refined","overrides":{},"keptLayouts":{},"sites":{"gmail":"shouting"}}"#.utf8)
        #expect(try JSONDecoder().decode(ToneSettings.self, from: unknown).siteChoices.isEmpty)
    }

    @Test("the As spoken lane has its copy and its example: the words exactly as said")
    func copyAndExample() {
        #expect(ToneLane.asSpoken.title == ToneCopy.asSpokenTitle)
        #expect(ToneLane.asSpoken.tone == nil && ToneLane.asSpoken.writing == .asSpoken)
        #expect(ToneCopy.laneDetail(.asSpoken, registerLines: true) == CleanupLevel.verbatim.summary)
        #expect(ToneLaneExample.forLane(.asSpoken, registerLines: false) == ToneLaneExample.asSpoken)
        #expect(AppWriting(rawValue: "asSpoken") == .asSpoken && AppWriting.asSpoken.rawValue == "asSpoken")
        #expect(!AppWriting.asSpoken.isAvailable)
    }
}
