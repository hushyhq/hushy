import Foundation
import MurmurCore

/// `murmur-eval live-shape [--tone professional] [--bundle com.anthropic.claudefordesktop] [--group-contract] [--report path.json]`
///
/// Task 125 follow-up. Does a long, run-on dictation with hedge "like"s, a doubled word and a contraction
/// come out polished when it goes through the same path `DictationController` uses for a hold-to-talk
/// dictation? The settings are built the way `DictationController.pipelineSettings` builds them (tone
/// plan from `ToneSettings`, the Default mode resolved to the app-wide level, the focused app's category
/// and technical-token context), and each invented dictation runs three ways: straight through
/// `DictationPipeline.clean` (what release does), after a streaming-style prewarm of every closed group
/// (what a long recording does), and rules-only. Counts and the stage that left a "like" in place are
/// reported; invented text only, no real dictations.
enum LiveShapeRunner {
    struct Sample { let id: String; let text: String }

    /// Invented, of the shape reported: 15 to 80 words, hedge "like", a doubled word, a contraction, run-ons.
    static let samples: [Sample] = [
        Sample(id: "short-15", text: "with the current plan how would they even know like which reports to be sending"),
        Sample(id: "short-15b", text: "I'll need to open the dashboard to see the numbers but how how would that work"),
        Sample(id: "long-45", text: "with the current plan how would they even know like which reports to be sending like think about it I'll need to open the dashboard to see the numbers but how how would that work like shouldn't we show that in the first screen so people can just decide"),
        Sample(id: "long-60", text: "so the way I see it we have two options we could keep the weekly summary like exactly as it is or we could let each team pick what they want and I think the second one is better because like nobody reads the long email anyway and I'll write up the proposal tomorrow but how how do we decide who owns the defaults like should it be product or should it be support"),
        Sample(id: "long-70", text: "I was looking at the onboarding flow and like the first thing people see is the settings page which is confusing because they don't know what any of it does and we should probably like move the important choices up front and I'll sketch that out but then the question is how how would we measure whether it worked like do we look at completion or do we look at how many people come back the next week"),
        Sample(id: "long-80", text: "when a customer writes in about a billing problem like the agent has to open three different tabs just to find the invoice and I think we can fix that by like putting the invoice and the plan on the same screen and I'll talk to the design team about it but how how soon could engineering ship something like that because if it takes a quarter then maybe we should do a quick version first and like see whether support even notices a difference in the tickets"),
        Sample(id: "long-42", text: "I think the pricing page is like too busy and we should probably like cut the comparison table down to three rows because nobody scrolls that far and I'll mock it up tonight but how how do we know the shorter version converts better like do we just run a test"),
        Sample(id: "long-55", text: "the reports we send every Monday are like way too long and I'll be honest I don't think anyone opens them so what if we like only send the three numbers that changed and link to the dashboard for the rest and then how how would we know whether people still want the full version"),
        Sample(id: "long-65", text: "so I talked to the vendor and they said like the integration will take about two weeks but I think that's optimistic because they still need to get security sign off and I'll follow up on Thursday but should we like start the contract now or should we wait until we know the timeline is real because if we wait we might lose the discount"),
        Sample(id: "long-48", text: "like when I open the app on my phone the menu is like hidden behind the logo and I'll admit it took me a minute to find it so how how are new users supposed to like discover that it is even there and shouldn't it just be visible"),
        Sample(id: "long-75", text: "we need to decide what to do about the backlog because it keeps growing and like every week we add more than we close and I'll take a first pass at sorting it but I think we should like agree on what done means before we start because how how else would we know when a ticket is actually finished and not just moved to another column"),
        Sample(id: "long-58", text: "in the last meeting people kept asking like who is responsible for the final review and I think the answer is like whoever wrote the draft but that doesn't really work because they're too close to it so I'll propose that someone from the other team does it and how how would that fit into the schedule"),
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}") }.map(String.init)
    }
    static func likes(_ text: String) -> Int { words(text).filter { $0 == "like" }.count }
    static func doubled(_ text: String) -> Int {
        let list = words(text)
        return zip(list, list.dropFirst()).filter { $0 == $1 }.count
    }
    static func contractions(_ text: String) -> Int {
        words(text).filter { $0.contains("'") || $0.contains("\u{2019}") }.count
    }

    /// What the app builds for one target with default app settings: the same shared function the controller calls.
    /// `surface` is what the focused field of a code editor reads as (`EditorChatSurface`); the app decides it from
    /// Accessibility, so a case states it. A chat box (or an unplaced field in Cursor or Windsurf) is an AI prompt.
    ///
    /// `appWriting` is the choice stored for this one app ("professional", "casual", "refined", "prompt"), as the Tones
    /// board stores it: with one, the register is that app's own, not the AI app default (Prompt).
    static func settings(tone: DictationTone, bundleID: String, surface: EditorChatSurface.Surface? = nil,
                         appWriting: String? = nil) -> (PipelineSettings, AppCategory) {
        var category = AppCategory.classify(bundleID: bundleID, windowTitle: nil)
        if let surface, EditorChatSurface.isPrompt(bundleID: bundleID, surface: surface) { category = .aiPrompts }
        var tones = ToneSettings.standard
        tones.choice = ToneChoice(tone: tone)
        if let appWriting {
            let writing: AppWriting? = appWriting == AppWriting.promptRawValue ? .prompt : DictationTone(rawValue: appWriting).map { .tone($0) }
            tones = tones.settingApp(writing, bundleIDs: [bundleID])
        }
        let mode = MurmurCore.Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        let settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode, category: category,
            bundleID: bundleID, windowTitle: nil)
        return (settings, category)
    }

    static func run(_ args: Arguments) async throws {
        if let cases = args.string("cases") { try await LiveShapeCases.run(args, casesPath: cases); return }
        let tone = DictationTone(rawValue: args.string("tone") ?? "professional") ?? .professional
        let bundle = args.string("bundle") ?? "com.anthropic.claudefordesktop"
        let (base, category) = settings(tone: tone, bundleID: bundle)
        print("### Live shape · tone \(tone.rawValue) · \(bundle) → \(category.rawValue) · level \(base.cleanupOptions.level.rawValue) · style \(base.style.map { "\($0.context.rawValue)/\($0.style.rawValue)" } ?? "none") · mode \(base.mode?.name ?? "-")")
        print("| case | path | words in → out | likes | doubled | contractions | wait | outcome | groups |")
        print("|---|---|---|---|---|---|---|---|---|")
        var detail: [String] = []
        for sample in samples {
            let inWords = words(sample.text).count
            for path in ["release", "prewarmed", "rules"] {
                let cleaner = args.makeCleaner(retainsRejectedCandidates: true)
                let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
                let settings = base
                if path == "prewarmed" {
                    let groups = TextSegmentation.groups(sample.text)
                    for group in groups where !group.isTail && groups.count > 1 {
                        await cleaner.prewarmGroup(group.text, options: settings.cleanupOptions, continuesSentence: group.continuesSentence,
                        previousRaw: group.index > 0 ? groups[group.index - 1].text : nil)
                    }
                }
                let started = ContinuousClock.now
                let result = await pipeline.clean(
                    sample.text, settings: settings, strategy: path == "rules" ? .rules : nil, released: started)
                let waited = ModelPace.ms(ContinuousClock.now - started) / 1000
                // The tone pass is idempotent, so running it again on the output must change nothing if it already ran.
                let again = ToneRegister.apply(base.tone ?? tone, layout: base.style?.style ?? .formal, to: result.text,
                                               in: base.style?.context ?? .other)
                let code = CleanupOutcomeSummary(groups: result.groups, level: base.cleanupOptions.level)?.code ?? "-"
                let groupList = result.groups.map {
                    "\($0.outcome.rawValue)\($0.guardCode.map { "/\($0.rawValue)" } ?? "") \($0.modelMs.map { "\($0)ms" } ?? "-")"
                        + ($0.repairedSpans > 0 ? " repaired:\($0.repairedSpans)" : "") + ($0.retries > 0 ? " retry:\($0.retries)" : "")
                }.joined(separator: " · ")
                print("| \(sample.id) | \(path) | \(inWords) → \(words(result.text).count) | \(likes(sample.text)) → \(likes(result.text)) | \(doubled(sample.text)) → \(doubled(result.text)) | \(contractions(sample.text)) → \(contractions(result.text)) | \(String(format: "%.1f", waited)) s | \(code) | \(groupList) |")
                detail.append("[\(sample.id)/\(path)] tone already applied to the output: \(again == result.text ? "yes" : "NO (another pass changes it)")")
                detail.append("  out: \(result.text)")
                for group in result.groups {
                    if let rejected = group.rejectedCandidate {
                        detail.append("  rejected by \(group.guardCode?.rawValue ?? "?"): likes \(likes(rejected)), doubled \(doubled(rejected)) in the model's own answer")
                        detail.append("    model answer: \(rejected)")
                    }
                }
            }
        }
        if args.flag("text") { print("\n" + detail.joined(separator: "\n")) }
    }
}
