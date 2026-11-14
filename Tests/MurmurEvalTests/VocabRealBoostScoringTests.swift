import Foundation
import MurmurCore
import Testing
@testable import murmur_eval

@Suite("vocab-real-boost scoring")
struct VocabRealBoostScoringTests {
    private static func vocabulary() -> SourcedVocabulary {
        let terms = [
            VocabularyTerm(text: "Priya"),
            VocabularyTerm(text: "invoice"),
            VocabularyTerm(text: "TextEdit", source: .installedApp),
            VocabularyTerm(text: "Visual Studio Code", source: .installedApp),
            VocabularyTerm(text: "Supabase", aliases: ["super base"]),
            VocabularyTerm(text: "Marguerite Okafor"),
        ]
        return SourcedVocabulary(
            context: VocabularyContext(terms: terms),
            sources: ["priya": .dictionary, "invoice": .dictionary, "textedit": .installedApp,
                      "visual studio code": .installedApp, "supabase": .dictionary, "marguerite okafor": .screen],
            aliasSources: ["super base": .dictionary])
    }

    private static func harmRow(_ text: String, vocab: String = "full") -> HarmRow {
        HarmRow(id: "h", vocab: vocab, text: text)
    }

    // MARK: Harm

    @Test func aSwapAtTheBoostStepAndKeptByTheGuardIsWorseTwice() {
        let result = VocabRealBoostScoring.scoreHarm(
            row: Self.harmRow("keep your voice down"), recogniser: "keep your voice down",
            boosted: "keep your invoice down", guarded: "keep your invoice down", vocabulary: Self.vocabulary())
        #expect(result.worseAtBoost == 1)
        #expect(result.worseAfterGuard == 1)
        #expect(result.changesAfterGuard == [
            .init(old: "voice", new: "invoice", term: "invoice", source: "dictionary")])
    }

    @Test func aSwapTheGuardRevertsCountsAtTheBoostStepOnly() {
        let result = VocabRealBoostScoring.scoreHarm(
            row: Self.harmRow("the privacy settings"), recogniser: "the privacy settings",
            boosted: "the Priya settings", guarded: "the privacy settings", vocabulary: Self.vocabulary())
        #expect(result.worseAtBoost == 1)
        #expect(result.worseAfterGuard == 0)
        #expect(result.changesAfterGuard.isEmpty)
        #expect(result.changesAtBoost.first?.source == "dictionary")
    }

    @Test func aMishearingTheBoostLeavesAloneIsNotMadeWorse() {
        let result = VocabRealBoostScoring.scoreHarm(
            row: Self.harmRow("send me a text"), recogniser: "send me a next",
            boosted: "send me a next", guarded: "send me a next", vocabulary: Self.vocabulary())
        #expect(result.worseAtBoost == 0)
        #expect(result.worseAfterGuard == 0)
    }

    @Test func aBoostThatFixesAMisheardWordIsNotMadeWorse() {
        let result = VocabRealBoostScoring.scoreHarm(
            row: Self.harmRow("ask Priya today"), recogniser: "ask pria today",
            boosted: "ask Priya today", guarded: "ask Priya today", vocabulary: Self.vocabulary())
        #expect(result.worseAtBoost == 0)
        #expect(result.worseAfterGuard == 0)
    }

    @Test func caseAndPunctuationAloneAreNotHarm() {
        let result = VocabRealBoostScoring.scoreHarm(
            row: Self.harmRow("open the mail app"), recogniser: "open the mail app.",
            boosted: "Open the Mail app", guarded: "Open the Mail app", vocabulary: Self.vocabulary())
        #expect(result.worseAtBoost == 0)
        #expect(result.worseAfterGuard == 0)
    }

    @Test func twoWordsJoinedIntoOneInstalledNameCountsBothWordsAndNamesTheApp() {
        let result = VocabRealBoostScoring.scoreHarm(
            row: Self.harmRow("review the text data today"), recogniser: "review the text data today",
            boosted: "review the TextEdit today", guarded: "review the TextEdit today", vocabulary: Self.vocabulary())
        #expect(result.worseAfterGuard == 2)
        #expect(result.changesAfterGuard == [
            .init(old: "text data", new: "textedit", term: "TextEdit", source: "installed app")])
    }

    @Test func aWordOfAMultiWordTermIsAttributedToThatTerm() {
        let changes = VocabRealBoostScoring.changes(
            from: "open the studio", to: "open the visual studio code", vocabulary: Self.vocabulary())
        #expect(changes.first?.term == "Visual Studio Code")
        #expect(changes.first?.source == "installed app")
    }

    @Test func anAliasIsAttributedToItsTerm() {
        let changes = VocabRealBoostScoring.changes(
            from: "we use a database", to: "we use super base", vocabulary: Self.vocabulary())
        #expect(changes.first?.term == "Supabase")
        #expect(changes.first?.source == "dictionary")
    }

    @Test func aDeletionAndAnUnexplainedSwapAreLabelled() {
        let vocabulary = Self.vocabulary()
        #expect(VocabRealBoostScoring.changes(from: "go to the page", to: "go to page", vocabulary: vocabulary)
            == [.init(old: "the", new: "", term: nil, source: "deletion")])
        #expect(VocabRealBoostScoring.changes(from: "a cat sat", to: "a dog sat", vocabulary: vocabulary)
            == [.init(old: "cat", new: "dog", term: nil, source: "unexplained")])
    }

    @Test func summaryCountsRowsWordsAndSources() {
        let vocabulary = Self.vocabulary()
        let results = [
            VocabRealBoostScoring.scoreHarm(
                row: Self.harmRow("keep your voice down"), recogniser: "keep your voice down",
                boosted: "keep your invoice down", guarded: "keep your invoice down", vocabulary: vocabulary),
            VocabRealBoostScoring.scoreHarm(
                row: Self.harmRow("review the text data"), recogniser: "review the text data",
                boosted: "review the TextEdit", guarded: "review the text data", vocabulary: vocabulary),
            VocabRealBoostScoring.scoreHarm(
                row: Self.harmRow("all fine here"), recogniser: "all fine here",
                boosted: "all fine here", guarded: "all fine here", vocabulary: vocabulary),
        ]
        let summary = VocabRealBoostScoring.summarise(harm: results)
        #expect(summary.rows == 3)
        #expect(summary.rowsWorseAtBoost == 2)
        #expect(summary.rowsWorseAfterGuard == 1)
        #expect(summary.wordsWorseAtBoost == 3)
        #expect(summary.wordsWorseAfterGuard == 1)
        #expect(summary.rowsWorseAfterGuardBySource == ["dictionary": 1])
        #expect(summary.rowsWorseAtBoostBySource == ["dictionary": 1, "installed app": 1])
    }

    @Test func worstListsTheMostDamagedRowsFirstAndSkipsCleanOnes() {
        let vocabulary = Self.vocabulary()
        let one = VocabRealBoostScoring.scoreHarm(
            row: HarmRow(id: "a", vocab: "full", text: "keep your voice down"), recogniser: "keep your voice down",
            boosted: "keep your invoice down", guarded: "keep your invoice down", vocabulary: vocabulary)
        let two = VocabRealBoostScoring.scoreHarm(
            row: HarmRow(id: "b", vocab: "full", text: "review the text data"), recogniser: "review the text data",
            boosted: "review the TextEdit", guarded: "review the TextEdit", vocabulary: vocabulary)
        let clean = VocabRealBoostScoring.scoreHarm(
            row: HarmRow(id: "c", vocab: "full", text: "fine"), recogniser: "fine", boosted: "fine", guarded: "fine",
            vocabulary: vocabulary)
        #expect(VocabRealBoostScoring.worst([one, clean, two], limit: 5).map(\.id) == ["b", "a"])
        #expect(VocabRealBoostScoring.worst([one, clean, two], limit: 1).map(\.id) == ["b"])
    }

    // MARK: Win

    @Test func aTermCountsOnlyWithItsExactCapitalsAsWholeWords() {
        #expect(VocabRealBoostScoring.containsTerm("Ask Siobhan, please.", term: "Siobhan"))
        #expect(!VocabRealBoostScoring.containsTerm("ask siobhan please", term: "Siobhan"))
        #expect(!VocabRealBoostScoring.containsTerm("ask Siobhans please", term: "Siobhan"))
        #expect(VocabRealBoostScoring.containsTerm("Open Visual Studio Code now", term: "Visual Studio Code"))
        #expect(!VocabRealBoostScoring.containsTerm("Open Visual Studio now", term: "Visual Studio Code"))
        #expect(VocabRealBoostScoring.containsTerm("Mail me at tryhushy.com.", term: "tryhushy.com"))
        #expect(!VocabRealBoostScoring.containsTerm("anything", term: ""))
    }

    @Test func recallIsScoredBeforeBoostAfterBoostAndAfterTheGuard() {
        let row = WinRow(id: "w", vocab: "full", text: "ask Priya about Supabase", expect: ["Priya", "Supabase"])
        let result = VocabRealBoostScoring.scoreWin(
            row: row, recogniser: "ask pria about super base", boosted: "ask Priya about Supabase",
            guarded: "ask Priya about super base")
        #expect(result.foundInRecogniser == 0)
        #expect(result.foundAfterBoost == 2)
        #expect(result.foundAfterGuard == 1)
    }

    @Test func winSummaryCountsGainsAndLosses() {
        let rows = [
            WinRow(id: "w1", vocab: "full", text: "", expect: ["Priya", "Supabase"]),
            WinRow(id: "w2", vocab: "full", text: "", expect: ["Figma"]),
        ]
        let results = [
            VocabRealBoostScoring.scoreWin(
                row: rows[0], recogniser: "ask pria about Supabase", boosted: "ask Priya about super base",
                guarded: "ask Priya about super base"),
            VocabRealBoostScoring.scoreWin(row: rows[1], recogniser: "open Figma", boosted: "open Figma", guarded: "open Figma"),
        ]
        let summary = VocabRealBoostScoring.summarise(win: results)
        #expect(summary.rows == 2)
        #expect(summary.terms == 3)
        #expect(summary.foundInRecogniser == 2)
        #expect(summary.foundAfterGuard == 2)
        #expect(summary.gainedByBoost == 1)
        #expect(summary.lostByBoost == 1)
        #expect(abs(summary.recall(summary.foundInRecogniser) - 2.0 / 3.0) < 0.0001)
    }

    @Test func recallOfNothingIsZeroNotNaN() {
        #expect(VocabRealBoostScoring.summarise(win: []).recall(0) == 0)
    }

    // MARK: Alignment

    @Test func regionsGroupRunsOfDifferingWords() {
        let regions = VocabRealBoostScoring.regions(
            from: ["a", "b", "c", "d"], to: ["a", "x", "y", "d", "e"])
        #expect(regions == [
            .init(old: ["b", "c"], new: ["x", "y"]),
            .init(old: [], new: ["e"]),
        ])
        #expect(VocabRealBoostScoring.regions(from: ["a"], to: ["a"]).isEmpty)
    }

    // MARK: The shipped fixture and rows

    private static var evalsFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Evals")
    }

    @Test(.enabled(if: PrivateFiles.present("Evals/vocab-real-boost-fixture.json"), "needs a private file: Evals/vocab-real-boost-fixture.json")) func theFixtureMatchesTheBrief() throws {
        let fixture = try VocabFixture.load(Self.evalsFolder.appendingPathComponent("vocab-real-boost-fixture.json").path)
        #expect(fixture.installedApps.count >= 140 && fixture.installedApps.count <= 160)
        #expect(Set(fixture.installedApps).count == fixture.installedApps.count)
        for name in ["TextEdit", "Notes", "Mail", "Music", "Photos", "Preview", "Pages", "Numbers", "Keynote", "Calendar",
                     "Linear", "Notion", "Slack", "Figma", "Obsidian", "Visual Studio Code", "Cursor", "Claude", "ChatGPT"] {
            #expect(fixture.installedApps.contains(name), "missing app \(name)")
        }
        #expect(fixture.dictionary.count == 40)
        for label in ["Next", "Text", "Edit", "Cancel", "Done", "Share"] {
            #expect(fixture.screen.context.contains(label), "missing screen label \(label)")
        }
        #expect(Set(fixture.profiles.keys) == ["full", "dictionary", "screen", "apps"])
    }

    @Test(.enabled(if: PrivateFiles.present("Evals/vocab-real-boost-fixture.json"), "needs a private file: Evals/vocab-real-boost-fixture.json")) func theFixtureBuildsTheAppsVocabularyWithASourceForEveryTerm() throws {
        let fixture = try VocabFixture.load(Self.evalsFolder.appendingPathComponent("vocab-real-boost-fixture.json").path)
        let full = try fixture.vocabulary(profile: "full")
        #expect(full.context.terms.count == full.sources.count)
        #expect(full.source(ofTerm: "Priya") == .dictionary)
        #expect(full.sources.values.contains(.installedApp))
        // Ordinary-word names (text + edit) are not boosted unconditionally (job 105).
        #expect(full.source(ofTerm: "TextEdit") == nil)
        #expect(full.source(ofTerm: "Hushy") == .builtIn)
        let dictionaryOnly = try fixture.vocabulary(profile: "dictionary")
        #expect(dictionaryOnly.sources.values.allSatisfy { $0 == .dictionary || $0 == .builtIn })
        #expect(throws: (any Error).self) { try fixture.vocabulary(profile: "nope") }
    }

    @Test(.enabled(if: PrivateFiles.present("Evals/vocab-harm.jsonl", "Evals/vocab-win.jsonl"), "needs a private file: Evals/vocab-harm.jsonl, Evals/vocab-win.jsonl")) func theRowFilesCoverTheCollisionWordsWithUniqueIDs() throws {
        let harm: [HarmRow] = try VocabRowFiles.load(Self.evalsFolder.appendingPathComponent("vocab-harm.jsonl").path)
        let win: [WinRow] = try VocabRowFiles.load(Self.evalsFolder.appendingPathComponent("vocab-win.jsonl").path)
        let fixture = try VocabFixture.load(Self.evalsFolder.appendingPathComponent("vocab-real-boost-fixture.json").path)
        #expect(harm.count >= 190 && harm.count <= 215)
        #expect(win.count >= 70 && win.count <= 90)
        #expect(Set(harm.map(\.id) + win.map(\.id)).count == harm.count + win.count)
        #expect(harm.allSatisfy { fixture.profiles[$0.vocab] != nil } && win.allSatisfy { fixture.profiles[$0.vocab] != nil })
        let words = harm.flatMap { VocabRealBoostScoring.lowerTokens($0.text) }
        for collision in ["text", "next", "data", "edit", "voice", "privacy", "cloud", "mail", "notes", "music", "photos",
                          "messages", "pages", "numbers", "preview", "home", "linear", "notion", "slack"] {
            #expect(words.filter { $0 == collision }.count >= 5, "too few rows with \(collision)")
        }
        let sentences = harm.map { $0.text.lowercased() }
        for join in ["text data", "text edit history", "page numbers", "my notes"] {
            #expect(sentences.contains { $0.contains(join) }, "no row with \(join)")
        }
        #expect(win.allSatisfy { !$0.expect.isEmpty })
        #expect(win.allSatisfy { row in row.expect.allSatisfy { row.text.contains($0) } })
    }
}
